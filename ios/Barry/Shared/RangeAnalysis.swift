//  RangeAnalysis.swift
//  Barry — Shared
//
//  Plain-language analysis of a user-selected slice of the pressure chart.
//  Pure rules over (Date, hPa) points — no network, fully unit-testable. The
//  vocabulary is small on purpose: a window of pressure has only a handful of
//  meaningful shapes (tide, calm, trough, ridge, fall, rise, noise), and each
//  has a real interpretation.

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

    /// Analyze a sorted-or-not slice of the series. `forecastStartsAt` marks the
    /// observed→forecast boundary (points after it are model output).
    static func analyze(points raw: [(Date, Double)],
                        forecastStartsAt now: Date?) -> RangeAnalysis? {
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
        let minV = values.min()!
        let maxV = values.max()!
        let spread = maxV - minV
        let minIdx = values.firstIndex(of: minV)!
        let maxIdx = values.firstIndex(of: maxV)!

        var steep = 0.0
        var steepAt: Date?
        for i in pts.indices {
            let s = PressureSlope.windowed(times: times, values: values, at: i) * 3
            if abs(s) > abs(steep) {
                steep = s
                steepAt = times[i]
            }
        }

        func frac(_ i: Int) -> Double {
            times[i].timeIntervalSince(first.0) / max(1, last.0.timeIntervalSince(first.0))
        }
        func clock(_ d: Date) -> String {
            d.formatted(date: .omitted, time: .shortened)
        }

        let title: String
        let detail: String

        if durationH >= 14, abs(net) <= 1.2, spread >= 0.8, spread <= 3.5,
           reversals(values) >= 2 {
            title = "The atmosphere breathing"
            detail = "This is the daily pressure tide, a gentle swing that peaks near 10 AM and 10 PM. Seeing it this clearly means nothing bigger is moving through. Stable air, and tomorrow will probably look a lot like today."
        } else if spread < 0.8 {
            title = "Dead calm"
            detail = "Pressure barely moved here. High pressure is parked overhead and nothing is pushing on it. Expect conditions to hold."
        } else if frac(minIdx) > 0.15, frac(minIdx) < 0.85,
                  values[0] - minV >= 1.0, values[values.count - 1] - minV >= 1.0 {
            title = "A trough passed"
            detail = "Pressure bottomed out around \(clock(times[minIdx])) and recovered. That is a trough, usually a front, with the roughest conditions near the low point."
        } else if frac(maxIdx) > 0.15, frac(maxIdx) < 0.85,
                  maxV - values[0] >= 1.0, maxV - values[values.count - 1] >= 1.0 {
            title = "A ridge peaked"
            detail = "Pressure topped out around \(clock(times[maxIdx])) and started easing. Fair conditions at the peak, slowly giving way after."
        } else if net <= -1.0 {
            let rate = net / durationH * 3
            title = rate <= -2.5 ? "A sharp fall" : "A steady fall"
            let where_ = steepAt.map { "around \(clock($0))" } ?? "midway through"
            detail = rate <= -2.5
                ? "Pressure dropped hard through this window, steepest \(where_). A pace like that usually means an organized system moving in."
                : "Pressure fell through this window, steepest \(where_). A front or low was approaching or passing."
        } else if net >= 1.0 {
            let rate = net / durationH * 3
            title = rate >= 2.5 ? "A sharp rise" : "A steady rise"
            detail = rate >= 2.5
                ? "Pressure built quickly here. A rise this fast usually follows a cold front, often with gusty wind behind it."
                : "Pressure built through this window. High pressure moving in, conditions settling."
        } else {
            title = "No single story"
            detail = "Pressure wandered without a clear trend. Weak systems and the daily tide trading places."
        }

        return RangeAnalysis(
            title: title, detail: detail,
            netHPa: net, spreadHPa: spread,
            steepest3hHPa: steep, steepestAt: steepAt,
            start: first.0, end: last.0,
            includesForecast: includesForecast)
    }

    /// Direction reversals of the meaningful (>= 0.3 hPa) swings — how many times
    /// the curve genuinely turned around. The tide turns at least twice a day.
    private static func reversals(_ values: [Double]) -> Int {
        guard values.count >= 5 else { return 0 }
        var count = 0
        var dir = 0
        var pivot = values[0]
        for v in values {
            let d = v - pivot
            if abs(d) >= 0.3 {
                let nd = d > 0 ? 1 : -1
                if dir != 0, nd != dir { count += 1 }
                dir = nd
                pivot = v
            }
        }
        return count
    }
}
