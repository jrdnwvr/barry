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
    // The rest of the report (km/h, °C); optional: absent on old backends.
    var windKmh: Double?
    var windDir: Double?
    var gustKmh: Double?
    var temp: Double?
    var dewpoint: Double?
    var visibilitySM: Double?
    var ceilingFt: Int?
    var fltCat: String?

    var id: Date { t }
    /// Preferred pressure value for plotting: SLP, falling back to altimeter.
    var pressure: Double? { slp ?? altim }
}

struct CurrentObs: Codable, Hashable {
    let slp: Double?
    let presTend: Double?
    /// Altimeter setting (hPa) + temp/dew point (°C) from the latest METAR —
    /// the density-altitude inputs. Optional: absent on old backends.
    var altim: Double?
    var temp: Double?
    var dewpoint: Double?
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
    var elevM: Double?
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
    // Field-conditions inputs; optional: absent on old backends.
    var temperature: Double?
    var dewpoint: Double?
    var cloudcover: Double?
    var surface_pressure: Double?

    var id: Date { t }
}

struct SunTimes: Codable, Hashable {
    var sunrise: [Date] = []
    var sunset: [Date] = []
}

struct ForecastResponse: Codable, Hashable {
    let hourly: [ForecastHour]
    var sun: SunTimes?
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

// MARK: - Reading (the server's structured curve interpretation)

/// Mirrors the backend's ReadingOut. Computed server-side; the app never
/// re-derives it.
struct Reading: Hashable, Codable {
    let trend: String
    let rate3h: Double
    let steadiness: Double
    let feature: String
    let featureTime: Date?
    let confidence: Double
    let caveats: [String]
    /// What else agrees or disagrees (C1). Optional: absent on old backends.
    var explanation: ExplanationOut?
}

// MARK: - Explanation (what else agrees with the pressure signal)

struct SignalOut: Codable, Hashable {
    let kind: String
    let at: Date
    let text: String
    let source: String   // "metar" (observed here) | "model" (forecast)
}

struct ExplanationOut: Codable, Hashable {
    let summary: String
    var supporting: [SignalOut] = []
    var conflicting: [SignalOut] = []
}

// MARK: - Field conditions (density altitude + fog risk)

struct DAPoint: Codable, Identifiable, Hashable {
    let t: Date
    let ft: Int
    var id: Date { t }
}

/// Radiation fog outlook for the coming night. Only present when there IS a
/// risk — a quiet night renders nothing.
struct FogOut: Codable, Hashable {
    let risk: String       // "possible" | "likely"
    var onset: Date?
    var clearing: Date?
    let detail: String
}

struct ConditionsOut: Codable, Hashable {
    var densityAltitudeFt: Int?
    var fieldElevationFt: Int?
    var daForecast: [DAPoint] = []
    var fog: FogOut?
}

// MARK: - Station wind layer

struct StationObs: Codable, Hashable, Identifiable {
    let id: String
    let lat: Double
    let lon: Double
    var name: String?
    var windKt: Double?
    var windDir: Double?
    var gustKt: Double?
    var fltCat: String?
    var obsTime: Date?
    var visibilitySM: Double?
    var ceilingFt: Int?
    var ceilingCover: String?
    var temp: Double?
    var dewpoint: Double?
    var altim: Double?
    var raw: String?
}

/// One runway, both ends, headings in degrees TRUE (same reference as the
/// METAR wind, so crosswind math needs no variation).
struct Runway: Codable, Hashable {
    let le: String
    let he: String
    let leHeading: Double
    let heHeading: Double
    var lengthFt: Int?
}

struct StationsResponse: Codable, Hashable {
    let stations: [StationObs]
    let cachedAt: Date
}

// MARK: - Radar model field (wind + boundary layer)

struct FieldPoint: Codable, Hashable {
    let lat: Double
    let lon: Double
    let windKmh: Double
    let windDeg: Double
    var blM: Double?
}

struct FieldGridResponse: Codable, Hashable {
    let points: [FieldPoint]
    let cachedAt: Date
}

// MARK: - Track record

/// Barry's scorecard at this station: trend calls that matched what the
/// pressure then did, over the last `days`. Absent until enough calls exist.
struct TrackRecordOut: Codable, Hashable {
    let right: Int
    let total: Int
    let days: Int
}

// MARK: - TAF

struct TafPeriod: Codable, Hashable, Identifiable {
    let timeFrom: Date
    let timeTo: Date
    var change: String?          // nil = base period; FM | BECMG | TEMPO | PROB30 | PROB40
    var windDir: Double?
    var windKt: Double?
    var gustKt: Double?
    var visibilitySM: Double?
    var ceilingFt: Int?
    var ceilingCover: String?
    var wx: String?
    var fltCat: String?
    var id: Date { timeFrom }

