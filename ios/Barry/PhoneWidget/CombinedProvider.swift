//  CombinedProvider.swift
//  Barry — iPhone Widget
//
//  One provider for the card widgets. Answers at once from the payload the
//  app last saved, refreshes behind that when it is older than 15 minutes
//  and asks for a redraw when the fetch lands. Only a phone with no saved
//  payload at all waits on the network, and then eight seconds at most.

import WidgetKit

struct CombinedEntry: TimelineEntry {
    let date: Date
    let combined: CombinedResponse?
    let savedAt: Date?
    let atAirport: Bool

    static let placeholder = CombinedEntry(date: Date(), combined: nil, savedAt: nil, atAirport: false)

    /// Past two hours the widget says "as of" and drops its colors.
    var isStale: Bool {
        guard let savedAt else { return true }
        return date.timeIntervalSince(savedAt) > 2 * 3600
    }
}

struct CombinedProvider: TimelineProvider {
    func placeholder(in context: Context) -> CombinedEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (CombinedEntry) -> Void) {
        completion(Self.entry(from: CombinedStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CombinedEntry>) -> Void) {
        let now = Date()
        if let stored = CombinedStore.load() {
            completion(Timeline(entries: [Self.entry(from: stored)], policy: .after(now.addingTimeInterval(20 * 60))))
            if now.timeIntervalSince(stored.savedAt) >= 15 * 60 {
                Task {
                    if await Self.fetchAndSave(station: stored.station, timeout: 8) != nil {
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }
            }
            return
        }
        Task {
            let station = SnapshotStore.load()?.station
                ?? AppConfig.sharedDefaults.string(forKey: AppConfig.syncStationKey)
                ?? AppConfig.defaultStation
            let stored = await Self.fetchAndSave(station: station, timeout: 8)
            let retry = stored == nil ? 2 * 60.0 : 20 * 60.0
            completion(Timeline(entries: [Self.entry(from: stored)], policy: .after(Date().addingTimeInterval(retry))))
        }
    }

    private static func entry(from stored: CombinedStore.Stored?) -> CombinedEntry {
        CombinedEntry(date: Date(), combined: stored?.combined, savedAt: stored?.savedAt,
                      atAirport: SnapshotStore.load()?.atAirport ?? false)
    }

    private static func fetchAndSave(station: String, timeout: TimeInterval) async -> CombinedStore.Stored? {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 4
        let api = BarryAPI(session: URLSession(configuration: cfg))
        guard let combined = try? await api.combined(station: station, lat: nil, lon: nil) else { return nil }
        CombinedStore.save(combined)
        return CombinedStore.load()
    }
}
