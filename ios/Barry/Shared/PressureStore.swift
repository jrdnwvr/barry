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

    /// Front watch (iOS only): the regional tendency-field analysis. nil or
    /// status "none" renders nothing — most days it should be invisible.
    @Published private(set) var front: FrontResponse?

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

    /// Fetch the combined payload. A `silent` refresh (used for the periodic and
    /// return-to-foreground updates) keeps the current reading on screen instead of
    /// flashing the full-screen spinner, and leaves the last good data in place if a
    /// transient refresh fails — so glancing at an open app never blanks out.
    func load(lat: Double? = nil, lon: Double? = nil, silent: Bool = false) async {
        let hadData = combined != nil
        if !(silent && hadData) { state = .loading }
        now = Date()
        do {
            let combined = try await api.combined(station: station, lat: lat, lon: lon)
            state = .loaded(combined)
            // Hand the complication a fresh snapshot and nudge it to redraw.
            SnapshotStore.save(TendencySnapshot(from: combined, updatedAt: now))
            WidgetCenter.shared.reloadAllTimelines()
            #if os(iOS)
            // Front watch rides second so the primary reading never waits on the
            // regional analysis — the banner just appears a beat later. A failed
            // fetch keeps the previous result if it's for the same station (the
            // UI hides it on a station mismatch), so a transient error doesn't
            // make the banner blink.
            if let f = try? await api.front(station: combined.pressure.station,
                                            lat: combined.pressure.lat,
                                            lon: combined.pressure.lon) {
                front = f
            }
            #endif
        } catch {
            if silent && hadData { return }  // keep showing the last good reading
            let message = (error as? APIError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
        }
    }

    #if DEBUG
    /// Seed a fake "approaching from the west" front so the banner, compass, and
    /// copy can be exercised on a calm day. Real fronts are rare; the UI isn't.
    func loadSampleFront() {
        let ring: [FrontStation] = (0..<8).map { i in
            let bearing = Double(i) * 45.0
            let x = 100.0 * sin(bearing * .pi / 180)
            return FrontStation(id: "KR\(i)A", bearingDeg: bearing,
                                distanceKm: Double(60 + i * 20),
                                tendency3h: (-1.0 + 0.015 * x).rounded(toPlaces: 2))
        }
        front = FrontResponse(
            station: combined?.pressure.station ?? station, status: "approaching",
            headline: "Change moving in from the west",
            detail: "Pressure is falling at KR6A and KR5A. The falls are spreading in from the west, and this kind of pattern usually brings the weather with it.",
            bearingDeg: 270, cardinal: "west",
            eta: Date().addingTimeInterval(4.5 * 3600),
            maxFall3h: -2.5, ownDelta3h: -0.8, gradient: 1.5, coherence: 0.92,
            stations: ring, cachedAt: Date())
    }

    func clearSampleFront() { front = nil }
    #endif
}

#if DEBUG
private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let f = pow(10.0, Double(places))
        return (self * f).rounded() / f
    }
}
#endif
