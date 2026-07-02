//  TendencyProvider.swift
//  Barry — Watch Complication
//
//  TimelineProvider pulling the cached tendency snapshot (brief §5, Phase 5).
//  watchOS limits background refreshes, so we design for ~20-min updates and lean
//  on the App Group snapshot written by the app rather than fetching here every
//  time (brief §7 — "don't promise live").

import WidgetKit
import SwiftUI

struct TendencyEntry: TimelineEntry {
    let date: Date
    let snapshot: TendencySnapshot?

    static let placeholder = TendencyEntry(
        date: Date(),
        snapshot: nil
    )
}

struct TendencyProvider: TimelineProvider {
    func placeholder(in context: Context) -> TendencyEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (TendencyEntry) -> Void) {
        completion(TendencyEntry(date: Date(), snapshot: SnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TendencyEntry>) -> Void) {
        // The complication feeds ITSELF: the watch app only writes the shared
        // snapshot when it's foregrounded, so relying on it alone leaves the
        // complication stale for anyone who doesn't open the app (i.e. everyone the
        // complication is working for). Fetch here — on watchOS, URLSession routes
        // via the paired iPhone when the watch has no direct connection — and fall
        // back to the cached snapshot when offline. WidgetKit's refresh budget
        // (~every 20+ min on an active face) sets the effective cadence.
        Task {
            let snapshot = await Self.freshestSnapshot()
            let now = Date()
            let next = now.addingTimeInterval(20 * 60)
            completion(Timeline(entries: [TendencyEntry(date: now, snapshot: snapshot)],
                                policy: .after(next)))
        }
    }

    /// Cached snapshot if it's recent; otherwise a short-timeout backend fetch for
    /// the last-known station, persisting the result (so the watch app opens fresh
    /// too). Any failure returns the cache — views mark it stale past 2 h.
    private static func freshestSnapshot() async -> TendencySnapshot? {
        let cached = SnapshotStore.load()
        // Fresh enough → don't spend widget budget / battery on a fetch.
        if let cached, !cached.isStale(asOf: Date()),
           Date().timeIntervalSince(cached.updatedAt) < 15 * 60 {
            return cached
        }

        let station = cached?.station
            ?? AppConfig.sharedDefaults.string(forKey: "homeStation")
            ?? AppConfig.defaultStation

        // Widget runtime is wall-clock limited — keep timeouts tight.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        let api = BarryAPI(session: URLSession(configuration: cfg))

        guard let combined = try? await api.combined(station: station, lat: nil, lon: nil)
        else { return cached }  // offline / backend down → last known, honestly aged

        let snap = TendencySnapshot(from: combined)
        SnapshotStore.save(snap)
        return snap
    }
}
