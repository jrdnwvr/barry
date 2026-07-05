//  ContentView.swift
//  Barry — iOS
//
//  Full app screen: verdict header, the hero −24/+24 pressure chart, confirmation
//  overlays, the forecast caveat, and a settings sheet (brief Phases 3 & 6).

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: PressureStore
    @EnvironmentObject var barometer: BarometerManager
    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var unitRaw: String = PressureUnit.inHg.rawValue
    @AppStorage("locationMode", store: AppConfig.sharedDefaults)
    private var locationModeRaw: String = LocationMode.device.rawValue
    @AppStorage("homeStation", store: AppConfig.sharedDefaults)
    private var homeStation: String = AppConfig.defaultStation
    @AppStorage("placeLat", store: AppConfig.sharedDefaults)
    private var placeLat: Double = 0
    @AppStorage("placeLon", store: AppConfig.sharedDefaults)
    private var placeLon: Double = 0
    @AppStorage("phoneBarometerEnabled", store: AppConfig.sharedDefaults)
    private var phoneBarometerEnabled: Bool = false
    @AppStorage("chartWindow", store: AppConfig.sharedDefaults)
    private var chartWindowRaw: String = ChartWindow.hours6.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    private var unit: PressureUnit { PressureUnit(rawValue: unitRaw) ?? .inHg }
    private var chartWindow: ChartWindow { ChartWindow(rawValue: chartWindowRaw) ?? .hours6 }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.horizontal)
            }
            .navigationTitle("Barry")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .refreshable { await reload() }
            .task { await initialLoad() }
            // Keep the reading live while the app is open. Keyed on scenePhase so the
            // loop only runs while frontmost — it stops the moment the app is dimmed
            // away / backgrounded, so the screen still sleeps normally and no work
            // happens in your pocket.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    if Task.isCancelled { break }
                    await reload()
                }
            }
            // Refresh each time the app returns to the foreground (silent — the
            // on-screen reading stays put instead of flashing a spinner).
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, store.combined != nil {
                    Task { await reload() }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            ProgressView("Reading the barometer…")
                .frame(maxWidth: .infinity, minHeight: 320)
        case .failed(let message):
            ErrorStateView(message: message) { Task { await reload() } }
                .frame(maxWidth: .infinity, minHeight: 320)
        case .loaded(let combined):
            VStack(alignment: .leading, spacing: 20) {
                // The glance: station, live-aware current value, trend, verdict.
                HeroView(combined: combined, unit: unit, barometer: barometer,
                         now: store.now, barometerEnabled: phoneBarometerEnabled)

                // The focused trend: window toggle + chart + the honest caveat.
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Window", selection: $chartWindowRaw) {
                        ForEach(ChartWindow.allCases) { w in
                            Text(w.label).tag(w.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Chart time window")

                    PressureChartView(
                        combined: combined,
                        now: store.now,
                        unit: unit,
                        // Full persisted history — the chart clips to its window and
                        // splits the line where recording gaps would fake a bridge.
                        phoneTrace: phoneBarometerEnabled ? barometer.phoneHistoryTrace : [],
                        window: chartWindow
                    )
                    // Trigger calibration whenever a fresh combined response arrives.
                    // The obs time makes it one calibration point per METAR report.
                    .onChange(of: combined) { _, newCombined in
                        if let slp = newCombined.currentPressure {
                            barometer.attemptCalibration(
                                metarSLP: slp,
                                observedAt: newCombined.observedSeries.last?.t)
                        }
                    }

                    ForecastCaveatView(combined: combined, now: store.now)
                }

                // Secondary: wind + rain confirmation, always expanded.
                ConfirmationOverlayView(combined: combined, now: store.now)

                // Radar: the sky itself, as corroboration for the trend. Sheet keeps
                // the main screen a glance. Needs station coords to center on.
                if let rlat = combined.pressure.lat, let rlon = combined.pressure.lon {
                    RadarRow(lat: rlat, lon: rlon,
                             stationName: combined.pressure.name ?? combined.pressure.station)
                }

                // Sensor vs Station: a compact entry row — the full comparison panel
                // (windows, legend, Δ, Measure now) lives on its own screen so the
                // default experience stays glance + verdict + chart.
                if phoneBarometerEnabled {
                    SensorStationRow(
                        combined: combined,
                        now: store.now,
                        unit: unit,
                        barometer: barometer
                    )
                }

                DataSourceFootnote(combined: combined)
            }
            .padding(.vertical)
        }
    }

    private func initialLoad() async {
        if store.combined != nil { return }
        await loadForCurrentMode()
    }

    private func reload() async { await loadForCurrentMode(silent: true) }

    private func loadForCurrentMode(silent: Bool = false) async {
        switch LocationMode(rawValue: locationModeRaw) ?? .device {
        case .device:
            await store.resolveStationFromLocation()
            await store.load(silent: silent)
        case .place:
            await store.resolveStation(lat: placeLat, lon: placeLon)
            await store.load(lat: placeLat, lon: placeLon, silent: silent)
        case .airport:
            store.station = homeStation.uppercased()
            await store.load(silent: silent)
        }
    }
}

private struct RadarRow: View {
    let lat: Double
    let lon: Double
    let stationName: String
    @State private var showRadar = false

    var body: some View {
        Button { showRadar = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                Text("Radar")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showRadar) {
            RadarView(lat: lat, lon: lon, stationName: stationName)
        }
    }
}

private struct DataSourceFootnote: View {
    let combined: CombinedResponse
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(combined.pressure.name ?? combined.pressure.station) · \(combined.pressure.source)")
            Text("Updated \(combined.pressure.cachedAt.formatted(date: .omitted, time: .shortened))")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

struct ErrorStateView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