    /// "310@15G25" / "VRB05", the TAF's own shorthand.
    var windText: String? {
        guard let kt = windKt else { return nil }
        let dir = windDir.map { String(format: "%03d", Int($0)) } ?? "VRB"
        let g = gustKt.map { "G\(Int($0))" } ?? ""
        return "\(dir)@\(Int(kt))\(g)"
    }
}

struct TafOut: Codable, Hashable {
    let station: String
    var issueTime: Date?
    var validFrom: Date?
    var validTo: Date?
    var raw: String?
    var periods: [TafPeriod] = []
}

// MARK: - Station search

struct StationSearchResult: Codable, Hashable, Identifiable {
    let station: String
    let name: String
    let lat: Double
    let lon: Double
    var id: String { station }
}

struct StationSearchResponse: Codable {
    let results: [StationSearchResult]
}

// MARK: - WPC surface fronts

/// One front off the WPC chart: type cold|warm|stnry|ocfnt|trof and points
/// [[lat, lon], ...] in bulletin order. The front moves toward the LEFT of
/// travel along the points — the renderer puts the pips on that side.
struct FrontLine: Codable, Hashable {
    let type: String
    var isWeak: Bool = false
    let points: [[Double]]

    enum CodingKeys: String, CodingKey {
        case type
        case isWeak = "weak"
        case points
    }
}

struct PressureCenter: Codable, Hashable {
    let pressure: Int
    let lat: Double
    let lon: Double
}

/// The surface chart at one valid time: hours 0 = analysis, 12/24/36/48 =
/// WPC's forecast positions.
struct FrontFrame: Codable, Hashable, Identifiable {
    let hours: Int
    let valid: Date
    var fronts: [FrontLine] = []
    var highs: [PressureCenter] = []
    var lows: [PressureCenter] = []
    var id: Int { hours }
}

struct FrontsResponse: Codable, Hashable {
    let frames: [FrontFrame]
    var source: String?
    let cachedAt: Date
}

/// The radar timeline as the backend trimmed it: observed frames then nowcast.
struct RadarFrameOut: Codable, Hashable {
    let time: Int
    let path: String
    var nowcast: Bool = false
}

struct RadarFramesResponse: Codable, Hashable {
    let host: String
    let frames: [RadarFrameOut]
    let cachedAt: Date
}

/// Latest HRRR model run IEM serves forecast-reflectivity tiles for. Forecast
/// minute F on a tile layer is valid at run + F.
struct HrrrMeta: Codable, Hashable {
    let run: Date
    var source: String?
    let cachedAt: Date
}

// MARK: - Front watch (regional tendency field)

/// One surrounding station's own 3h tendency — a dot on the front-watch compass.
struct FrontStation: Codable, Hashable, Identifiable {
    let id: String
    let bearingDeg: Double
    let distanceKm: Double
    let tendency3h: Double
}

/// The WPC-analyzed front nearest the station, with WPC's own forecast motion.
struct NearestFront: Codable, Hashable {
    let type: String       // cold | warm | stnry | ocfnt | trof
    var isWeak: Bool = false
    let distanceKm: Double
    let bearingDeg: Double
    let cardinal: String
    var approaching: Bool?
    var etaHours: Double?
    var etaAt: Date?

    enum CodingKeys: String, CodingKey {
        case type, distanceKm, bearingDeg, cardinal, approaching, etaHours, etaAt
        case isWeak = "weak"
    }

    var name: String {
        switch type {
        case "cold": return "Cold front"
        case "warm": return "Warm front"
        case "stnry": return "Stationary front"
        case "ocfnt": return "Occluded front"
        default: return "Trough"
        }
    }

    var distanceMiles: Int { Int((distanceKm * 0.621371).rounded()) }
}

/// The `/front` payload. Direction comes from real station reports around the
/// user; timing (`eta`) comes from the model trough. Status "none" means a quiet
/// field — render nothing at all.
struct FrontResponse: Codable, Hashable {
    let station: String
    var nearestFront: NearestFront?
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
    var conditions: ConditionsOut?
    var runways: [Runway]?   // optional: absent on old backends
    var taf: TafOut?         // optional: none issued, or an old backend
    var trackRecord: TrackRecordOut?
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
