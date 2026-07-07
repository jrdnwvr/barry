//  ContentView.swift
//  Barry — iOS
//
//  Full app screen: verdict header, the hero −24/+24 pressure chart, confirmation
//  overlays, the forecast caveat, and a settings sheet (brief Phases 3 & 6).

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: PressureStore
    @EnvironmentObject var barometer: BarometerManager
    @StateObject private var savedLocations = SavedLocationsStore()
    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var unitRaw: String = PressureUnit.inHg.rawValue
    @AppStorage("phoneBarometerEnabled", store: AppConfig.sharedDefaults)
    private var phoneBarometerEnabled: Bool = false
    @AppStorage("chartWindow", store: AppConfig.sharedDefaults)
    private var chartWindowRaw: String = ChartWindow.hours6.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showSettings = false
    @State private var showRadarFullScreen = false

    private var unit: PressureUnit { PressureUnit(rawValue: unitRaw) ?? .inHg }
    private var chartWindow: ChartWindow { ChartWindow(rawValue: chartWindowRaw) ?? .hours6 }

    /// The phone barometer only means anything where the phone physically is —
    /// viewing a remote station must never show LOCAL readings or, worse, feed a
    /// remote SLP into the calibration (which would corrupt the offset).
    private var isPhysicalSelection: Bool { savedLocations.selected.isPhysical }
    private var localSensorActive: Bool { phoneBarometerEnabled && isPhysicalSelection }

    var body: some View {
        NavigationStack {
            rootContent
            .navigationTitle("Barry")
            .navigationBarTitleDisplayMode(hSizeClass == .regular ? .inline : .automatic)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(savedLocations)
            }
            // Switching locations (from the hero menu or Settings) reloads for
            // the new selection.
            .onChange(of: savedLocations.selectedID) { _, _ in
                Task { await loadForCurrentMode(silent: false) }
            }
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

    /// Regular width (iPad full screen / large Split View) gets the kneeboard
    /// dashboard — everything visible at once, no navigation. Compact width
    /// (iPhone, iPad slide-over) keeps the scrolling glance layout.
    @ViewBuilder
    private var rootContent: some View {
        if hSizeClass == .regular,
           case .loaded(let combined) = store.state,
           !combined.pressure.series.isEmpty {
            dashboard(combined)
        } else {
            ScrollView {
                content
                    .padding(.horizontal)
            }
            .refreshable { await reload() }
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
        case .loaded(let combined) where combined.pressure.series.isEmpty:
            // The station exists as an identifier but nothing reports there —
            // say so instead of rendering a screen of dashes.
            VStack(spacing: 12) {
                Image(systemName: "icloud.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("\(store.station) isn't reporting weather")
                    .font(.headline)
                Text("This field may not have a weather station. Try a nearby reporting airport, or add this spot as a place in Settings and Barry will use the nearest station.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, minHeight: 320)
        case .loaded(let combined):
            VStack(alignment: .leading, spacing: 20) {
                // The glance: station, live-aware current value, trend, verdict.
                // The station row doubles as the saved-locations switcher.
                HeroView(combined: combined, unit: unit, barometer: barometer,
                         now: store.now, barometerEnabled: localSensorActive,
                         locations: savedLocations.locations,
                         selectedLocationID: savedLocations.selectedID,
                         onSelectLocation: { savedLocations.selectedID = $0 })

                // The focused trend: window toggle + chart + the honest caveat.
                trendSection(combined)

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
                // default experience stays glance + verdict + chart. Physical
                // location only: comparing the pocket barometer to a remote
                // station is meaningless.
                if localSensorActive {
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

    /// Window picker + chart + caveat — shared by the phone layout and the iPad
    /// dashboard, including the calibration trigger.
    private func trendSection(_ combined: CombinedResponse) -> some View {
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
                // Local trace only at the physical location.
                phoneTrace: localSensorActive ? barometer.phoneHistoryTrace : [],
                window: chartWindow
            )
            // Trigger calibration whenever a fresh combined response arrives.
            // Physical location ONLY: a remote station's SLP fed into the
            // calibration would corrupt the offset (and trip the altitude-
            // jump reset). The obs time keeps it one point per METAR.
            .onChange(of: combined) { _, newCombined in
                guard isPhysicalSelection else { return }
                if let slp = newCombined.currentPressure {
                    barometer.attemptCalibration(
                        metarSLP: slp,
                        observedAt: newCombined.observedSeries.last?.t)
                }
            }

            ForecastCaveatView(combined: combined, now: store.now)
        }
    }

    /// The iPad kneeboard dashboard: METAR strip across the top, the glance rail
    /// on the left, and the chart + live radar filling the rest. Everything at
    /// once — the pilot use case inverts "glance then drill in".
    private func dashboard(_ combined: CombinedResponse) -> some View {
        VStack(spacing: 12) {
            MetarStrip(combined: combined)

            HStack(alignment: .top, spacing: 16) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        HeroView(combined: combined, unit: unit, barometer: barometer,
                                 now: store.now, barometerEnabled: localSensorActive,
                                 locations: savedLocations.locations,
                                 selectedLocationID: savedLocations.selectedID,
                                 onSelectLocation: { savedLocations.selectedID = $0 })

                        ConfirmationOverlayView(combined: combined, now: store.now)

                        if localSensorActive {
                            SensorStationRow(combined: combined, now: store.now,
                                             unit: unit, barometer: barometer)
                        }

                        DataSourceFootnote(combined: combined)
                    }
                }
                .frame(width: 340)
                .refreshable { await reload() }

                VStack(spacing: 12) {
                    trendSection(combined)

                    if let rlat = combined.pressure.lat, let rlon = combined.pressure.lon {
                        RadarPanel(lat: rlat, lon: rlon,
                                   stationName: combined.pressure.name ?? combined.pressure.station,
                                   onExpand: { showRadarFullScreen = true })
                            .frame(maxHeight: .infinity)
                            .fullScreenCover(isPresented: $showRadarFullScreen) {
                                RadarView(lat: rlat, lon: rlon,
                                          stationName: combined.pressure.name ?? combined.pressure.station)
                            }
                    } else {
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
    }

    private func initialLoad() async {
        if store.combined != nil { return }
        await loadForCurrentMode()
    }

    private func reload() async { await loadForCurrentMode(silent: true) }

    private func loadForCurrentMode(silent: Bool = false) async {
        switch savedLocations.selected.kind {
        case .currentLocation:
            await store.resolveStationFromLocation()
            await store.load(silent: silent)
        case .place(let lat, let lon, _):
            await store.resolveStation(lat: lat, lon: lon)
            await store.load(lat: lat, lon: lon, silent: silent)
        case .airport(let icao):
            store.station = icao
            await store.load(silent: silent)
        }
    }
}

/// The kneeboard's top line: station + flight category + raw METAR conditions
/// ("KLUK VFR · 27011G18KT 10SM BKN045") in mono — the watch METAR complication's
/// language, promoted to the top of the iPad dashboard.
private struct MetarStrip: View {
    let combined: CombinedResponse

    var body: some View {
        HStack(spacing: 8) {
            Text(combined.pressure.station)
                .foregroundStyle(.secondary)
            if let cat = combined.pressure.current.fltCat {
                Text(cat)
                    .fontWeight(.bold)
                    .foregroundStyle(fltCatColor(cat))
            }
            if !conditions.isEmpty {
                Text(conditions)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer()
            Text("Updated \(combined.pressure.cachedAt.formatted(date: .omitted, time: .shortened))")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 13, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    /// "27011G18KT 10SM BKN045" — wind, visibility, ceiling in METAR notation.
    private var conditions: String {
        let cur = combined.pressure.current
        var parts: [String] = []
        if let kmh = cur.windspeed {
            let kt = Int((kmh / 1.852).rounded())
            if kt == 0 {
                parts.append("00000KT")
            } else {
                let dir = cur.winddir.map {
                    String(format: "%03d", Int($0.rounded()) == 0 ? 360 : Int($0.rounded()))
                } ?? "VRB"
                var w = dir + String(format: "%02d", kt)
                if let g = cur.windgust { w += "G\(Int((g / 1.852).rounded()))" }
                parts.append(w + "KT")
            }
        }
        if let v = cur.visibilitySM {
            parts.append(v >= 10 ? "10SM"
                : (v == v.rounded() ? "\(Int(v))SM" : String(format: "%.1fSM", v)))
        }
        if let ft = cur.ceilingFt {
            parts.append("\(cur.ceilingCover ?? "CIG")\(String(format: "%03d", ft / 100))")
        } else if let cover = cur.ceilingCover {
            parts.append(cover)
        }
        return parts.joined(separator: " ")
    }

    /// Standard aviation flight-category colors.
    private func fltCatColor(_ cat: String) -> Color {
        switch cat {
        case "VFR":  return Color(red: 0.13, green: 0.62, blue: 0.28)
        case "MVFR": return Color(red: 0.20, green: 0.48, blue: 0.85)
        case "IFR":  return Color(red: 0.85, green: 0.22, blue: 0.18)
        case "LIFR": return Color(red: 0.72, green: 0.20, blue: 0.70)
        default:     return .secondary
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
            // CC-BY 4.0 requires visible credit for the forecast data.
            if combined.sources?.forecast != nil {
                Text("Forecast · Open-Meteo.com (CC-BY 4.0)")
            }
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
