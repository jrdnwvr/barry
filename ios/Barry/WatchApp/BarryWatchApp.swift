//  BarryWatchApp.swift
//  Barry — watchOS
//
//  @main entry for the watch app. watchOS 10+.

import SwiftUI

@main
struct BarryWatchApp: App {
    @StateObject private var store = PressureStore()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(store)
        }
    }
}
