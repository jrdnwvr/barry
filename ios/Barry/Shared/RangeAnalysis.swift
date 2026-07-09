//  RangeAnalysis.swift
//  Barry — Shared
//
//  Plain-language analysis of a user-selected slice of the pressure chart.
//  Pure rules over (Date, hPa) points — no network, fully unit-testable.
//
//  Two-layer reading so big selections don't steamroll small structure:
//  1. DE-TIDE — on windows long enough to identify it (>=14 h), fit and subtract
//     the 12-hour atmospheric tide, the same trick the backend interpreter uses.
//     The tide is reported separately instead of contaminating the trend.
//  2. SEGMENT — classify the de-tided curve's local slope into rising / steady /
//     falling runs, merge the fragments, and narrate the phases in order. A day
//     of quiet tide followed by a front reads as exactly that, not "steady fall".

import Foundation

struct RangeAnalysis: Equatable {
    let title: String
    let detail: String
    let netHPa: Double
    let spreadHPa: Double
    /// Steepest 3h-equivalent rate anywhere in the window (signed hPa/3h).
    let steepest3hHPa: Double
    let steepestAt: Date?
    let start: Date
    let end: Date
    let includesForecast: Bool

    // MARK: - Tunables

    /// Windows at least this long can have the 12 h tide fitted + subtracted.
    static let tideFitMinHours = 14.0
    /// Fitted tide amplitudes below this are noise, not tide.
    static let tideMinAmplitude = 0.5
    /// |slope| (hPa per 3 h) above which a stretch counts as rising/falling.
    static let phaseSlopeThreshold = 0.8
    /// Phases shorter than this get absorbed into a neighbor.
    static let minPhaseHours = 2.0

    // MARK: - Entry

    static func analyze(points raw: [(Date, Double)],
                        forecastStartsAt now: Date?,
                        unit: PressureUnit) -> RangeAnalysis? {
        let pts = raw.sorted { $0.0 < $1.0 }
        guard let first = pts.first, let last = pts.last, pts.count >= 2 else { return nil }
        let durationH = last.0.timeIntervalSince(first.0) / 3600
        let includesForecast = now.map { last.0 > $0 } ?? false
        let net = last.1 - first.1

        guard pts.count >= 3, durationH >= 2 else {
            return RangeAnalysis(
                title: "Too short to read",
                detail: "Not much to learn from a window this small. Select a few hours or more.",
                netHPa: net, spreadHPa: 0, steepest3hHPa: 0, steepestAt: nil,
                start: first.0, end: last.0, includesForecast: includesForecast)
        }

        let times = pts.map(\.0)
        let values = pts.map(\.1)
        let spread = values.max()! - values.min()!

        // 1. De-tide when the window is long enough to tell tide from trend.
        var tideAmp = 0.0
        var work = values
        if durationH >= tideFitMinHours {
            let (amp, residual) = detide(times: times, values: values)
            if amp >= tideMinAmplitude {
                tideAmp = amp
                work = residual
            }
        }

        // Steepest local stretch — measured on the de-tided curve so the tide's
        // own slope can't claim the title.
        var steep = 0.0
        var steepAt: Date?
        for i in pts.indices {
            let s = PressureSlope.windowed(times: times, values: work, at: i) * 3
            if abs(s) > abs(steep) {
                steep = s
                steepAt = times[i]
            }
        }

        // 2. Segment into phases.
        let phases = segment(times: times, values: work)
        let (title, detail) = narrate(phases: phases, times: times,
                                      tideAmp: tideAmp, spread: spread,
                                      steepest: steep, steepAt: steepAt,
                                      durationH: durationH, unit: unit)

        return RangeAnalysis(
            title: title, detail: detail,
            netHPa: net, spreadHPa: spread,
            steepest3hHPa: steep, steepestAt: steepAt,
            start: first.0, end: last.0,
            includesForecast: includesForecast)
    }

    // MARK: - Phases

    struct Phase: Equatable {
        enum Kind: Equatable { case rising, steady, falling }
        var kind: Kind
        var startIdx: Int
        var endIdx: Int
        var start: Date
        var end: Date
        var netHPa: Double
        var hours: Double { end.timeIntervalSince(start) / 3600 }
    }

