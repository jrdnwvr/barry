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
        //
        // Never block on the network when there is something to show: WidgetKit
        // gives a watch extension only seconds, and a fetch that outruns that
        // leaves the slot on the redacted placeholder (a grey disc) for good.
        // With a cached snapshot the entry goes back at once, stale or not (the
        // views say "Stale" past 2 h), and a refresh runs behind it, saving the
        // snapshot and asking for a reload when it lands. Only a watch with no
        // snapshot at all waits, and then briefly.
        let now = Date()
        if let cached = SnapshotStore.load() {
            completion(Timeline(entries: [TendencyEntry(date: now, snapshot: cached)],
                                policy: .after(now.addingTimeInterval(20 * 60))))
            if now.timeIntervalSince(cached.updatedAt) >= 15 * 60 {
                Task {
                    if await Self.fetchAndSave(cached: cached) != nil {
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                }
            }
            return
        }
        Task {
            let snapshot = await Self.fetchAndSave(cached: nil, timeout: 5)
            // Nothing yet: try again soon rather than in twenty minutes.
            let retry = snapshot == nil ? 2 * 60.0 : 20 * 60.0
            completion(Timeline(entries: [TendencyEntry(date: Date(), snapshot: snapshot)],
                                policy: .after(Date().addingTimeInterval(retry))))
        }
    }

    /// A short-timeout backend fetch for the last-known station, persisted so
    /// the watch app opens fresh too. nil when it fails; callers keep the cache.
    private static func fetchAndSave(cached: TendencySnapshot?, timeout: TimeInterval = 8) async -> TendencySnapshot? {
        let station = cached?.station
            ?? AppConfig.sharedDefaults.string(forKey: "homeStation")
            ?? AppConfig.defaultStation

        // Widget runtime is wall-clock limited — keep timeouts tight.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 4
        let api = BarryAPI(session: URLSession(configuration: cfg))

        guard let combined = try? await api.combined(station: station, lat: nil, lon: nil)
        else { return nil }  // offline / backend down

        // The widget has no location: a chosen airport (synced from the
        // phone) counts, otherwise keep the app's last 3 NM judgement.
        let selected = AppConfig.sharedDefaults.bool(forKey: AppConfig.syncAirportSelectedKey)
        var snap = TendencySnapshot(from: combined, atAirport: selected || (cached?.atAirport ?? false))
        // The widget has no sensor either; carry the app's last local reading.
        snap.localDisplayHPa = cached?.localDisplayHPa
        snap.localAt = cached?.localAt
        SnapshotStore.save(snap)
        return snap
    }
}
