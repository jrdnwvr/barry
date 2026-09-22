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

/// Thunderstorm / lightning state decoded from one METAR by the backend.
/// Absent means "nothing reported", never "no lightning": a field without a
/// sensor says nothing at all.
struct LightningOut: Codable, Hashable {
    let status: String            // thunderstorm | vicinity | distant
    var frequency: String?        // occasional | frequent | continuous
    var types: [String] = []      // IC, CC, CG
    var directions: [String] = [] // "SW", "W-NW", "ALQDS"
    var moving: String?
    var since: Date?

    private static let cardinal: [String: String] = [
        "N": "north", "NE": "northeast", "E": "east", "SE": "southeast",
        "S": "south", "SW": "southwest", "W": "west", "NW": "northwest",
    ]

    /// " to the northwest", ", west through north" (a range), " all around".
    private var whereText: String {
        var singles: [String] = []
        var ranges: [String] = []
        for d in directions {
            if let c = Self.cardinal[d] {
                singles.append(c)
            } else {
                let parts = d.split(separator: "-").compactMap { Self.cardinal[String($0)] }
                if parts.count == 2 { ranges.append("\(parts[0]) through \(parts[1])") }
            }
        }
        if let r = ranges.first { return ", \(r)" }
        if !singles.isEmpty { return " to the " + singles.prefix(2).joined(separator: " and ") }
        if directions.contains("ALQDS") { return " all around" }
        return ""
    }

    /// One calm sentence for the hero card and the station sheet.
    var sentence: String {
        switch status {
        case "thunderstorm":
            var t = "Thunderstorm at the field"
            if let s = since { t += " since \(s.formatted(date: .omitted, time: .shortened))" }
            if let m = moving, let c = Self.cardinal[m] { t += ", moving \(c)" }
            return t + "."
        case "vicinity":
            let lead = frequency == "frequent" || frequency == "continuous" ? "Frequent lightning" : "Lightning"
            return "\(lead) close by\(whereText)."
        default:
            return "Lightning in the distance\(whereText)."
        }
    }

    /// Short label for map badges and chips.
    var shortLabel: String {
        switch status {
        case "thunderstorm": return "TS"
        case "vicinity": return "LTG"
        default: return "DSNT"
        }
    }
}

struct CloudLayer: Codable, Hashable {
    let cover: String
    var baseFt: Int?
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
    var fltCatDerived: Bool? = nil   // Barry worked the category out; absent on old backends
    var wx: String?
    var lightning: LightningOut?
    var clouds: [CloudLayer]? = nil   // every layer, lowest first; absent on old backends
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
    var cape: Double?
    var weather_code: Int?
    var boundary_layer: Double?
    var radiation: Double?
    var temp80m: Double?
    var temp180m: Double?
    var wind80m: Double?

    var id: Date { t }
    /// WMO weather codes with a thunderstorm in them.
    var isThunder: Bool { [95, 96, 99].contains(weather_code ?? 0) }
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

/// Thunderstorm outlook for the next hours. Only present when there is a setup.
struct StormOut: Codable, Hashable {
    let risk: String       // "observed" | "likely" | "possible"
    var start: Date?
    var end: Date?
    var capeMax: Int?
    var source: String = "model"
    let detail: String
    // Observed storms nearby
    var distanceMi: Int?
    var cardinal: String?      // already a word: "west"
    var moving: String?
    var towardYou: Bool?
    var etaAt: Date?
    var forecastStart: Date?
    var forecastEnd: Date?
}

/// How bumpy the boundary layer is likely to be: an estimate from what
/// drives turbulence, never a measurement or a pilot report.
struct RideOut: Codable, Hashable {
    let band: String          // smooth | chop | bumpy
    let kind: String          // thermal | wind | mixed
    var topFt: Int?
    let score: Double
    let thermal: Double
    let mechanical: Double
    var changeBand: String?
    var changeAt: Date?
}

struct ConditionsOut: Codable, Hashable {
    var densityAltitudeFt: Int?
    var densityAltitudeHumidFt: Int?   // absent on old backends
    var fieldElevationFt: Int?
    var daForecast: [DAPoint] = []
    var boundaryLayerFt: Int?
    var blForecast: [DAPoint] = []
    var fog: FogOut?
    var storm: StormOut?
    var ride: RideOut?

