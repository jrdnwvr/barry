//  RunwayMath.swift
//  Barry — Shared
//
//  The wind projected onto each runway end, and the setting that decides
//  when the app and the widgets show runway components at all. Pure values
//  so the runway winds card, the widget, and tests share one answer.

import Foundation

enum RunwayWindsMode: String, CaseIterable, Identifiable {
    case always, auto, compass
    static let key = "runwayWindsMode"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .always:  return "Runway"
        case .auto:    return "Auto"
        case .compass: return "Compass only"
        }
    }

    /// Whether runway components apply, given where the user is.
    func usesRunways(atAirport: Bool) -> Bool {
        switch self {
        case .always: return true
        case .auto: return atAirport
        case .compass: return false
        }
    }
}

struct RunwayWind: Identifiable {
    let ident: String
    let heading: Double
    let headwind: Double        // kt, negative = tailwind
    let crosswind: Double       // kt, signed, positive = from the right
    let gustCrosswind: Double?  // kt, signed, when a gust was reported

    var id: String { ident }
    var isTailwind: Bool { headwind < -0.5 }
}

enum RunwayWinds {
    /// One entry per runway END, best first: headwind ends before tailwind
    /// ends, then least crosswind. Nil wind or unknown runways gives [].
    static func compute(runways: [Runway], windDirDeg: Double?, windKt: Double,
                        gustKt: Double?) -> [RunwayWind] {
        guard let dir = windDirDeg, windKt >= 1 else { return [] }
        var out: [RunwayWind] = []
        for r in runways {
            for (ident, hdg) in [(r.le, r.leHeading), (r.he, r.heHeading)] where !ident.isEmpty {
                let delta = (dir - hdg) * .pi / 180
                let head = windKt * cos(delta)
                let cross = windKt * sin(delta)
                let gustCross = gustKt.map { $0 * sin(delta) }
                out.append(RunwayWind(ident: ident, heading: hdg, headwind: head,
                                      crosswind: cross, gustCrosswind: gustCross))
            }
        }
        return out.sorted {
            if $0.isTailwind != $1.isTailwind { return !$0.isTailwind }
            return abs($0.crosswind) < abs($1.crosswind)
        }
    }

    /// "9 kt crosswind from the right, 12 kt headwind. Gusts push it to 14 kt."
    static func sentence(_ w: RunwayWind) -> String {
        var parts: [String] = []
        let x = Int(abs(w.crosswind).rounded())
        if x >= 1 {
            parts.append("\(x) kt crosswind from the \(w.crosswind > 0 ? "right" : "left")")
        }
        let h = Int(abs(w.headwind).rounded())
        if h >= 1 { parts.append("\(h) kt \(w.headwind < 0 ? "tailwind" : "headwind")") }
        var s = parts.isEmpty ? "Wind straight down the runway." : parts.joined(separator: ", ") + "."
        if let g = w.gustCrosswind, abs(g) - abs(w.crosswind) >= 2 {
            s += " Gusts push the crosswind to \(Int(abs(g).rounded())) kt."
        }
        return s
    }

    /// "Rwy 21 · 9 kt from the right", for small spaces.
    static func compact(_ w: RunwayWind) -> String {
        let x = Int(abs(w.crosswind).rounded())
        if x < 1 { return "Rwy \(Runway.base(w.ident)) · straight down" }
        return "Rwy \(Runway.base(w.ident)) · \(x) kt from the \(w.crosswind > 0 ? "right" : "left")"
    }
}
