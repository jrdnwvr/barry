//  SharedSnapshot.swift
//  Barry — Shared
//
//  A tiny, complication-friendly snapshot of the current tendency, persisted to the
//  shared App Group container. The phone/watch app writes it after every fetch; the
//  WidgetKit complication reads it so it can render instantly without a network call
//  (watchOS background-refresh budget is tight — brief §7).

import Foundation

/// One point of the complication sparkline (compact on purpose — the whole
/// snapshot lives in the App Group defaults).
struct SparkPoint: Codable, Hashable {
    let t: Date
    let p: Double  // hPa
}

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

    // Optional extras (absent in snapshots written by older builds — all decode
    // to nil). Wind + aviation conditions feed the METAR complication; the spark
    // series feeds the Graph complication.
    var windKmh: Double? = nil
    var windDirDeg: Double? = nil
    var windGustKmh: Double? = nil
    var visibilitySM: Double? = nil
    var ceilingFt: Int? = nil
    var ceilingCover: String? = nil
    var fltCat: String? = nil
    /// Observed pressure, last ~12 h, at most one point per hour.
    var spark: [SparkPoint]? = nil

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

        let cur = combined.pressure.current
        self.windKmh = cur.windspeed
        self.windDirDeg = cur.winddir
        self.windGustKmh = cur.windgust
        self.visibilitySM = cur.visibilitySM
        self.ceilingFt = cur.ceilingFt
        self.ceilingCover = cur.ceilingCover
        self.fltCat = cur.fltCat

        let cutoff = updatedAt.addingTimeInterval(-12 * 3600)
        self.spark = combined.observedSeries
            .filter { $0.t >= cutoff }
            .compactMap { p in p.pressure.map { SparkPoint(t: p.t, p: $0) } }
            .suffix(14)
            .map { $0 }
    }
}

extension TendencySnapshot {
    /// Forecast-aware glyph shared by the watch complication and the iPhone widget:
    /// when the interpreter's reading carries a feature it tells us what's *about*
    /// to happen (bottoming out, topping out, sharp fall just started), which is
    /// more useful than just "currently falling". Falls back to the trend icon.
    var trendSymbolName: String {
        switch feature {
        case "trough_passing":       return "arrow.up.from.line"     // at bottom, rising next
        case "post_trough_recovery": return "arrow.up.right"          // already rising off a low
        case "approaching_trough":   return "arrow.down.right"        // still falling toward a low
        case "ridge_peak":           return "arrow.down.from.line"    // at top, falling next
        case "rapid_fall":           return "arrow.down.to.line"      // sharp sustained drop
        case "rapid_rise":           return "arrow.up.to.line"        // sharp sustained rise (gust front)
        case "front_knee":           return "bolt.horizontal.fill"    // sudden step change
        default:                     return cls.symbolName
        }
    }

    /// Age beyond which the complication stops presenting the trend as current.
    /// METARs land hourly and the provider refreshes on WidgetKit's ~20-min budget,
    /// so 2 h of age means several consecutive refresh failures — say so instead of
    /// letting old data masquerade as live (the app's honesty principle).
    static let staleAfter: TimeInterval = 2 * 3600

    func isStale(asOf date: Date = Date()) -> Bool {
        date.timeIntervalSince(updatedAt) > Self.staleAfter
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
