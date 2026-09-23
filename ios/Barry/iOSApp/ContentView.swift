//  ContentView.swift
//  Barry — iOS
//
//  Full app screen: verdict header, the hero −24/+24 pressure chart, confirmation
//  overlays, the forecast caveat, and a settings sheet (brief Phases 3 & 6).

import SwiftUI
import CoreLocation

struct ContentView: View {
    @EnvironmentObject var store: PressureStore
    @EnvironmentObject var barometer: BarometerManager
    @StateObject private var savedLocations = SavedLocationsStore()
    @StateObject private var homeLayout = HomeLayoutStore()
    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var unitRaw: String = PressureUnit.inHg.rawValue
    @AppStorage("phoneBarometerEnabled", store: AppConfig.sharedDefaults)
    private var phoneBarometerEnabled: Bool = false
    @AppStorage("chartWindow", store: AppConfig.sharedDefaults)
    private var chartWindowRaw: String = ChartWindow.hours6.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Backcountry.enabledKey, store: AppConfig.sharedDefaults)
    private var backcountryEnabled: Bool = false
    @AppStorage(Backcountry.useWatchSensorKey, store: AppConfig.sharedDefaults)
    private var backcountryUseWatch: Bool = true
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var showSettings = false
    @State private var showRadarFullScreen = false
    @State private var showAloft = false
    /// The dashboard's radar card only animates while it is on screen.
    @State private var radarCardOnScreen = true

    /// Height of the screen the app is on, in points. Available from the
    /// first frame, which is the whole point of using it.
    private static var screenHeight: CGFloat {
        (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive }
            as? UIWindowScene)?.screen.bounds.height
        ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.height
        ?? 0
    }


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
            // Once there is data, the title bar goes: the gear moves next to
            // the update time on the METAR strip and the mark sits at the
            // foot of the page, so the row that only said "Barry" gives its
            // height back to the data. Loading and error states keep it.
            .toolbar(hasData ? .hidden : .visible, for: .navigationBar)
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
                    .environmentObject(homeLayout)
            }
            // Switching locations (from the hero menu or Settings) reloads for
            // the new selection.
            .onChange(of: savedLocations.selectedID) { _, _ in
                syncAirportSelection()
                Task { await loadForCurrentMode(silent: false) }
            }
            .task {
                // A UI test or a screenshot run can land on the radar directly.
                if UITestSupport.active, ProcessInfo.processInfo.arguments.contains("-uitest-radar") {
                    showRadarFullScreen = true
                }
                if UITestSupport.active, ProcessInfo.processInfo.arguments.contains("-uitest-aloft") {
                    showAloft = true
                }
                WatchSync.shared.activate()
                syncAirportSelection()
                await initialLoad()
            }
            .onChange(of: backcountryEnabled) { _, _ in syncWatch() }
            // The lock screen follows the data: start for a new event while
            // the app is in front, update or end a running one.
            .onChange(of: store.combined) { _, c in
                guard let c else { return }
                Task { await LiveActivityManager.shared.sync(c, atAirport: isAtAirport(c), foreground: true) }
            }
            .onChange(of: backcountryUseWatch) { _, _ in syncWatch() }
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

    /// Loaded with something to show (the title bar steps aside).
    private var hasData: Bool {
        guard case .loaded(let combined) = store.state else { return false }
        return !combined.pressure.series.isEmpty
    }

    /// True when the kneeboard dashboard is what's on screen.
    private var isDashboard: Bool {
        guard hSizeClass == .regular, case .loaded(let combined) = store.state else { return false }
        return !combined.pressure.series.isEmpty
    }

    /// Regular width (iPad full screen / large Split View) gets the kneeboard
    /// dashboard — everything visible at once, no navigation. Compact width
    /// (iPhone, iPad slide-over) keeps the scrolling glance layout.
    @ViewBuilder
    private var rootContent: some View {
        if isDashboard, case .loaded(let combined) = store.state {
            dashboard(combined)
        } else {
            ScrollView {
                content
                    .padding(.horizontal)
            }
            .refreshable { await reload() }
            .navigationDestination(isPresented: $showAloft) { aloftScreen }
            .navigationDestination(isPresented: $showRadarFullScreen) {
                if let combined = store.combined,
                   let rlat = combined.pressure.lat, let rlon = combined.pressure.lon {
                    RadarScreen(lat: rlat, lon: rlon,
                                stationName: combined.pressure.name ?? combined.pressure.station,
                                home: homeMarker(combined))
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
        case .loaded(let combined) where combined.pressure.series.isEmpty:
            // The station exists as an identifier but nothing reports there —
            // say so instead of rendering a screen of dashes.
            VStack(spacing: 12) {
                Image(systemName: "icloud.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("\(store.station) isn't reporting weather")
                    .font(.headline)
                Text("No weather station here. Pick a nearby reporting airport, or save this spot as a place in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, minHeight: 320)
        case .loaded(let combined):
            VStack(alignment: .leading, spacing: 20) {
                // The kneeboard's METAR line, phone-sized, gear included.
                MetarStrip(combined: combined, onSettings: { showSettings = true })
                glanceCards(combined, layout: .phone)
            }
            .padding(.top, 8)
            .padding(.bottom)
        }
    }

    /// Which chrome the card list is embedded in. The phone stack carries the
    /// chart and the radar row inline; the iPad dashboard puts those in their
    /// own columns and only wants the glance cards.
    private enum GlanceLayout { case phone, dashboard }

    /// THE list of cards, in order, for both layouts. Adding a card here adds
    /// it everywhere; there is no second list to forget.
    @ViewBuilder
    private func glanceCards(_ combined: CombinedResponse, layout: GlanceLayout) -> some View {
        // The glance: station, live-aware current value, trend, verdict.
        // The station row doubles as the saved-locations switcher.
        HeroView(combined: combined, unit: unit, barometer: barometer,
                 now: store.now, barometerEnabled: localSensorActive,
                 atAirport: isAtAirport(combined),
                 locations: savedLocations.locations,
                 selectedLocationID: savedLocations.selectedID,
                 onSelectLocation: { savedLocations.selectedID = $0 },
                 isFollowing: LiveActivityManager.shared.isFollowing,
                 onFollow: { Task { await LiveActivityManager.shared.toggleFollow(combined, atAirport: isAtAirport(combined)) } },
                 stale: store.isStale, staleReason: store.refreshError)

        // The cards, in the user's order (Settings > Home screen). Each one
        // still decides whether it has anything to say.
        ForEach(homeLayout.layout.order) { card in
            if homeLayout.isVisible(card) {
                homeCard(card, combined, layout: layout)
            }
        }

        // The app's name lives at the foot of the page, where the title
        // bar used to say it.
        HStack(spacing: 6) {
            Image("BarryMark")
                .resizable()
                .renderingMode(.template)
                .frame(width: 20, height: 20)
                .foregroundStyle(Color(red: 0.42, green: 0.32, blue: 0.75))
            Text("Barry")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// One card of the home list. The iPad dashboard draws the chart and
    /// the rain + wind card in their own columns, so the rail skips them.
    @ViewBuilder
    private func homeCard(_ card: HomeCard, _ combined: CombinedResponse, layout: GlanceLayout) -> some View {
        switch card {
        case .lightning:
            // The breakout card the front banner used to be. The front watch
            // itself still runs; its map and compass are on the radar.
            lightningBanner(combined)
        case .chart:
            // The focused trend: window toggle + chart + the honest caveat.
            if layout == .phone { trendSection(combined) }
        case .taf:
            // The forecaster's product as a strip; only when the station has a TAF.
            if let taf = combined.taf, !taf.periods.isEmpty {
                TafTimelineCard(combined: combined, now: store.now)
            }
        case .rainWind:
            if layout == .phone { ShortTermForecastCard(combined: combined, now: store.now) }
        case .conditions:
            // DA now + trend, clouds, boundary layer, storm and fog outlooks
            // when they exist. Never an empty card.
            if let cond = combined.conditions, cond.hasContent {
                FieldConditionsCard(conditions: cond, combined: combined, now: store.now,
                                    onAloft: { showAloft = true })
            }
        case .strip:
            // Off-field only: the nearest station as a fact for everyone,
            // the estimates when Backcountry is on. Never at an airport.
            if !isAtAirport(combined) {
                StripCard(combined: combined, now: store.now, unit: unit,
                          here: hereCoordinate, physical: isPhysicalSelection,
                          barometer: barometer, sensorEnabled: localSensorActive)
            }
        case .wind:
            // Crosswind per runway at an airport, the plain wind elsewhere.
            RunwayWindsCard(combined: combined, atAirport: isAtAirport(combined))
        case .radar:
            // The same embedded map the kneeboard has, phone-sized.
            if layout == .phone, let rlat = combined.pressure.lat, let rlon = combined.pressure.lon {
                RadarPanel(lat: rlat, lon: rlon,
                           stationName: combined.pressure.name ?? combined.pressure.station,
                           home: homeMarker(combined),
                           onExpand: { showRadarFullScreen = true },
                           embedded: true,
                           active: radarCardOnScreen)
                    .frame(height: 440)
                    // iOS 18 has onScrollVisibilityChange for exactly this. On
                    // 17 the card measures its own window-space frame against
                    // the screen. The screen height needs no layout pass, so
                    // there is no window where one side is known and the other
                    // is not, which is what sank the two attempts before this.
                    .background {
                        GeometryReader { g in
                            let fr = g.frame(in: .global)
                            let h = Self.screenHeight
                            let onScreen = h <= 0 || (fr.maxY > 0 && fr.minY < h)
                            Color.clear
                                .onChange(of: onScreen, initial: true) { _, visible in
                                    if visible != radarCardOnScreen { radarCardOnScreen = visible }
                                }
                        }
                    }
            }
        case .sensor:
            // Physical location only: comparing the pocket barometer to a
            // remote station is meaningless.
            if localSensorActive {
                SensorStationRow(combined: combined, now: store.now, unit: unit, barometer: barometer)
            }
        case .sources:
            DataSourceFootnote(combined: combined)
        }
    }

    /// Lightning within 100 miles, as a card that opens the radar.
    @ViewBuilder
    private func lightningBanner(_ combined: CombinedResponse) -> some View {
        if let near = combined.lightningNearby,
           let lat = combined.pressure.lat, let lon = combined.pressure.lon {
            LightningBanner(near: near, now: store.now, lat: lat, lon: lon,
                            stationName: combined.pressure.name ?? combined.pressure.station,
                            home: homeMarker(combined))
        }
    }

    /// Window picker + chart + caveat — shared by the phone layout and the iPad
    /// dashboard, including the calibration trigger.
    private func trendSection(_ combined: CombinedResponse,
                              chartHeight: CGFloat = 220) -> some View {
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
                phoneTrace: localSensorActive
                    ? barometer.phoneHistoryTrace.map { ($0.0, combined.displayValue(fromLocalAltim: $0.1)) } : [],
                window: chartWindow,
                height: chartHeight
            )
            // Trigger calibration whenever a fresh combined response arrives.
            // Physical location ONLY: a remote station's SLP fed into the
            // calibration would corrupt the offset (and trip the altitude-
            // jump reset). The obs time keeps it one point per METAR.
            .onChange(of: combined) { _, newCombined in
                guard isPhysicalSelection else { return }
                if let ref = newCombined.calibrationReference {
                    barometer.attemptCalibration(
                        stationAltim: ref,
                        tempC: newCombined.pressure.current.temp,
                        observedAt: newCombined.observedSeries.last?.t)
                }
            }

            ForecastCaveatView(combined: combined, now: store.now)
        }
        // The chart's floating analysis card overflows this section; it must
        // paint above the siblings below (cards on the phone, the map on iPad).
        .zIndex(1)
    }

    /// The iPad kneeboard dashboard: METAR strip across the top, the glance rail
    /// on the left, and the chart + live radar filling the rest. Everything at
    /// once — the pilot use case inverts "glance then drill in".
    ///
    /// Wide layouts (iPad landscape) get THREE columns — rail | chart | radar —
    /// so the radar map runs the full panel height. Stacking chart-over-radar
    /// there left the map a sliver shorter than its own controls. Portrait (and
    /// anything narrower than ~1000 pt) keeps the stacked two-column layout.
    private func dashboard(_ combined: CombinedResponse) -> some View {
        GeometryReader { geo in
            let threeColumn = geo.size.width > geo.size.height && geo.size.width >= 1000

            VStack(spacing: 12) {
                MetarStrip(combined: combined, onSettings: { showSettings = true })

                HStack(alignment: .top, spacing: 16) {
                    glanceRail(combined)

                    // The chart runs shorter here than on the phone so the
                    // rain + wind card fits under it in the same column.
                    if threeColumn {
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 12) {
                                trendSection(combined, chartHeight: 200)
                                if homeLayout.isVisible(.rainWind) {
                                    ShortTermForecastCard(combined: combined, now: store.now)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)

                        radarColumn(combined)
                            .frame(width: max(320, geo.size.width * 0.30))
                    } else {
                        VStack(spacing: 12) {
                            trendSection(combined, chartHeight: 200)
                            if homeLayout.isVisible(.rainWind) {
                                ShortTermForecastCard(combined: combined, now: store.now)
                            }
                            radarColumn(combined)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding()
        }
        .navigationDestination(isPresented: $showAloft) { aloftScreen }
        .navigationDestination(isPresented: $showRadarFullScreen) {
            if let rlat = combined.pressure.lat, let rlon = combined.pressure.lon {
                RadarScreen(lat: rlat, lon: rlon,
                            stationName: combined.pressure.name ?? combined.pressure.station,
                            home: homeMarker(combined))
            }
        }
    }

    private func glanceRail(_ combined: CombinedResponse) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                glanceCards(combined, layout: .dashboard)
            }
        }
        .frame(width: 340)
        .refreshable { await reload() }
    }

    @ViewBuilder
    private func radarColumn(_ combined: CombinedResponse) -> some View {
        if let rlat = combined.pressure.lat, let rlon = combined.pressure.lon {
            RadarPanel(lat: rlat, lon: rlon,
                       stationName: combined.pressure.name ?? combined.pressure.station,
                       home: homeMarker(combined),
                       onExpand: { showRadarFullScreen = true },
                       embedded: true)
                .frame(maxHeight: .infinity)
        } else {
            Spacer()
        }
    }

    /// The home station as a map marker: its own barb (with a halo) when the
    /// selection is an airport or the user is within 3 NM of it; otherwise the
    /// pin. Built from /combined so it needs no extra fetch; the radar swaps
    /// in the station slice's fuller copy when it has one.
    private func homeMarker(_ combined: CombinedResponse) -> HomeMarker? {
        guard let lat = combined.pressure.lat, let lon = combined.pressure.lon else { return nil }
        let cur = combined.pressure.current
        let obs = StationObs(id: combined.pressure.station, lat: lat, lon: lon,
                             name: combined.pressure.name,
                             windKt: cur.windspeed.map { $0 / 1.852 }, windDir: cur.winddir,
                             gustKt: cur.windgust.map { $0 / 1.852 }, fltCat: cur.fltCat,
                             fltCatDerived: cur.fltCatDerived,
                             obsTime: combined.observedSeries.last?.t,
                             visibilitySM: cur.visibilitySM, ceilingFt: cur.ceilingFt,
                             ceilingCover: cur.ceilingCover, temp: cur.temp,
                             dewpoint: cur.dewpoint, altim: cur.altim, raw: nil)
        return HomeMarker(obs: obs, asBarb: isAtAirport(combined))
    }

    /// The selection is an airport, or the user is physically within 3 NM of
    /// the station (PressureStore holds the rule so the watch shares it).
    /// Drives the altimeter headline, the home barb on the map and the
    /// runway view of the wind card (in its Auto mode).
    private func isAtAirport(_ combined: CombinedResponse) -> Bool {
        store.isAtAirport(combined)
    }

    /// Where "here" is for the Strip card: the device for My location, the
    /// saved place otherwise, nothing for an airport.
    private var hereCoordinate: CLLocationCoordinate2D? {
        switch savedLocations.selected.kind {
        case .currentLocation: return store.userLocation?.coordinate
        case .place(let lat, let lon, _): return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        case .airport: return nil
        }
    }

    private func syncAirportSelection() {
        if case .airport = savedLocations.selected.kind { store.airportSelected = true }
        else { store.airportSelected = false }
    }

    /// The watch follows the phone's station and airport choice.
    private func syncWatch() {
        WatchSync.shared.send(station: store.station, airportSelected: store.airportSelected,
                              physical: savedLocations.selected.isPhysical,
                              backcountry: backcountryEnabled, watchSensor: backcountryEnabled && backcountryUseWatch)
    }

    /// The Aloft column for the loaded station; nothing until the station
    /// has coordinates to ask the model about.
    @ViewBuilder private var aloftScreen: some View {
        if let c = store.combined, let lat = c.pressure.lat, let lon = c.pressure.lon {
            AloftScreen(lat: lat, lon: lon, station: c.pressure.station,
                        stationName: c.pressure.name ?? c.pressure.station, combined: c)
        }
    }

    private func initialLoad() async {
        // Fresh data already on screen: nothing to do. A saved reading
        // from the last run is on screen at a cold start; refresh behind
        // it rather than replacing it with a spinner.
        if store.combined != nil && !store.isStale { return }
        await loadForCurrentMode(silent: store.combined != nil)
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
        syncWatch()
    }
}

/// The kneeboard's top line: station + flight category + raw METAR conditions
/// ("KLUK VFR · 27011G18KT 10SM BKN045") in mono — the watch METAR complication's
/// language, promoted to the top of the iPad dashboard.
private struct MetarStrip: View {
    let combined: CombinedResponse
    /// Opens Settings; the dashboard has no title bar to hold the gear.
    var onSettings: (() -> Void)? = nil

    var body: some View {
        // Plain text hierarchy + hairline rule — no container chrome. Mono is
        // reserved for the raw METAR cluster (it's code-like content); everything
        // else is standard system type.
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(combined.pressure.station)
                    .font(.subheadline.weight(.semibold))
                if let cat = combined.pressure.current.fltCat {
                    Text(cat)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(fltCatColor(cat))
                }
                if !conditions.isEmpty {
                    Text(conditions)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer()
                // Freshness lives on the hero's station row (report age and
                // refresh time together); only the gear sits up here.
                if let onSettings {
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Settings")
                }
            }
            Divider()
        }
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

    private func fltCatColor(_ cat: String) -> Color { FlightCategory.color(cat) }
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
