//  PressureActivity.swift
//  Barry — Shared (iOS app + phone widget)
//
//  The Live Activity's data: what is fixed for its lifetime (the station and
//  the event that started it) and what each update carries (the reading,
//  the trend, the verdict). Shared so the app writes it and the widget
//  extension draws it from one definition.

#if os(iOS)
import ActivityKit
import Foundation

struct PressureActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var pressureHPa: Double?
        var isAltimeter: Bool
        var delta3h: Double
        var cls: TendencyClass
        var intensity: Double
        var trendSymbol: String
        var verdict: String
        /// "Front passing", "Falling fast", "Lightning 12 mi west", "Following".
        var eventLabel: String
        var updatedAt: Date
    }

    let station: String
    let stationName: String?
    /// fall | rise | front | lightning | follow
    let kind: String
    let startedAt: Date
}
#endif