    /// Classify local slopes into runs, then absorb sub-`minPhaseHours` fragments
    /// into their larger neighbor and re-derive each run's kind from its net.
    static func segment(times: [Date], values: [Double]) -> [Phase] {
        func kindFor(net: Double, hours: Double) -> Phase.Kind {
            guard hours > 0 else { return .steady }
            let rate3h = net / hours * 3
            if rate3h >= phaseSlopeThreshold { return .rising }
            if rate3h <= -phaseSlopeThreshold { return .falling }
            return .steady
        }

        // Initial runs from pointwise slope regimes.
        var runs: [Phase] = []
        for i in times.indices {
            let s = PressureSlope.windowed(times: times, values: values, at: i) * 3
            let kind: Phase.Kind = s >= phaseSlopeThreshold ? .rising
                : (s <= -phaseSlopeThreshold ? .falling : .steady)
            if var lastRun = runs.last, lastRun.kind == kind {
                lastRun.endIdx = i
                lastRun.end = times[i]
                lastRun.netHPa = values[i] - values[lastRun.startIdx]
                runs[runs.count - 1] = lastRun
            } else {
                runs.append(Phase(kind: kind, startIdx: i, endIdx: i,
                                  start: times[i], end: times[i],
                                  netHPa: 0))
            }
        }

        // Absorb short fragments (merge into the previous run, or the next when
        // there is no previous) until every phase has real duration.
        var merged = runs
        while merged.count > 1,
              let shortIdx = merged.indices.first(where: { merged[$0].hours < minPhaseHours }) {
            let victim = merged.remove(at: shortIdx)
            let target = max(0, shortIdx - 1)
            merged[target].endIdx = max(merged[target].endIdx, victim.endIdx)
            merged[target].startIdx = min(merged[target].startIdx, victim.startIdx)
            merged[target].start = min(merged[target].start, victim.start)
            merged[target].end = max(merged[target].end, victim.end)
        }

        // Re-derive kind + net from the merged spans, then coalesce equal neighbors.
        for i in merged.indices {
            let net = values[merged[i].endIdx] - values[merged[i].startIdx]
            merged[i].netHPa = net
            merged[i].kind = kindFor(net: net, hours: merged[i].hours)
        }
        var out: [Phase] = []
        for p in merged {
            if var lastP = out.last, lastP.kind == p.kind {
                lastP.endIdx = p.endIdx
                lastP.end = p.end
                lastP.netHPa = values[p.endIdx] - values[lastP.startIdx]
                out[out.count - 1] = lastP
            } else {
                out.append(p)
            }
        }
        return out
    }

    // MARK: - Narration

