//  SharedSnapshot.swift
//  Barry — Shared
//
//  A tiny, complication-friendly snapshot of the current tendency, persisted to the
//  shared App Group container. The phone/watch app writes it after every fetch; the
//  WidgetKit complication reads it so it can render instantly without a network call
//  (watchOS background-refresh budget is tight — brief §7).

import Foundation

struct TendencySnapshot: Codable, Hashable {
    let station: String
    let stationName: String?
    let currentPressureHPa: Double?
    let delta3h: Double
    let cls: TendencyClass
    let intensity: Double
    /// Interpreter's §4.3 feature ("approaching_trough", "trough_passing", …)
    /// — drives forecast-aware glyphs/colors on the complication.
    let feature: String?
    /// Model-expected pressure change over the *next* 3h (signed hPa). Drives the
    /// dial complication's needle angle. nil when no forecast is available.
    let expectedDelta3h: Double?
    let verdict: String
    let updatedAt: Date

    init(from combined: CombinedResponse, updatedAt: Date = Date()) {
        let t = combined.tendency
        self.station = combined.pressure.station
        self.stationName = combined.pressure.name
        self.currentPressureHPa = combined.currentPressure
        self.delta3h = t?.delta3h ?? 0
        self.cls = t?.cls ?? .steady
        self.intensity = t?.intensity ?? 0
        self.feature = combined.reading?.feature
        self.expectedDelta3h = combined.expectedDelta3h(after: updatedAt)
        self.verdict = combined.verdict
        self.updatedAt = updatedAt
    }
}

enum SnapshotStore {
    private static let key = "tendency.snapshot.v1"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppConfig.appGroupID)
    }

    static func save(_ snapshot: TendencySnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: key)
    }

    static func load() -> TendencySnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TendencySnapshot.self, from: data)
    }
}
