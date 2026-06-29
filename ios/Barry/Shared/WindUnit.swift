//  WindUnit.swift
//  Barry — Shared
//
//  Wind-speed presentation. The base unit is km/h because that's what Open-Meteo
//  returns by default (windspeed_10m), so all stored values are km/h and this only
//  affects display. Knots matters for the aviation audience (1 kn = 1 nmi/h).

import Foundation

enum WindUnit: String, CaseIterable, Codable, Identifiable {
    case kmh
    case mph
    case knots

    var id: String { rawValue }

    /// Short label shown inline next to a value and in the segmented picker.
    var label: String {
        switch self {
        case .kmh: return "km/h"
        case .mph: return "mph"
        case .knots: return "kts"
        }
    }

    private var factor: Double {
        switch self {
        case .kmh: return 1.0
        case .mph: return 0.621371      // km/h → mph
        case .knots: return 0.539957    // km/h → knots
        }
    }

    /// Convert a speed from km/h into this unit.
    func convert(_ kmh: Double) -> Double { kmh * factor }

    /// Whole-number string in this unit (wind rarely needs decimals).
    func format(_ kmh: Double) -> String {
        String(format: "%.0f", convert(kmh))
    }
}