    private static func narrate(phases: [Phase], times: [Date],
                                tideAmp: Double, spread: Double,
                                steepest: Double, steepAt: Date?,
                                durationH: Double,
                                unit: PressureUnit) -> (String, String) {
        func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
        func mag(_ hPa: Double) -> String {
            "\(unit.formatDelta(hPa)) \(unit.label)"
        }

        let moving = phases.filter { $0.kind != .steady }

        // Whole window quiet.
        if moving.isEmpty {
            if tideAmp >= tideMinAmplitude {
                return ("The atmosphere breathing",
                        "This is the daily pressure tide, swinging about \(mag(tideAmp)) either way with peaks near 10 AM and 10 PM. Seeing it this clearly means nothing bigger is moving through. Stable air, and tomorrow will probably look a lot like today.")
            }
            if spread < 0.8 {
                return ("Dead calm",
                        "Pressure barely moved here. High pressure is parked overhead and nothing is pushing on it. Expect conditions to hold.")
            }
            return ("No single story",
                    "Pressure wandered without a clear trend. Weak systems and the daily tide trading places.")
        }

        // Chronological phase sentences.
        var sentences: [String] = []
        for p in phases {
            switch p.kind {
            case .steady:
                if p.hours >= 3 {
                    sentences.append("Held steady from \(clock(p.start)) to \(clock(p.end)).")
                }
            case .falling:
                sentences.append("Fell \(mag(abs(p.netHPa))) between \(clock(p.start)) and \(clock(p.end)).")
            case .rising:
                sentences.append("Rose \(mag(abs(p.netHPa))) between \(clock(p.start)) and \(clock(p.end)).")
            }
        }
        if tideAmp >= tideMinAmplitude {
            sentences.append("Under it all, the daily tide swung about \(mag(tideAmp)) either way.")
        }

        // Headline from the phase pattern.
        let kinds = phases.map(\.kind)
        let title: String
        if let troughAt = adjacency(kinds, .falling, .rising) {
            title = "A trough passed"
            sentences.insert("Pressure bottomed out around \(clock(phases[troughAt].end)), usually a front, with the roughest conditions near the low point.", at: 0)
        } else if let ridgeAt = adjacency(kinds, .rising, .falling) {
            title = "A ridge peaked"
            sentences.insert("Pressure topped out around \(clock(phases[ridgeAt].end)). Fair conditions at the peak, giving way after.", at: 0)
        } else if moving.count == 1, let m = moving.first {
            let sharp = abs(m.netHPa / max(m.hours, 0.5) * 3) >= 2.5
            let ledQuiet = phases.first?.kind == .steady && (phases.first?.hours ?? 0) >= 3
            switch m.kind {
            case .falling:
                title = ledQuiet ? "Quiet, then a fall" : (sharp ? "A sharp fall" : "A steady fall")
                if sharp {
                    sentences.append("A pace like that usually means an organized system moving in.")
                }
            case .rising:
                title = ledQuiet ? "Quiet, then a rise" : (sharp ? "A sharp rise" : "A steady rise")
                if sharp {
                    sentences.append("A rise this fast usually follows a cold front, often with gusty wind behind it.")
                }
            case .steady:
                title = "No single story"
            }
        } else {
            title = "A busy stretch"
        }

        return (title, sentences.joined(separator: " "))
    }

    /// Index of the first phase where `a` is immediately followed by `b`.
    private static func adjacency(_ kinds: [Phase.Kind],
                                  _ a: Phase.Kind, _ b: Phase.Kind) -> Int? {
        guard kinds.count >= 2 else { return nil }
        for i in 0..<(kinds.count - 1) where kinds[i] == a && kinds[i + 1] == b {
            return i
        }
        return nil
    }

    // MARK: - Tide fit

    /// Least-squares fit of c + a·sin(ωt) + b·cos(ωt), ω = 2π/12 h. Returns the
    /// fitted amplitude and the residual (values with the tide removed).
    static func detide(times: [Date], values: [Double]) -> (amplitude: Double, residual: [Double]) {
        let t0 = times[0]
        let omega = 2 * Double.pi / (12 * 3600)
        let x = times.map { $0.timeIntervalSince(t0) }
        let s = x.map { sin(omega * $0) }
        let c = x.map { cos(omega * $0) }
        let n = Double(values.count)

        // Normal equations for [const, a, b].
        let Ss = s.reduce(0, +), Sc = c.reduce(0, +)
        let Sss = zip(s, s).reduce(0) { $0 + $1.0 * $1.1 }
        let Scc = zip(c, c).reduce(0) { $0 + $1.0 * $1.1 }
        let Ssc = zip(s, c).reduce(0) { $0 + $1.0 * $1.1 }
        let Sy = values.reduce(0, +)
        let Sys = zip(values, s).reduce(0) { $0 + $1.0 * $1.1 }
        let Syc = zip(values, c).reduce(0) { $0 + $1.0 * $1.1 }

        // Solve the 3×3 system via Cramer's rule.
        let m = [
            [n,   Ss,  Sc],
            [Ss,  Sss, Ssc],
            [Sc,  Ssc, Scc],
        ]
        let rhs = [Sy, Sys, Syc]
        func det3(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
                - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let d = det3(m)
        guard abs(d) > 1e-9 else { return (0, values) }
        func col(_ j: Int) -> [[Double]] {
            var mm = m
            for i in 0..<3 { mm[i][j] = rhs[i] }
            return mm
        }
        let a = det3(col(1)) / d
        let b = det3(col(2)) / d
        let amplitude = (a * a + b * b).squareRoot()
        let residual = values.indices.map { values[$0] - a * s[$0] - b * c[$0] }
        return (amplitude, residual)
    }
}