    /// Anything worth a card at all.
    var hasContent: Bool {
        densityAltitudeFt != nil || !daForecast.isEmpty || boundaryLayerFt != nil
            || fog != nil || storm != nil
    }
}

// MARK: - Aloft: the column at a point

struct AloftLevel: Codable, Hashable, Identifiable {
    let hPa: Int
    let ft: Int
    let tempC: Double
    var dewC: Double?
    var dirDeg: Double?
    var spdKt: Double?
    var cloudPct: Int?
    var id: Int { hPa }
}

struct AloftCloud: Codable, Hashable {
    let baseFt: Int
    let topFt: Int
    let coverPct: Int
    var icing: Bool = false
}

struct AloftSurface: Codable, Hashable {
    var tempC: Double?
    var dewC: Double?
    var dirDeg: Double?
    var spdKt: Double?
}

struct AloftHour: Codable, Hashable {
    let t: Date
    var levels: [AloftLevel] = []
    var clouds: [AloftCloud] = []
    var surface: AloftSurface?
    var freezingFt: Int?
    var blAglFt: Int?
}

struct AloftResponse: Codable, Hashable {
    var hours: [AloftHour] = []
    let source: String
    let cachedAt: Date
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
    var fltCatDerived: Bool? = nil
    var obsTime: Date?
    var visibilitySM: Double?
    var ceilingFt: Int?
    var ceilingCover: String?
    var temp: Double?
    var dewpoint: Double?
    var altim: Double?
    var wx: String?
    var lightning: LightningOut?
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

    /// "18L" -> "18": the number alone. Barry cannot pick between parallels,
    /// so it never pretends to.
    static func base(_ ident: String) -> String {
        var s = Substring(ident)
        while let last = s.last, "LRCW".contains(last), s.count > 1 { s = s.dropLast() }
        return String(s)
    }

    /// Parallel runways collapsed to one per direction (the longest kept),
    /// with the L/R/C letters dropped from the idents.
    static func merged(_ runways: [Runway]) -> [Runway] {
        var out: [Runway] = []
        var index: [String: Int] = [:]
        for r in runways {
            let key = [base(r.le), base(r.he)].sorted().joined(separator: "/")
            let stripped = Runway(le: base(r.le), he: base(r.he), leHeading: r.leHeading,
                                  heHeading: r.heHeading, lengthFt: r.lengthFt)
            if let i = index[key] {
                if (r.lengthFt ?? 0) > (out[i].lengthFt ?? 0) { out[i] = stripped }
            } else {
                index[key] = out.count
                out.append(stripped)
            }
        }
        return out
    }
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
    var capeJkg: Double?
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

// MARK: - Pressure field (isobars, isallobars, shaded grids)

struct ContourLine: Codable, Hashable, Identifiable {
    let level: Double
    let points: [[Double]]
    var id: String { "\(level)-\(points.first ?? [])-\(points.count)" }
}

struct GridOut: Codable, Hashable {
    let lat0: Double
    let lon0: Double
    let dlat: Double
    let dlon: Double
    let ny: Int
    let nx: Int
    let values: [[Double?]]
}

struct FieldExtremum: Codable, Hashable {
    let kind: String     // "H" | "L"
    let lat: Double
    let lon: Double
    let value: Double
}

struct PressureFieldResponse: Codable, Hashable {
    var isobars: [ContourLine] = []
    var isallobars: [ContourLine] = []
    var pressureGrid: GridOut?
    var tendencyGrid: GridOut?
    var tendencyExtrema: [FieldExtremum] = []
    var stations: Int = 0
    let cachedAt: Date
}

// MARK: - GLM lightning (flashes seen from orbit)

struct LightningCell: Codable, Hashable {
    let lat: Double
    let lon: Double
    let count: Int
    let ageSec: Int
}

/// A group of touching flash cells: the electrified part of one storm,
/// as a closed outline of (lat, lon) pairs.
struct LightningCluster: Codable, Hashable {
    let points: [[Double]]
    let flashes: Int
    let recent: Int
    let newestAgeSec: Int
}

struct LightningResponse: Codable, Hashable {
    var cells: [LightningCell] = []
    var clusters: [LightningCluster] = []
    var windowSec: Int = 900
    var binDeg: Double = 0.02
    /// False when the server's feed is stale: an empty map then means
    /// "unknown", never "no lightning".
    var coverage: Bool = false
    var source: String?
    let cachedAt: Date
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

/// The nearest station reporting lightning within 100 miles: how far, which
/// way, how old the report is, and whether the storm is coming this way.
struct LightningNearby: Codable, Hashable {
    let station: String
    var name: String?
    let distanceMi: Int
    let bearingDeg: Double
    let cardinal: String
    let status: String
    let at: Date
    var moving: String?
    var towardYou: Bool?
    var continuesUntil: Date?
    var source: String?     // "metar" | "glm"; absent on old backends
    var flashes: Int?
    var speedKmh: Double?
    var etaAt: Date?

