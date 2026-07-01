//  SettingsView.swift
//  Barry — iOS
//
//  Settings (brief §6): unit, then a "where to read pressure" picker with three
//  modes — device location, a saved geocoded place, or an explicit airport.
//  The chosen mode drives only the *station/forecast lookup*. Any local sensor
//  reading from the iPhone barometer (CMAltimeter, future) stays tied to the
//  device and is intentionally NOT controlled here.

import CoreLocation
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var store: PressureStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var unitRaw: String = PressureUnit.hPa.rawValue
    @AppStorage("windUnit", store: AppConfig.sharedDefaults)
    private var windUnitRaw: String = WindUnit.kmh.rawValue
    @AppStorage("locationMode", store: AppConfig.sharedDefaults)
    private var locationModeRaw: String = LocationMode.device.rawValue
    @AppStorage("homeStation", store: AppConfig.sharedDefaults)
    private var homeStation: String = AppConfig.defaultStation
    @AppStorage("placeLabel", store: AppConfig.sharedDefaults)
    private var placeLabel: String = ""
    @AppStorage("placeLat", store: AppConfig.sharedDefaults)
    private var placeLat: Double = 0
    @AppStorage("placeLon", store: AppConfig.sharedDefaults)
    private var placeLon: Double = 0

    @AppStorage("phoneBarometerEnabled", store: AppConfig.sharedDefaults)
    private var phoneBarometerEnabled: Bool = false
    @AppStorage(StormAlerter.enabledKey, store: AppConfig.sharedDefaults)
    private var stormAlertsEnabled: Bool = false

    @State private var placeQuery: String = ""
    @State private var geocodeError: String?
    @State private var isGeocoding = false
    @State private var notifDenied = false

    private var locationMode: LocationMode {
        LocationMode(rawValue: locationModeRaw) ?? .device
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Live phone sensor", isOn: $phoneBarometerEnabled)
                    Text("Supplements METAR reports with a calibrated local reading between updates. Motion gating (§4.5.3) prevents elevator and driving spikes from registering as weather. Off by default — only useful when stationary with a clear sky view. Requires a physical device; has no effect on the simulator.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Phone barometer")
                }

                Section {
                    Toggle("Storm alerts", isOn: $stormAlertsEnabled)
                    Text("Notifies you when pressure changes fast — a sharp drop (storm approaching) or a sharp rise (gust front / clearing). Checked opportunistically in the background, so timing depends on iOS and it won't be instant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if notifDenied {
                        Text("Notifications are turned off for Barry. Turn them on in iOS Settings › Notifications › Barry.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if stormAlertsEnabled && !notifDenied {
                        Button("Send a test alert") { StormAlerter.sendTestAlert() }
                    }
                } header: {
                    Text("Storm alerts")
                }
                .onChange(of: stormAlertsEnabled) { _, on in
                    if on { Task { notifDenied = !(await StormAlerter.requestAuthorization()) } }
                }
                .task { notifDenied = await StormAlerter.authorizationStatus() == .denied }

                Section("Units") {
                    Picker("Pressure", selection: $unitRaw) {
                        ForEach(PressureUnit.allCases) { u in
                            Text(u.label).tag(u.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Wind", selection: $windUnitRaw) {
                        ForEach(WindUnit.allCases) { u in
                            Text(u.label).tag(u.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Where to read pressure") {
                    Picker("Source", selection: $locationModeRaw) {
                        ForEach(LocationMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch locationMode {
                    case .device:
                        Text("Barry will resolve the nearest reporting station from your current location each time you refresh.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .place:
                        placeSection
                    case .airport:
                        airportSection
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task { await applyAndDismiss() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var placeSection: some View {
        if !placeLabel.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(placeLabel).font(.body)
                Text("\(placeLat, specifier: "%.3f"), \(placeLon, specifier: "%.3f")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        HStack {
            TextField("City, address, or airport", text: $placeQuery)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { geocode() }
            Button("Search") { geocode() }
                .buttonStyle(.bordered)
                .disabled(placeQuery.trimmingCharacters(in: .whitespaces).isEmpty || isGeocoding)
        }
        if isGeocoding {
            ProgressView().controlSize(.small)
        }
        if let err = geocodeError {
            Text(err).font(.caption).foregroundStyle(.red)
        }
        Text("Barry will look up the nearest reporting station near this point. The station data still comes from an airport, so it can be a few miles from your saved place.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var airportSection: some View {
        TextField("ICAO (e.g. KLUK)", text: $homeStation)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
        Text("Use an exact ICAO code when you want a specific reporting station, regardless of where you are.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func geocode() {
        let query = placeQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        geocodeError = nil
        isGeocoding = true
        Task {
            let geocoder = CLGeocoder()
            do {
                let placemarks = try await geocoder.geocodeAddressString(query)
                guard let pm = placemarks.first, let loc = pm.location else {
                    isGeocoding = false
                    geocodeError = "No match found."
                    return
                }
                placeLat = loc.coordinate.latitude
                placeLon = loc.coordinate.longitude
                let parts = [pm.locality, pm.administrativeArea, pm.country]
                    .compactMap { $0 }
                let labelFromPlace = parts.isEmpty ? (pm.name ?? query) : parts.joined(separator: ", ")
                placeLabel = labelFromPlace
                placeQuery = ""
                isGeocoding = false
            } catch {
                isGeocoding = false
                geocodeError = error.localizedDescription
            }
        }
    }

    private func applyAndDismiss() async {
        switch locationMode {
        case .device:
            await store.resolveStationFromLocation()
            await store.load()
        case .place:
            await store.resolveStation(lat: placeLat, lon: placeLon)
            await store.load(lat: placeLat, lon: placeLon)
        case .airport:
            store.station = homeStation.uppercased()
            await store.load()
        }
        dismiss()
    }
}
