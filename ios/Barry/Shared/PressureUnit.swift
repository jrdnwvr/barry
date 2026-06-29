//  PressureUnit.swift
//  Barry — Shared
//
//  hPa / inHg presentation (brief §6, §8). The aviation crossover audience expects
//  inHg, so it's a day-one setting. All math stays in hPa internally; this only
//  affects display.

import Foundation

enum PressureUnit: String, CaseIterable, Codable, Identifiable {
    case hPa
    case inHg

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hPa: return "hPa"
        case .inHg: return "inHg"
        }
    }

    /// 1 hPa = 0.0295299830714 inHg.
    private static let hPaToInHg = 0.0295299830714

    /// Convert an absolute pressure value from hPa into this unit.
    func convert(_ hPa: Double) -> Double {
        switch self {
        case .hPa: return hPa
        case .inHg: return hPa * Self.hPaToInHg
        }
    }

    /// Convert a delta (change) from hPa into this unit. Same factor, no offset.
    func convertDelta(_ hPaDelta: Double) -> Double {
        convert(hPaDelta) - convert(0)
    }

    func format(_ hPa: Double, signed: Bool = false) -> String {
        let v = convert(hPa)
        let digits = self == .hPa ? 1 : 2
        let s = String(format: "%.\(digits)f", v)
        if signed && v >= 0 { return "+\(s)" }
        return s
    }

    /// Format a delta with explicit sign and unit, e.g. "−2.4 hPa".
    func formatDelta(_ hPaDelta: Double) -> String {
        let v = convertDelta(hPaDelta)
        let digits = self == .hPa ? 1 : 2
        let sign = v > 0 ? "+" : (v < 0 ? "−" : "")
        return "\(sign)\(String(format: "%.\(digits)f", abs(v))) \(label)"
    }
}
