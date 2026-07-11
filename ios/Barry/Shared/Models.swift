//  Models.swift
//  Barry — Shared
//
//  Codable mirrors of the backend JSON contract (brief §5). Field names and the
//  `class` alias match the server's `model_dump(by_alias=True)` output exactly.

import Foundation

struct SeriesPoint: Codable, Identifiable, Hashable {
    let t: Date
    let slp: Double?
    let altim: Double?

    var id: Date { t }
    /// Preferred pressure value for plotting: SLP, falling back to altimeter.
    var pressure: Double? { slp ?? altim }
}

struct CurrentObs: Codable, Hashable {
    let slp: Double?
    let presTend: Double?
    /// Wind from the latest METAR — a real measurement, preferred over the model
    /// forecast for "now" (km/h + degrees). `windgust` only present when the
    /// station reported one (inherently notable). Optional: absent on old backends.
    var windspeed: Double?
    var winddir: Double?
    var windgust: Double?
    /// Aviation conditions from the same METAR (drives the METAR complication).
    var visibilitySM: Double?
    var ceilingFt: Int?
    var ceilingCover: String?
    var fltCat: String?
}

struct TendencyOut: Codable, Hashable {
    let delta3h: Double
    let cls: TendencyClass
    let intensity: Double

    enum CodingKeys: String, CodingKey {
        case delta3h
        case cls = "class"
        case intensity
    }
}

struct PressureResponse: Codable, Hashable {
    let station: String
    let name: String?
    let lat: Double?
    let lon: Double?
    let series: [SeriesPoint]
    let current: CurrentObs
    let tendency: TendencyOut?
    let source: String
    let cachedAt: Date
}

struct ForecastHour: Codable, Identifiable, Hashable {
    let t: Date
    let pressure_msl: Double?
    let windspeed: Double?
    let winddir: Double?
    var windgust: Double?  // model gusts (km/h); optional: absent on old backends
    let precip_prob: Int?

    var id: Date { t }
}

struct ForecastResponse: Codable, Hashable {
    let hourly: [ForecastHour]
    let source: String
    let cachedAt: Date
    /// True when the backend re-served its last good forecast because the upstream
    /// was down (stale-if-error). Optional: absent on old backends.
    var stale: Bool?
}

struct Sources: Codable, Hashable {
    let observed: String
    let forecast: String?
}

// MARK: - Front watch (regional tendency field)

/// One surrounding station's own 3h tendency — a dot on the front-watch compass.
struct FrontStation: Codable, Hashable, Identifiable {
    let id: String
    let bearingDeg: Double
    let distanceKm: Double
    let tendency3h: Double
}

/// The `/front` payload. Direction comes from real station reports around the
/// user; timing (`eta`) comes from the model trough. Status "none" means a quiet
/// field — render nothing at all.
struct FrontResponse: Codable, Hashable {
    let station: String
    let status: String   // none | forecast | approaching | passing | passed
    var headline: String?
    var detail: String?
    var bearingDeg: Double?
    var cardinal: String?
    var eta: Date?
    var maxFall3h: Double?
    var ownDelta3h: Double?
    var gradient: Double?
    var coherence: Double?
    var stations: [FrontStation] = []
    let cachedAt: Date

    var isActive: Bool { status != "none" }
}

struct CombinedResponse: Codable, Hashable {
    let pressure: PressureResponse
    let forecast: ForecastResponse?
    let reading: Reading?
    let sources: Sources?
    let verdict: String
}

// MARK: - Convenience derived from the combined payload

extension CombinedResponse {
    var tendency: TendencyOut? { pressure.tendency }

    var currentPressure: Double? {
        pressure.current.slp ?? pressure.series.last?.pressure
    }

    /// Observed points that have a usable pressure value, oldest -> newest.
    var observedSeries: [SeriesPoint] {
        pressure.series.filter { $0.pressure != nil }
    }

    /// Forecast points trimmed to the future (the "now" line splits the chart).
    func forecastSeries(after now: Date) -> [ForecastHour] {
        (forecast?.hourly ?? []).filter { $0.t >= now && $0.pressure_msl != nil }
    }

    /// Model-expected pressure change over the 3 hours *following* `now`, in hPa
    /// (signed; negative = falling). Computed entirely within the forecast series
    /// — pressure(now+3h) − pressure(nearest to now) — so it shares one baseline
    /// and isn't skewed by the observed/forecast MSL offset. Returns nil when the
    /// forecast is missing or too short. This is the "what's coming" signal that
    /// drives the dial complication's needle angle.
    func expectedDelta3h(after now: Date) -> Double? {
        let pts = (forecast?.hourly ?? []).filter { $0.pressure_msl != nil }
        guard pts.count >= 2 else { return nil }
        func nearest(to date: Date) -> ForecastHour? {
            pts.min { abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date)) }
        }
        guard let p0 = nearest(to: now)?.pressure_msl,
              let p3 = nearest(to: now.addingTimeInterval(3 * 3600))?.pressure_msl
        else { return nil }
        return p3 - p0
    }
}
