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
    @AppStorage("watchBarometerEnabled", store: AppConfig.sharedDefaults)
    private var barometerEnabled: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Watch barometer", isOn: $barometerEnabled)
                if barometerEnabled {
                    NavigationLink("Set altimeter by hand") {
                        ManualAltimeterView()
                    }
                }
            } footer: {
                Text("Reads the watch sensor between station reports. Calibrates at a reporting field, or from a setting you enter.")
            }
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

/// A setting heard on the radio, entered with the crown. Seeds the sensor
/// calibration the way a station report would.
struct ManualAltimeterView: View {
    @EnvironmentObject var barometer: WatchBarometer
    @Environment(\.dismiss) private var dismiss
    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var unitRaw: String = PressureUnit.inHg.rawValue
    private var unit: PressureUnit { PressureUnit(rawValue: unitRaw) ?? .inHg }

    /// Picker index; the value is in the user's unit.
    @State private var index: Int = 0
    private var values: [Double] {
        unit == .inHg ? stride(from: 27.50, through: 31.50, by: 0.01).map { $0 }
                      : stride(from: 930.0, through: 1070.0, by: 1.0).map { $0 }
    }
    private var selectedHPa: Double {
        let v = values[min(max(0, index), values.count - 1)]
        return unit == .inHg ? v / 0.0295299830714 : v
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("Altimeter", selection: $index) {
                ForEach(values.indices, id: \.self) { i in
                    Text(String(format: unit == .inHg ? "%.2f" : "%.0f", values[i])).tag(i)
                }
            }
            .labelsHidden()
            .frame(height: 70)
            Button("Use \(String(format: unit == .inHg ? "%.2f" : "%.0f", values[min(max(0, index), values.count - 1)])) \(unit.label)") {
                barometer.calibrate(manualAltim: selectedHPa)
                dismiss()
            }
            .disabled(!barometer.isSteady)
            if !barometer.isSteady {
                Text("Hold still a moment.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Altimeter")
        .onAppear {
            let start = unit == .inHg ? 29.92 : 1013.0
            index = values.firstIndex { abs($0 - start) < 0.001 } ?? values.count / 2
        }
    }
}
