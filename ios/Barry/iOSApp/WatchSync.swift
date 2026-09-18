//  WatchSync.swift
//  Barry — iOS
//
//  Pushes the phone's choice of station, and whether that choice is an
//  airport, to the watch. App Groups are device-local, so without this the
//  watch only ever knew the default station and could never honor "an
//  airport is selected". Application context is latest-wins and is stored
//  by the system until the watch app next runs, so nothing here has to wait
//  for the watch to be awake.

import Foundation
import WatchConnectivity

final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()

    private var pending: [String: Any]?

    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        if s.activationState != .activated { s.activate() }
    }

    /// Tell the watch which station the phone is on and whether it is a
    /// chosen airport. Safe to call often: an unchanged context is a no-op.
    func send(station: String, airportSelected: Bool, physical: Bool,
              backcountry: Bool, watchSensor: Bool) {
        guard WCSession.isSupported() else { return }
        let ctx: [String: Any] = [AppConfig.syncStationKey: station,
                                  AppConfig.syncAirportSelectedKey: airportSelected,
                                  AppConfig.syncPhysicalKey: physical,
                                  AppConfig.syncBackcountryKey: backcountry,
                                  AppConfig.syncWatchSensorKey: watchSensor]
        let s = WCSession.default
        guard s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else {
            pending = ctx
            return
        }
        let current = s.applicationContext
        if current[AppConfig.syncStationKey] as? String == station,
           current[AppConfig.syncAirportSelectedKey] as? Bool == airportSelected,
           current[AppConfig.syncPhysicalKey] as? Bool == physical,
           current[AppConfig.syncBackcountryKey] as? Bool == backcountry,
           current[AppConfig.syncWatchSensorKey] as? Bool == watchSensor {
            return
        }
        try? s.updateApplicationContext(ctx)
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        guard state == .activated, let ctx = pending else { return }
        pending = nil
        if session.isPaired, session.isWatchAppInstalled {
            try? session.updateApplicationContext(ctx)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // A watch switch: the session must be re-activated for the new watch.
        session.activate()
    }
}
