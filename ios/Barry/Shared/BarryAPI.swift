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
        case .transport: return "Network problem — check your connection."
        }
    }
}

struct BarryAPI {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL = AppConfig.backendBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    private static let decoder: JSONDecoder = {
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
        comps?.queryItems = items
        return try await get(comps?.url)
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
