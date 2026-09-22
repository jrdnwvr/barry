//  AloftMath.swift
//  Barry — iOS
//
//  The numbers behind the Aloft column, kept pure so they test: the
//  altitude scale that gives the crowded low levels room, the marks on a
//  wind barb, and which levels fit between the ground and the ceiling.

import CoreGraphics
import Foundation

/// The column's altitude scale. The bottom 6,000 ft take 52 percent of
/// the height and everything above shares the rest, so the levels a GA
/// pilot lives in do not pile onto each other.
enum AloftScale {
    static let breakFt = 6000.0
    static let lowShare = 0.52
    static let ceilings = [6000, 12000, 18000, 24000]

    /// 0 at the ceiling, 1 at the ground.
    static func fraction(ft: Double, ceiling: Double) -> Double {
        let c = max(ceiling, 1)
        let f: Double
        if c <= breakFt {
            f = 1 - ft / c
        } else if ft <= breakFt {
            f = 1 - ft / breakFt * lowShare
        } else {
            f = (1 - lowShare) - (ft - breakFt) / (c - breakFt) * (1 - lowShare)
        }
        return max(0, min(1, f))
    }
}

/// One mark on a barb, measured from the centre along the staff (negative
/// is toward the tip), in the design's 30 pt box.
struct BarbMark: Equatable {
    enum Kind { case pennant, full, half }
    let y: Double
    let kind: Kind
}

enum WindBarb {
    /// Marks from the tip inward: a pennant per 50 kt, a feather per 10,
    /// a half feather for the last 5. A lone half feather sits in from
    /// the tip so it does not read as a fleck.
    static func marks(speedKt: Double) -> [BarbMark] {
        var rem = Int((speedKt / 5).rounded()) * 5
        var y = -14.0
        var out: [BarbMark] = []
        while rem >= 50 { out.append(BarbMark(y: y, kind: .pennant)); rem -= 50; y += 5 }
        while rem >= 10 { out.append(BarbMark(y: y, kind: .full)); rem -= 10; y += 3.5 }
        if rem >= 5 {
            if out.isEmpty { y += 3.5 }
            out.append(BarbMark(y: y, kind: .half))
        }
        return out
    }
}

enum AloftRows {
    /// The levels between the ground and the ceiling, from the bottom up,
    /// dropping any that would land within `minGap` points of the one
    /// kept below it. Rows never overlap; a crowded scale loses a level
    /// rather than its legibility.
    static func visible(_ levels: [AloftLevel], groundFt: Int, ceilingFt: Int,
                        plotHeight: CGFloat, minGap: CGFloat = 18) -> [AloftLevel] {
        var out: [AloftLevel] = []
        // The ground band counts as the first row: a level sitting on it is not readable.
        var lastY = plotHeight * AloftScale.fraction(ft: Double(groundFt), ceiling: Double(ceilingFt))
        for lv in levels.sorted(by: { $0.ft < $1.ft }) where lv.ft > groundFt && lv.ft <= ceilingFt {
            let y = plotHeight * AloftScale.fraction(ft: Double(lv.ft), ceiling: Double(ceilingFt))
            if lastY - y >= minGap {
                out.append(lv)
                lastY = y
            }
        }
        return out
    }
}

enum AloftFormat {
    /// "−4°" with the real minus sign.
    static func degrees(_ c: Double) -> String {
        let v = Int(c.rounded())
        return (v < 0 ? "−\(abs(v))" : "\(v)") + "°"
    }

    /// "230°", zero padded like a forecast.
    static func direction(_ deg: Double) -> String {
        String(format: "%03d°", Int(deg.rounded()) % 360)
    }

    static func feet(_ ft: Int) -> String {
        ft.formatted(.number.grouping(.automatic))
    }
}
