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
    @EnvironmentObject var savedLocations: SavedLocationsStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var unitRaw: String = PressureUnit.inHg.rawValue
    @AppStorage("windUnit", store: AppConfig.sharedDefaults)
    private var windUnitRaw: String = WindUnit.mph.rawValue

    @EnvironmentObject var barometer: BarometerManager
    @AppStorage("phoneBarometerEnabled", store: AppConfig.sharedDefaults)
    private var phoneBarometerEnabled: Bool = false
    @AppStorage(StormAlerter.enabledKey, store: AppConfig.sharedDefaults)
    private var stormAlertsEnabled: Bool = false

    @State private var newICAO: String = ""
    @State private var icaoError: String?
    @State private var isValidatingICAO = false
    @State private var placeQuery: String = ""
    @State private var geocodeError: String?
    @State private var isGeocoding = false
    @State private var notifDenied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Live phone sensor", isOn: $phoneBarometerEnabled)
                    Text("Uses your phone's barometer for live readings between station reports. It calibrates itself against the station and ignores readings from elevators and driving.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Phone barometer")
                }

                Section {
                    Toggle("Storm alerts", isOn: $stormAlertsEnabled)
                    Text("Sends a notification when pressure changes fast. A sharp drop usually means a storm, and a sharp rise can mean gusty wind. iOS decides when background checks run, so alerts won't be instant.")
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

                Section {
                    ForEach(savedLocations.locations) { loc in
                        Button {
                            savedLocations.selectedID = loc.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(loc.title)
                                        .foregroundStyle(.primary)
                                    if let sub = loc.subtitle {
                                        Text(sub)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if loc.id == savedLocations.selectedID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                    .onDelete { savedLocations.remove(at: $0) }

                    HStack {
                        TextField("Add airport (ICAO, e.g. KLUK)", text: $newICAO)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .onSubmit { addAirport() }
                        if isValidatingICAO {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Add") { addAirport() }
                                .buttonStyle(.bordered)
                                .disabled(!icaoLooksValid)
                        }
                    }
                    if let err = icaoError {
                        Text(err).font(.caption).foregroundStyle(.orange)
                    }

                    HStack {
                        TextField("Add a place (city or address)", text: $placeQuery)
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

                    Text("Tap to switch. Swipe to remove. My location stays pinned and is the only place the phone's own barometer applies.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Locations")
                }

                // Dev-only helpers — compiled out of Release/TestFlight builds so
                // testers can't seed fake readings into their real data. Collapsed
                // by default so day-to-day settings visits don't wade through it.
                #if DEBUG
                Section {
                    DisclosureGroup("Testing") {
                        Button("Load 48h sample history") {
                            let obs = store.combined?.observedSeries
                                .compactMap { p in p.pressure.map { (p.t, $0) } } ?? []
                            barometer.loadSampleHistory(observed: obs, now: store.now)
                        }
                        Button("Clear phone history", role: .destructive) {
                            barometer.clearHistory()
                        }
                        Button("Show onboarding again") {
                            AppConfig.sharedDefaults.set(false, forKey: "hasOnboarded")
                            dismiss()
                        }
                        Button("Show sample front watch") {
                            store.loadSampleFront()
                            dismiss()
                        }
                        Button("Clear sample front watch") {
                            store.clearSampleFront()
                        }
                        Text("Fills history with METAR data for UI testing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                #endif
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

    private var icaoLooksValid: Bool {
        let s = newICAO.trimmingCharacters(in: .whitespaces)
        return s.count >= 3 && s.count <= 4 && s.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private func addAirport() {
        guard icaoLooksValid, !isValidatingICAO else { return }
        let icao = newICAO.trimmingCharacters(in: .whitespaces).uppercased()
        icaoError = nil
        isValidatingICAO = true
        Task {
            defer { isValidatingICAO = false }
            do {
                // The backend normalizes the identifier (I67 -> KI67, CVG ->
                // KCVG); save the canonical form it reports back.
                let combined = try await BarryAPI().combined(station: icao, lat: nil, lon: nil)
                if combined.pressure.series.isEmpty {
                    icaoError = "\(icao) doesn't report weather. Try a nearby reporting airport, or add it as a place and Barry will use the nearest station."
                    return
                }
                savedLocations.add(SavedLocation(kind: .airport(icao: combined.pressure.station)))
                newICAO = ""
            } catch {
                // Can't reach the backend to check — add as typed rather than block.
                savedLocations.add(SavedLocation(kind: .airport(icao: icao)))
                newICAO = ""
            }
        }
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
                let parts = [pm.locality, pm.administrativeArea, pm.country]
                    .compactMap { $0 }
                let label = parts.isEmpty ? (pm.name ?? query) : parts.joined(separator: ", ")
                savedLocations.add(SavedLocation(kind: .place(
                    lat: loc.coordinate.latitude,
                    lon: loc.coordinate.longitude,
                    label: label)))
                placeQuery = ""
                isGeocoding = false
            } catch {
                isGeocoding = false
                geocodeError = error.localizedDescription
            }
        }
    }

    private func applyAndDismiss() async {
        // Selection changes reload via ContentView's onChange; Done just closes.
        dismiss()
    }
}
