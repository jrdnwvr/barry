//  BarryApp.swift
//  Barry — iOS
//
//  @main entry. iOS 17+.

import SwiftUI

@main
struct BarryApp: App {
    @StateObject private var store = PressureStore()
    @StateObject private var barometer = BarometerManager()

    @AppStorage("phoneBarometerEnabled", store: AppConfig.sharedDefaults)
    private var phoneBarometerEnabled: Bool = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(barometer)
                .onAppear {
                    if phoneBarometerEnabled { barometer.start() }
                }
                .onChange(of: phoneBarometerEnabled) { _, enabled in
                    if enabled { barometer.start() } else { barometer.stop() }
                }
        }
    }
}
