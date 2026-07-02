//  WatchSettingsView.swift
//  Barry — watchOS
//
//  Local settings for the watch app. App Groups are device-local, so the
//  iPhone's unit preference can't reach the watch — the watch keeps its own
//  setting, and the complication reads the same `pressureUnit` key from this
//  device's App Group store.

import SwiftUI

struct WatchSettingsView: View {
    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var unitRaw: String = PressureUnit.inHg.rawValue

    var body: some View {
        Form {
            Section("Pressure unit") {
                Picker("Unit", selection: $unitRaw) {
                    ForEach(PressureUnit.allCases) { u in
                        Text(u.label).tag(u.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .navigationTitle("Settings")
    }
}