    private static let cardinalWord: [String: String] = [
        "N": "north", "NE": "northeast", "E": "east", "SE": "southeast",
        "S": "south", "SW": "southwest", "W": "west", "NW": "northwest",
    ]

    /// "Lightning 34 mi NW · 12m ago" / "Lightning at the field · 5m ago"
    func headline(now: Date) -> String {
        let m = max(0, Int(now.timeIntervalSince(at) / 60))
        let age = m < 60 ? "\(m)m ago" : "\(m / 60)h \(m % 60)m ago"
        let where_ = distanceMi < 3 ? "at the field" : "\(distanceMi) mi \(cardinal)"
        return "Lightning \(where_) · \(age)"
    }

    /// One sentence for the hero card: "Lightning 17 mi to the north, 10 min
    /// ago, moving toward you." / "Lightning at the field, 3 min ago."
    func sentence(now: Date) -> String {
        let m = max(0, Int(now.timeIntervalSince(at) / 60))
        let age = m < 1 ? "just now" : (m < 60 ? "\(m) min ago" : "\(m / 60) h \(m % 60) min ago")
        let where_ = distanceMi < 3 ? "at the field" : "\(distanceMi) mi to the \(Self.cardinalWord[cardinal] ?? cardinal)"
        var t = "Lightning \(where_), \(age)"
        if let d = detail(now: now) { t += ", \(d)" }
        return t + "."
    }

    /// The second line: motion relative to you, else whether more is expected.
    func detail(now: Date) -> String? {
        if let t = towardYou {
            if t, let eta = etaAt, eta > now {
                return "moving toward you, here around \(eta.formatted(date: .omitted, time: .shortened))"
            }
            return t ? "moving toward you" : "moving away"
        }
        if let m = moving, let w = Self.cardinalWord[m] {
            return "moving \(w)"
        }
        if let u = continuesUntil, u > now {
            return "more expected through \(u.formatted(date: .omitted, time: .shortened))"
        }
        return nil
    }
}

struct CombinedResponse: Codable, Hashable {
    let pressure: PressureResponse
    let forecast: ForecastResponse?
    let reading: Reading?
    var conditions: ConditionsOut?
    var runways: [Runway]?   // optional: absent on old backends
    var taf: TafOut?         // optional: none issued, or an old backend
    var trackRecord: TrackRecordOut?
    var lightningNearby: LightningNearby?   // optional: absent on old backends
    let sources: Sources?
    let verdict: String
}

// MARK: - Convenience derived from the combined payload

extension CombinedResponse {
    var tendency: TendencyOut? { pressure.tendency }

    var currentPressure: Double? {
        pressure.current.slp ?? pressure.series.last?.pressure
    }

    /// What the device barometer is calibrated against: the station's altimeter
    /// setting. Every METAR has one; sea-level pressure is the fallback for the
    /// rare station that reports only that.
    var calibrationReference: Double? {
        pressure.current.altim ?? currentPressure
    }

    /// A local altimeter-setting equivalent expressed in the kind of number the
    /// station series uses: sea-level pressure where the station reports it,
    /// the altimeter setting otherwise. The difference is the station's own
    /// temperature reduction, refreshed with every report.
    func displayValue(fromLocalAltim a: Double) -> Double {
        if let slp = pressure.current.slp, let alt = pressure.current.altim { return a + (slp - alt) }
        return a
    }

    /// The number to headline. At an airport (selected, or within 3 NM) it
    /// is the field's reported altimeter setting, the value a pilot dials
    /// in; elsewhere the sea-level pressure the trend is measured on.
    func headlinePressure(atAirport: Bool) -> (hPa: Double, isAltimeter: Bool)? {
        if atAirport, let a = pressure.current.altim { return (a, true) }
        return currentPressure.map { ($0, false) }
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
