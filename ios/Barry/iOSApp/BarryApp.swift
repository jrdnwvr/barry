//  BarryApp.swift
//  Barry — iOS
//
//  @main entry. iOS 17+.

import SwiftUI

@main
struct BarryApp: App {
    @StateObject private var store = PressureStore()
    @StateObject private var barometer = BarometerManager()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("phoneBarometerEnabled", store: AppConfig.sharedDefaults)
    private var phoneBarometerEnabled: Bool = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(barometer)
                .onChange(of: scenePhase) { _, phase in
                    // Run the sensor only while the app is in front; iOS suspends it
                    // in the background anyway, so stop to save battery and restart
                    // cleanly on return.
                    switch phase {
                    case .active:
                        if phoneBarometerEnabled { barometer.start() }
                    case .background:
                        barometer.stop()
                        // Only ask for background slots when the sensor feature is on.
                        if phoneBarometerEnabled { BackgroundRefresh.schedule() }
                    default:
                        break
                    }
                }
                .onChange(of: phoneBarometerEnabled) { _, enabled in
                    if enabled { barometer.start() } else { barometer.stop() }
                }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.taskID)) {
            await BackgroundRefresh.run(store: store, barometer: barometer,
                                        sensorEnabled: phoneBarometerEnabled)
            BackgroundRefresh.schedule()  // chain the next opportunistic refresh
        }
    }
}
