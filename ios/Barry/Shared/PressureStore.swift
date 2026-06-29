//  PressureStore.swift
//  Barry — Shared
//
//  Observable data store shared by the iOS app and the watch app. Resolves the
//  active station (saved home station or nearest to current location), fetches the
//  combined payload, persists a snapshot for the complication, and exposes simple
//  loading/error state for the views.

import Foundation
import SwiftUI
import WidgetKit

@MainActor
final class PressureStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(CombinedResponse)
        case failed(String)
    }

    @Published private(set) var state: LoadState = .idle
    @Published var station: String

    /// "Now" is captured once per load so the chart's now-rule and the
    /// observed/forecast split agree.
    @Published private(set) var now: Date = Date()

    private let api: BarryAPI
    private let location: LocationManager

    init(api: BarryAPI = BarryAPI(),
         location: LocationManager? = nil,
         station: String = SnapshotStore.load()?.station ?? AppConfig.defaultStation) {
        self.api = api
        // Constructed here (in the @MainActor init body) rather than as a default
        // argument — default args evaluate in a nonisolated context and can't call
        // a @MainActor initializer.
        self.location = location ?? LocationManager()
        self.station = station
    }

    var combined: CombinedResponse? {
        if case .loaded(let c) = state { return c }
        return nil
    }

    /// Resolve nearest station from device location, if permitted, and adopt it.
    func resolveStationFromLocation() async {
        guard let loc = await location.requestLocation() else { return }
        await resolveStation(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
    }

    /// Resolve nearest station from an explicit lat/lon (custom saved place).
    /// Decoupled from device location so the same API works for both modes.
    func resolveStation(lat: Double, lon: Double) async {
        if let nearest = try? await api.nearestStation(lat: lat, lon: lon) {
            station = nearest.station
        }
    }

    func load(lat: Double? = nil, lon: Double? = nil) async {
        state = .loading
        now = Date()
        do {
            let combined = try await api.combined(station: station, lat: lat, lon: lon)
            state = .loaded(combined)
            // Hand the complication a fresh snapshot and nudge it to redraw.
            SnapshotStore.save(TendencySnapshot(from: combined, updatedAt: now))
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            let message = (error as? APIError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
        }
    }
}
