//  BarryAPI.swift
//  Barry — Shared
//
//  Thin async client for the caching backend. Clients NEVER talk to
//  aviationweather.gov directly (brief §7) — everything goes through this proxy.

import Foundation

enum APIError: Error, LocalizedError {
    case badURL
    case http(Int)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Bad request URL."
        case .http(let code): return "Server returned status \(code)."
        case .decoding: return "Couldn't read the server response."
        case .transport: return "Network problem. Check your connection."
        }
    }
}

struct BarryAPI {
    let baseURL: URL
    let session: URLSession

    /// The session behind a spinner: twelve seconds and then an answer,
    /// not the system's sixty. No waiting for connectivity: offline is an
    /// answer too, and the cold-start cache is what the screen shows then.
    static let interactiveSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 20
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// The session for refreshes nobody is watching: it may wait for the
    /// radio to come back rather than fail at once.
    static let patientSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 45
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    init(baseURL: URL = AppConfig.backendBaseURL, session: URLSession = BarryAPI.interactiveSession) {
        self.baseURL = baseURL
        self.session = session
    }

    /// The same client on the patient session. A client built on its own
    /// session (the widgets, tests) keeps it.
    var patient: BarryAPI {
        session === Self.interactiveSession ? BarryAPI(baseURL: baseURL, session: Self.patientSession) : self
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Primary call — the full −24/+24 picture in one request (brief §5).
    func combined(station: String, lat: Double?, lon: Double?) async throws -> CombinedResponse {
        var comps = URLComponents(url: baseURL.appendingPathComponent("combined"),
                                  resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "station", value: station)]
        if let lat { items.append(URLQueryItem(name: "lat", value: String(lat))) }
        if let lon { items.append(URLQueryItem(name: "lon", value: String(lon))) }
        // The verdict and explanation quote local clock times; the device
        // knows the real offset (with daylight saving), the server can only guess.
        items.append(URLQueryItem(name: "tz", value: String(TimeZone.current.secondsFromGMT() / 60)))
        comps?.queryItems = items
        return try await get(comps?.url)
    }

    /// Front watch — regional pressure-tendency field around the station.
    /// Called after `combined` so the backend's caches are warm; a failure just
    /// means no banner, never a blocked screen.
    func front(station: String, lat: Double?, lon: Double?) async throws -> FrontResponse {
        var comps = URLComponents(url: baseURL.appendingPathComponent("front"),
                                  resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "station", value: station)]
        if let lat { items.append(URLQueryItem(name: "lat", value: String(lat))) }
        if let lon { items.append(URLQueryItem(name: "lon", value: String(lon))) }
        comps?.queryItems = items
        return try await get(comps?.url)
    }

    /// Latest wind at every station around a point — the radar's barb/speed layer.
    /// `half` is the box half-width in degrees of latitude. The server thins
    /// to a fixed ceiling whatever the box, so a wide one spreads the same
    /// number of stations further rather than returning more of them.
    func metars(lat: Double, lon: Double, half: Double? = nil) async throws -> StationsResponse {
        var comps = URLComponents(url: baseURL.appendingPathComponent("metars"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
        ]
        if let half { comps?.queryItems?.append(URLQueryItem(name: "half", value: String(half))) }
        return try await get(comps?.url)
    }

    /// The radar's wind + boundary-layer sample grid for a map region. The
    /// server quantizes the region and shares one Open-Meteo call per cell.
    func fieldGrid(lat: Double, lon: Double, latSpan: Double, lonSpan: Double) async throws -> FieldGridResponse {
        var comps = URLComponents(url: baseURL.appendingPathComponent("radar/field"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
            URLQueryItem(name: "latSpan", value: String(latSpan)),
            URLQueryItem(name: "lonSpan", value: String(lonSpan)),
        ]
        return try await get(comps?.url)
    }

    /// GOES lightning-mapper flashes over the last 15 minutes around a
    /// point, binned, from the server's memory (it polls NOAA, not the phone).
    func lightning(lat: Double, lon: Double) async throws -> LightningResponse {
        var comps = URLComponents(url: baseURL.appendingPathComponent("lightning"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
        ]
        return try await get(comps?.url)
    }

    /// WPC surface fronts: analysis + forecast positions. Failure just means
    /// the fronts layer stays empty.
    func fronts() async throws -> FrontsResponse {
        try await get(baseURL.appendingPathComponent("fronts"))
    }

    /// Isobars, isallobars, and the gridded fields for a map region, from
    /// the server's station table (no upstream call).
    func pressureField(lat: Double, lon: Double, latSpan: Double, lonSpan: Double) async throws -> PressureFieldResponse {
        var comps = URLComponents(url: baseURL.appendingPathComponent("radar/pressure"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
            URLQueryItem(name: "latSpan", value: String(latSpan)),
            URLQueryItem(name: "lonSpan", value: String(lonSpan)),
        ]
        return try await get(comps?.url)
    }

    /// The vertical column at a point: clouds, temperatures and wind by
    /// model level, hourly for a day. The server keys it by tenth-degree
    /// cell and refreshes hourly.
    func aloft(lat: Double, lon: Double) async throws -> AloftResponse {
        var comps = URLComponents(url: baseURL.appendingPathComponent("aloft"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
        ]
        return try await get(comps?.url)
    }

    /// RainViewer's frame list, trimmed and cached by the backend.
    func radarFrames() async throws -> RadarFramesResponse {
        try await get(baseURL.appendingPathComponent("radar/frames"))
    }

    /// Latest HRRR run for forecast-radar frames. 503/failure just means the
    /// radar timeline ends at the RainViewer nowcast.
    func hrrrRun() async throws -> HrrrMeta {
        try await get(baseURL.appendingPathComponent("radar/hrrr"))
    }

    /// Station search by ICAO prefix or name (METAR-issuing sites only).
    func searchStations(_ q: String) async throws -> [StationSearchResult] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("stations/search"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "q", value: q)]
        let resp: StationSearchResponse = try await get(comps?.url)
        return resp.results
    }

    /// Location → nearest known station (brief Phase 3 resolution helper).
    func nearestStation(lat: Double, lon: Double) async throws -> NearestStation {
        var comps = URLComponents(url: baseURL.appendingPathComponent("stations/nearest"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
        ]
        return try await get(comps?.url)
    }

    /// One MetricKit payload to the server's drop box. Fire and forget:
    /// the caller never waits on it and a failure is not retried; MetricKit
    /// hands the same report over again next time if it was not consumed.
    func postDiagnostics(_ body: Data, kind: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("diagnostics"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(kind, forHTTPHeaderField: "X-Barry-Kind")
        req.httpBody = body
        let (_, response) = try await Self.patientSession.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    private func get<T: Decodable>(_ url: URL?) async throws -> T {
        guard let url else { throw APIError.badURL }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.http(-1)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(http.statusCode)
            }
            do {
                return try Self.decoder.decode(T.self, from: data)
            } catch {
                throw APIError.decoding(error)
            }
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.transport(error)
        }
    }
}

struct NearestStation: Codable, Hashable {
    let station: String
    let name: String
    let lat: Double
    let lon: Double
    let distance_km: Double
}
