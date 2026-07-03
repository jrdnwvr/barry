//  LocationManager.swift
//  Barry — Shared
//
//  Thin CoreLocation wrapper: one-shot "where am I" for nearest-station resolution.
//  Add NSLocationWhenInUseUsageDescription to each app's Info.plist.

import Foundation
import CoreLocation

@MainActor
final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var lastLocation: CLLocation?
    @Published var authorization: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    /// Station lookup only needs ~km fixes; altitude-reference sampling (barometer
    /// calibration) asks for `kCLLocationAccuracyBest` to get a usable vertical fix.
    init(desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyKilometer) {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = desiredAccuracy
        authorization = manager.authorizationStatus
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Request a single location fix. Returns nil if denied/unavailable.
    func requestLocation() async -> CLLocation? {
        if authorization == .notDetermined {
            requestAuthorization()
        }
        return await withCheckedContinuation { cont in
            self.continuation = cont
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.authorization = manager.authorizationStatus }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            self.lastLocation = locations.last
            self.continuation?.resume(returning: locations.last)
            self.continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in
            self.continuation?.resume(returning: nil)
            self.continuation = nil
        }
    }
}
