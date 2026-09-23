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
    private var authContinuation: CheckedContinuation<Void, Never>?

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

    /// Request a single location fix. Returns nil if denied/unavailable, and
    /// after `timeout` seconds if no fix arrives — a slow first fix (Wi-Fi-only
    /// iPads, permission dialog pending) must never hang the app's initial load.
    func requestLocation(timeout: TimeInterval = 8) async -> CLLocation? {
        if authorization == .notDetermined {
            // Ask, then wait for the answer before asking for a fix: a fix
            // requested while the prompt is still up fails at once as
            // "denied", which used to send every first launch to the default
            // station whatever the user tapped.
            requestAuthorization()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                authContinuation = cont
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.authContinuation?.resume()
                        self?.authContinuation = nil
                    }
                }
            }
        }
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else { return nil }
        // A second caller supersedes the first — resume the old continuation
        // (with the best we have) instead of leaking it, which would hang that
        // caller's task forever.
        continuation?.resume(returning: lastLocation)
        continuation = nil

        return await withCheckedContinuation { cont in
            self.continuation = cont
            manager.requestLocation()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.continuation != nil else { return }
                    self.continuation?.resume(returning: self.lastLocation)
                    self.continuation = nil
                }
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status != .notDetermined {
                self.authContinuation?.resume()
                self.authContinuation = nil
            }
        }
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
