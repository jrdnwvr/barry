//  PressureStore.swift
//  Barry — Shared
//
//  Observable data store shared by the iOS app and the watch app. Resolves the
//  active station (saved home station or nearest to current location), fetches the
//  combined payload, persists a snapshot for the complication, and exposes simple
//  loading/error state for the views.

import Foundation
import CoreLocation
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
    /// The device's last known position (nil before the first fix).
    var userLocation: CLLocation? { location.lastLocation }

    /// Set by the phone when the saved selection is an airport; the watch
    /// gets the same flag over WatchConnectivity (PhoneSync).
    @Published var airportSelected = false {
        didSet { if airportSelected != oldValue { refreshAirportJudgement() } }
    }

    /// The phone's selection is "My location" (synced to the watch), so the
    /// station is where the wearer physically is. Gates sensor calibration.
    @Published var selectionPhysical = false

    /// The one answer to "is the reading for the field I am at": decided
    /// when data lands and again when a position fix arrives, so the headline,
    /// the snapshot the complication reads, and the watch page never disagree.
    @Published private(set) var atAirport = false

    /// Within this distance of the station, "here" IS the airport.
    static let airportRadiusMeters = 3 * 1852.0

    /// An airport is selected, or the device is within 3 NM of the station:
    /// the headline shows the field's altimeter setting, the map draws the
    /// home station as its own barb, the wind card goes to runway mode.
    func isAtAirport(_ combined: CombinedResponse) -> Bool {
        if airportSelected { return true }
        guard let lat = combined.pressure.lat, let lon = combined.pressure.lon,
              let here = userLocation else { return false }
        return here.distance(from: CLLocation(latitude: lat, longitude: lon)) <= Self.airportRadiusMeters
    }

    /// Ask for a position without changing the station (the watch, which
    /// keeps its station but still wants the 3 NM rule). A fix that changes
    /// the airport judgement rewrites the complication's snapshot.
    func refreshLocation() async {
        _ = await location.requestLocation()
        refreshAirportJudgement()
    }

    /// Re-decide `atAirport` for the loaded data; when the answer changes,
    /// hand the complication a snapshot that says the same thing.
    private func refreshAirportJudgement() {
        guard let c = combined else { return }
        let judged = isAtAirport(c)
        guard judged != atAirport else { return }
        atAirport = judged
        var snap = TendencySnapshot(from: c, updatedAt: now, atAirport: judged)
        if let f = front, f.isActive {
            snap.frontStatus = f.status
            snap.frontCardinal = f.cardinal
            snap.frontBearingDeg = f.bearingDeg
        }
        SnapshotStore.save(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }

    init(api: BarryAPI = BarryAPI(),
         location: LocationManager? = nil,
         station: String = AppConfig.sharedDefaults.string(forKey: AppConfig.syncStationKey)
                           ?? SnapshotStore.load()?.station ?? AppConfig.defaultStation) {
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
            atAirport = isAtAirport(combined)
            #if os(iOS)
            // The home screen widgets draw from this same payload.
            CombinedStore.save(combined, at: now)
            #endif
            // Hand the complication a fresh snapshot and nudge it to redraw.
            SnapshotStore.save(TendencySnapshot(from: combined, updatedAt: now,
                                                atAirport: atAirport))
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
                // Second snapshot with the front watch on it, so the
                // complication can show the arrow (D7). Cheap: same payload
                // plus three fields; the widget gets one more nudge.
                var snap = TendencySnapshot(from: combined, updatedAt: now,
                                            atAirport: atAirport)
                if f.isActive {
                    snap.frontStatus = f.status
                    snap.frontCardinal = f.cardinal
                    snap.frontBearingDeg = f.bearingDeg
                }
                SnapshotStore.save(snap)
                WidgetCenter.shared.reloadAllTimelines()
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
            detail: "Pressure is falling here and at KR6A and KR5A. The pattern is sliding in roughly from the west. In testing, roughly six of ten patterns like this brought a real pressure dip within a day. The rest slid past or fizzled.",
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
