//  BackgroundRefresh.swift
//  Barry — iOS
//
//  Opportunistic background refresh via BGAppRefreshTask. When iOS grants us a
//  background slot it: (1) re-fetches the METAR for the last station (which updates
//  the cached snapshot the complication reads), and (2) if the live sensor feature
//  is on, folds a fresh *stationary* barometer reading into the calibration.
//
//  IMPORTANT: `earliestBeginDate` is a floor + hint, not a schedule. iOS decides the
//  real cadence from usage and battery, so 30 min is a best case — often longer, and
//  effectively never while the phone is unused. This adds sparse calibration points;
//  it is NOT a continuous background stream (that would need the location mode).

import BackgroundTasks
import Foundation

enum BackgroundRefresh {
    static let taskID = "me.wvr.barry.refresh"
    static let interval: TimeInterval = 30 * 60  // earliest, not guaranteed

    /// Submit the next refresh request. Safe to call repeatedly (a duplicate just
    /// replaces the pending request). No-op on the Simulator / when disabled.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // BGTaskScheduler is unavailable on the Simulator and throws if the
            // identifier isn't permitted; nothing actionable at runtime.
        }
    }

    /// The work performed when the task fires. Kept @MainActor since it drives the
    /// (main-actor) store + barometer. Network + a ~3 s sensor sample fit easily in
    /// the task's runtime budget.
    @MainActor
    static func run(store: PressureStore, barometer: BarometerManager,
                    sensorEnabled: Bool, stormAlertsEnabled: Bool) async {
        await store.load()
        if sensorEnabled, let slp = store.combined?.currentPressure {
            await barometer.recalibrateInBackground(metarSLP: slp)
        }
        // Fresh reading in hand — check whether it just turned stormy.
        await StormAlerter.evaluate(store.combined, enabled: stormAlertsEnabled)
    }
}
