//  TemperatureUnit.swift
//  Barry — Shared
//
//  Temperature presentation. Everything stored and sent is Celsius, which
//  is what METARs and the model speak; this only changes what is drawn.

import Foundation

enum TemperatureUnit: String, CaseIterable, Codable, Identifiable {
    case celsius
    case fahrenheit

    static let key = "temperatureUnit"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        }
    }

    func convert(_ celsius: Double) -> Double {
        switch self {
        case .celsius: return celsius
        case .fahrenheit: return celsius * 9 / 5 + 32
        }
    }

    /// A difference between two temperatures, which has no offset.
    func convertDelta(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5
    }

    /// Where water freezes, in this unit.
    var freezing: Double { convert(0) }

    /// "−4°", "61°": whole degrees with the real minus sign, no unit.
    func format(_ celsius: Double) -> String {
        Self.degrees(convert(celsius))
    }

    /// "16°C", "61°F".
    func formatWithUnit(_ celsius: Double) -> String {
        Self.degrees(convert(celsius)) + label.dropFirst()
    }

    func formatDelta(_ celsius: Double) -> String {
        Self.degrees(convertDelta(celsius))
    }

    static func degrees(_ v: Double) -> String {
        let n = Int(v.rounded())
        return (n < 0 ? "−\(abs(n))" : "\(n)") + "°"
    }

    /// The saved choice, for code that cannot hold an AppStorage binding.
    static var current: TemperatureUnit {
        TemperatureUnit(rawValue: AppConfig.sharedDefaults.string(forKey: key) ?? "") ?? .celsius
    }
}
