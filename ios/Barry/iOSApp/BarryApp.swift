//  BarryApp.swift
//  Barry — iOS
//
//  @main entry. iOS 17+.

import SwiftUI
import UserNotifications

@main
struct BarryApp: App {
    @StateObject private var store = PressureStore()
    @StateObject private var barometer = BarometerManager()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("phoneBarometerEnabled", store: AppConfig.sharedDefaults)
    private var phoneBarometerEnabled: Bool = false
    @AppStorage(StormAlerter.enabledKey, store: AppConfig.sharedDefaults)
    private var stormAlertsEnabled: Bool = false

    init() {
        // Let storm alerts surface as banners even while the app is open.
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

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
                        // Ask for background slots when either background feature is on.
                        if phoneBarometerEnabled || stormAlertsEnabled {
                            BackgroundRefresh.schedule()
                        }
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
                                        sensorEnabled: phoneBarometerEnabled,
                                        stormAlertsEnabled: stormAlertsEnabled)
            BackgroundRefresh.schedule()  // chain the next opportunistic refresh
        }
    }
}
