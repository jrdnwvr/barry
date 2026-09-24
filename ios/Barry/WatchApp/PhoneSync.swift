//  PhoneSync.swift
//  Barry — watchOS
//
//  Receives the phone's station and airport choice (WatchSync on iOS) and
//  writes both into this device's App Group store, where the watch app and
//  the complication's own fetch read them. The last context the phone sent
//  is also available at launch, so a watch that was asleep catches up.

import Foundation
import WatchConnectivity

@MainActor
final class PhoneSync: NSObject, WCSessionDelegate {
    static let shared = PhoneSync()

    /// Called on the main actor whenever the phone's choice changes.
    var onUpdate: ((_ station: String, _ airportSelected: Bool, _ physical: Bool) -> Void)?

    /// Whether the phone is within Bluetooth or Wi-Fi reach right now. False on
    /// a cellular watch left behind; the watch then finds its own station.
    var isPhoneReachable: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        if s.activationState != .activated { s.activate() }
        apply(s.receivedApplicationContext)
    }

    /// The last choice the phone sent, from this device's store.
    static var stored: (station: String, airportSelected: Bool, physical: Bool)? {
        let d = AppConfig.sharedDefaults
        guard let st = d.string(forKey: AppConfig.syncStationKey) else { return nil }
        return (st, d.bool(forKey: AppConfig.syncAirportSelectedKey), d.bool(forKey: AppConfig.syncPhysicalKey))
    }

    private func apply(_ ctx: [String: Any]) {
        guard let station = ctx[AppConfig.syncStationKey] as? String, !station.isEmpty else { return }
        let selected = ctx[AppConfig.syncAirportSelectedKey] as? Bool ?? false
        let physical = ctx[AppConfig.syncPhysicalKey] as? Bool ?? false
        let d = AppConfig.sharedDefaults
        let changed = d.string(forKey: AppConfig.syncStationKey) != station
            || d.bool(forKey: AppConfig.syncAirportSelectedKey) != selected
            || d.bool(forKey: AppConfig.syncPhysicalKey) != physical
        d.set(station, forKey: AppConfig.syncStationKey)
        d.set(selected, forKey: AppConfig.syncAirportSelectedKey)
        d.set(physical, forKey: AppConfig.syncPhysicalKey)
        // Settings the phone owns; the watch's own switches read these keys.
        if let b = ctx[AppConfig.syncBackcountryKey] as? Bool { d.set(b, forKey: AppConfig.syncBackcountryKey) }
        // Only a CHANGE on the phone reaches the watch's own switch; the same
        // context is re-applied at every launch and must not undo a choice
        // made on the wrist.
        if let w = ctx[AppConfig.syncWatchSensorKey] as? Bool,
           (d.object(forKey: AppConfig.syncWatchSensorLastKey) as? Bool) != w {
            d.set(w, forKey: AppConfig.syncWatchSensorKey)
            d.set(w, forKey: AppConfig.syncWatchSensorLastKey)
        }
        if changed { onUpdate?(station, selected, physical) }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        guard state == .activated else { return }
        let ctx = session.receivedApplicationContext
        Task { @MainActor in self.apply(ctx) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext ctx: [String: Any]) {
        Task { @MainActor in self.apply(ctx) }
    }
}
