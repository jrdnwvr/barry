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
    @AppStorage(StormAlerter.pressureKey, store: AppConfig.sharedDefaults)
    private var pressureAlertsEnabled: Bool = false
    @AppStorage("hasOnboarded", store: AppConfig.sharedDefaults)
    private var hasOnboarded: Bool = false

    init() {
        // A UI test run starts from a known state: onboarded, KLUK selected,
        // the radar's default layers. Nothing else reads this flag.
        if UITestSupport.active { UITestSupport.prepare() }
        StormAlerter.migrateKeys()
        // MetricKit's daily launch, hang, crash and battery reports go to
        // Barry's own server. See Diagnostics.swift and the privacy page.
        DiagnosticsReporter.shared.start()
        // Let storm alerts surface as banners even while the app is open.
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        // RainViewer serves every radar tile with a two day max-age and an
        // ETag. The default shared cache is too small to keep more than a
        // screenful, so a tile evicted from memory went back to the network.
        URLCache.shared = URLCache(memoryCapacity: 16 << 20, diskCapacity: 200 << 20)
    }

    var body: some Scene {
        WindowGroup {
            // First run shows onboarding as the root (not a cover) so nothing —
            // station lookup, location prompt — starts until the user is through.
            Group {
                if hasOnboarded {
                    ContentView()
                } else {
                    OnboardingView()
                }
            }
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
                        if phoneBarometerEnabled || stormAlertsEnabled || pressureAlertsEnabled {
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
                                        pressureAlertsEnabled: pressureAlertsEnabled,
                                        stormAlertsEnabled: stormAlertsEnabled)
            BackgroundRefresh.schedule()  // chain the next opportunistic refresh
        }
    }
}
