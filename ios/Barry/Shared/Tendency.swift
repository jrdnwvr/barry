//  Tendency.swift
//  Barry — Shared
//
//  Single source of truth for tendency thresholds on the Swift side. Mirrors
//  backend/app/tendency.py (brief §4.1). Keep the two in sync BY HAND — there is
//  intentionally no codegen; the table is small and stable.

import Foundation
import SwiftUI

/// 3-hour pressure tendency classification.
enum TendencyClass: String, Codable, CaseIterable {
    case risingFast = "rising_fast"
    case rising
    case steady
    case falling
    case fallingMod = "falling_mod"
    case fallingFast = "falling_fast"

    // Thresholds (hPa per 3 hours, signed; negative = falling).
    static let risingFastT = 1.5
    static let risingT = 0.5
    static let steadyT = -0.5
    static let fallingT = -1.5
    static let fallingModT = -3.0

    /// Classify a signed 3-hour delta. Mirrors `classify()` in tendency.py.
    static func classify(delta3h d: Double) -> TendencyClass {
        if d >= risingFastT { return .risingFast }
        if d >= risingT { return .rising }
        if d > steadyT { return .steady }
        if d > fallingT { return .falling }
        if d > fallingModT { return .fallingMod }
        return .fallingFast
    }

    var isFalling: Bool {
        switch self {
        case .falling, .fallingMod, .fallingFast: return true
        default: return false
        }
    }

    /// SF Symbol name for the trend glyph (brief §4.1 icon column).
    var symbolName: String {
        switch self {
        case .risingFast: return "arrow.up"
        case .rising: return "arrow.up.right"
        case .steady: return "arrow.right"
        case .falling: return "arrow.down.right"
        case .fallingMod: return "arrow.down"
        case .fallingFast: return "arrow.down.to.line"
        }
    }

    /// Short human label.
    var label: String {
        switch self {
        case .risingFast: return "Rising fast"
        case .rising: return "Rising"
        case .steady: return "Steady"
        case .falling: return "Falling"
        case .fallingMod: return "Falling steadily"
        case .fallingFast: return "Falling sharply"
        }
    }
}

/// Continuous color-intensity model. Mirrors `intensity()` in tendency.py.
enum TendencyIntensity {
    // Band: |d| from FLOOR..CEIL hPa mapped to 0..1 (pale amber -> deep red).
    // See the note in tendency.py: set floor to 0.0 to match the brief's example
    // JSON instead of its prose.
    static let floor = 1.5
    static let ceil = 4.0

    static func intensity(delta3h d: Double) -> Double {
        let mag = abs(d)
        let raw = (mag - floor) / (ceil - floor)
        return min(1.0, max(0.0, raw))
    }
}

extension TendencyClass {
    /// Color for the glyph / complication. Falling classes blend amber -> red by
    /// `intensity`; rising/steady are fixed. Intensity drives *depth*, not hue,
    /// so the complication conveys magnitude at a glance (brief §4.1).
    func color(intensity: Double) -> Color {
        switch self {
        case .risingFast: return Color.green
        case .rising: return Color(red: 0.55, green: 0.85, blue: 0.45) // light green
        case .steady: return Color.gray
        case .falling, .fallingMod, .fallingFast:
            return Self.amberToRed(intensity)
        }
    }

    /// Linear blend pale-amber -> deep-red over t in 0...1.
    static func amberToRed(_ t: Double) -> Color {
        let amber = (r: 0.98, g: 0.75, b: 0.30)
        let red = (r: 0.78, g: 0.10, b: 0.10)
        let c = min(1.0, max(0.0, t))
        return Color(
            red: amber.r + (red.r - amber.r) * c,
            green: amber.g + (red.g - amber.g) * c,
            blue: amber.b + (red.b - amber.b) * c
        )
    }
}
