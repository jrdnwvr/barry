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
        let now = Date()
        let entry = TendencyEntry(date: now, snapshot: SnapshotStore.load())
        // Ask the system to refresh in ~20 min. The app refreshes the snapshot when
        // it's foregrounded and calls WidgetCenter.reloadAllTimelines(); this cadence
        // is the realistic background floor, not a live feed.
        let next = now.addingTimeInterval(20 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}
