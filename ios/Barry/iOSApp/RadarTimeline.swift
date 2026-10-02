//  RadarTimeline.swift
//  Barry — iOS
//
//  The radar's clock: which frames a span lists, where its loop starts, what
//  the time line under the slider says, and which isobars and which front
//  positions go with the moment the slider is on. Pure functions, so the
//  rules are tested without a map.

import Foundation

/// The two replay chips. `hour` is every ten minutes from two hours back and
/// the nowcast; its loop is the last hour. `day` is on the hour from six
/// hours back to twelve ahead; its loop is the last six hours. Forecast
/// frames are scrubbed to, never looped.
enum RadarSpan: String {
    case hour, day

    /// How far back the loop starts, seconds before the newest observed frame.
    var loopSeconds: Int { self == .hour ? 3_600 : 6 * 3_600 }
}

enum RadarFrameKind: String {
    case observed, nowcast, model
}

enum RadarTimeline {
    /// A moment this close to the newest observed frame is "now": the layers
    /// that only know the present are right for it, and the isobars are the
    /// live field's.
    static let nowToleranceS = 15 * 60
    /// A pressure frame is used for a moment within this of its hour.
    static let pressureMatchS = 35 * 60

    /// Where the loop starts: the first frame within the span's loop length
    /// of the newest observed one.
    static func loopStart(frames: [RadarFrame], nowIndex: Int, span: RadarSpan) -> Int {
        guard frames.indices.contains(nowIndex) else { return 0 }
        let from = frames[nowIndex].time - span.loopSeconds
        return frames.firstIndex { $0.time >= from } ?? 0
    }

    /// The next frame of the loop: from the loop's start through now, then
    /// around again. A playhead outside the loop (scrubbed further back, or
    /// into the forecast) rejoins it at the start.
    static func nextLoopIndex(current: Int, start: Int, nowIndex: Int) -> Int {
        current >= nowIndex || current < start ? start : current + 1
    }

    static func isNow(_ time: Int, nowTime: Int) -> Bool {
        abs(time - nowTime) <= nowToleranceS
    }

    /// "8:20 PM · 20m ago", "11 AM · 5h ago", "8:50 PM · nowcast +40m",
    /// "10 PM · model +2h", "8:40 PM · latest, 3m ago".
    static func frameText(_ f: RadarFrame, nowTime: Int, wallClock: Date, parked: Bool,
                          clock: (Date) -> String) -> String {
        let at = clock(Date(timeIntervalSince1970: Double(f.time)))
        switch f.kind {
        case .model:
            let hrs = max(1, Int((Double(f.time - nowTime) / 3600).rounded()))
            return "\(at) · model +\(hrs)h"
        case .nowcast:
            let mins = max(10, Int((Double(f.time - nowTime) / 600).rounded()) * 10)
            return "\(at) · nowcast +\(mins)m"
        case .observed:
            let mins = Int((wallClock.timeIntervalSince1970 - Double(f.time)) / 60)
            let age: String
            if mins <= 1 { age = "now" }
            else if mins < 100 { age = "\(mins)m ago" }
            else { age = "\(Int((Double(mins) / 60).rounded()))h ago" }
            return parked ? "\(at) · latest, \(age)" : "\(at) · \(age)"
        }
    }

    /// The isobars for a moment: nil when it is now (the live field is the
    /// better picture) or when no hour of the series is near it.
    static func pressureFrame(_ series: [PressureFrame], time: Int, nowTime: Int) -> PressureFrame? {
        guard !isNow(time, nowTime: nowTime) else { return nil }
        let best = series.min { abs($0.time - time) < abs($1.time - time) }
        guard let best, abs(best.time - time) <= pressureMatchS else { return nil }
        return best
    }

    /// Where the fronts are at a moment.
    enum FrontPick: Equatable {
        case none
        case frame(FrontFrame)
        case blend(FrontFrame, FrontFrame, Double)
    }

    /// The chart for a moment on the timeline. The analysis stands from its
    /// own valid time until now, as it always has on this map. Before that,
    /// the earlier analyses are blended by their valid times. After now, the
    /// analysis is carried to the next forecast chart, reaching it at that
    /// chart's valid time, and on to the one after. Nothing is run past the
    /// oldest or the last chart held.
    static func fronts(at time: Int, nowTime: Int, analysis: FrontFrame?, history: [FrontFrame],
                       progs: [FrontFrame]) -> FrontPick {
        guard let analysis else { return .none }
        let t = Double(time), now = Double(nowTime)
        let valid = analysis.valid.timeIntervalSince1970
        if t > now + Double(nowToleranceS) {
            // The analysis leaves from now, not from its valid time: the
            // map has shown it at now all along, and a jump there would
            // read as the front leaping.
            var from = analysis, fromT = now
            for p in progs.sorted(by: { $0.valid < $1.valid }) {
                let pt = p.valid.timeIntervalSince1970
                guard pt > fromT else { continue }
                if t <= pt { return .blend(from, p, (t - fromT) / (pt - fromT)) }
                from = p
                fromT = pt
            }
            return .frame(from)
        }
        if t >= valid { return .frame(analysis) }
        let past = (history.filter { $0.valid < analysis.valid } + [analysis]).sorted { $0.valid < $1.valid }
        guard let first = past.first else { return .frame(analysis) }
        if t <= first.valid.timeIntervalSince1970 { return .frame(first) }
        for (a, b) in zip(past, past.dropFirst()) {
            let at = a.valid.timeIntervalSince1970, bt = b.valid.timeIntervalSince1970
            if t <= bt { return .blend(a, b, (t - at) / (bt - at)) }
        }
        return .frame(analysis)
    }

    /// The one line that says which layers are not on the slider's clock,
    /// nil when the slider is on now or none of them is showing.
    static func nowOnlyNote(wind: Bool, stations: Bool, lightning: Bool, advisories: Bool,
                            change: Bool) -> String? {
        var names: [String] = []
        if wind { names.append("wind") }
        if stations { names.append("stations") }
        if lightning { names.append("lightning") }
        if advisories { names.append("advisories") }
        if change { names.append("pressure change") }
        guard let first = names.first else { return nil }
        let list: String
        switch names.count {
        case 1: list = first
        case 2: list = "\(first) and \(names[1])"
        default: list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        let subject = list.prefix(1).uppercased() + list.dropFirst()
        return "\(subject) \(names.count == 1 && !first.hasSuffix("s") ? "shows" : "show") now."
    }
}
