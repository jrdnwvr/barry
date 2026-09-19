//  FlightCategory.swift
//  Barry — Shared
//
//  The standard flight category colors, one place for the app, the map, the
//  watch and the widgets. Nil or unknown category falls back to secondary.

import SwiftUI

enum FlightCategory {
    static let order = ["VFR", "MVFR", "IFR", "LIFR"]

    static func color(_ cat: String?) -> Color {
        switch cat {
        case "VFR":  return Color(red: 0.13, green: 0.62, blue: 0.28)
        case "MVFR": return Color(red: 0.20, green: 0.48, blue: 0.85)
        case "IFR":  return Color(red: 0.85, green: 0.22, blue: 0.18)
        case "LIFR": return Color(red: 0.72, green: 0.20, blue: 0.70)
        default:     return .secondary
        }
    }

    /// Worse to better, for "improving" versus "deteriorating" wording.
    static func rank(_ cat: String) -> Int {
        ["LIFR": 0, "IFR": 1, "MVFR": 2, "VFR": 3][cat] ?? -1
    }
}
