//  CombinedStore.swift
//  Barry — Shared
//
//  The last /combined payload the app fetched, on disk in the App Group
//  container, so the home screen widgets draw the same cards the app does
//  without their own fetch. Dates are stored as epoch seconds both ways,
//  independent of the API's wire format.

import Foundation

enum CombinedStore {
    struct Stored: Codable {
        let savedAt: Date
        let station: String
        let combined: CombinedResponse
    }

    private static let filename = "combined.json"

    private static var url: URL? {
        let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return dir?.appendingPathComponent(filename)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    static func save(_ combined: CombinedResponse, at date: Date = Date()) {
        guard let url, let data = try? encoder.encode(Stored(savedAt: date, station: combined.pressure.station, combined: combined))
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> Stored? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Stored.self, from: data)
    }
}
