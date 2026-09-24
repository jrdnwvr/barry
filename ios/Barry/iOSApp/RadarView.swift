//  RadarView.swift
//  Barry — iOS
//
//  The radar screen: RadarScreen (pushed, full-bleed map, floating controls)
//  and RadarPanel, which the iPad dashboard also embeds in compact form.
//
//  Layers come in two tiers, the way Windy and Apple's map do it. One BASE at
//  a time (Radar, Pressure, Change) picked from a segmented control, and thin
//  OVERLAYS (Wind, Fronts, Stations, Lightning) that stack on it as chips. One
//  timeline, and it belongs to the base: the radar scrubber shows only when
//  radar is the base; the front chips fold behind the Fronts chip. The key
//  and the source notes live in a sheet that lists only what's on screen.
//  Model and map bridge live in RadarModel.swift and RadarMapView.swift.

import Combine
import SwiftUI
import MapKit

/// The one fill layer under everything else.
/// The gridded field drawn over the map: none, sea-level pressure (isobars
/// and shading), or the 3 h change (isallobars and shading). One at a time,
/// since two shadings on one map say nothing; the radar can stay on under
/// either.
enum RadarField: String, CaseIterable, Identifiable {
    case off, pressure, change
    var id: String { rawValue }
}

// MARK: - Screen

/// The radar as its own screen (pushed, with a real Back button): the map fills
/// the view and the controls float over it. The iPad dashboard embeds RadarPanel
/// directly in compact form and pushes this for the full experience.
struct RadarScreen: View {
    let lat: Double
    let lon: Double
    let stationName: String
    var home: HomeMarker? = nil

    var body: some View {
        RadarPanel(lat: lat, lon: lon, stationName: stationName, home: home)
            .navigationTitle("Radar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

struct RadarPanel: View {
    let lat: Double
    let lon: Double
    let stationName: String
    /// How to mark the home station (pin, or its own barb with a halo).
    var home: HomeMarker? = nil
    /// When set, an expand button overlays the map (dashboard embeds use it to
    /// pop the radar to full screen).
    var onExpand: (() -> Void)? = nil
    /// Dashboard embeds run chrome-light: the map is a rounded card and the
    /// chip bar sits under it, so the MAP gets the panel's height.
    var embedded: Bool = false
    /// False while the card is scrolled out of sight. Both the radar loop and
    /// the wind streaks stand down; neither is worth a frame nobody sees.
    var active: Bool = true

    @StateObject private var model = RadarModel()
    @State private var dwellTicks = 0

    // Layers. Radar is one of them now, not a base the others sit on, so
    // the pressure field can shade over the rain. The field is exclusive
    // within itself (pressure or change), everything else stacks.
    @AppStorage("radarShowRadar", store: AppConfig.sharedDefaults)
    private var showRadar: Bool = true
    @AppStorage("radarField", store: AppConfig.sharedDefaults)
    private var fieldRaw: String = RadarField.off.rawValue
    /// Isobars are their own layer now, not part of the Pressure shading:
    /// lines of equal sea-level pressure are worth having over plain radar,
    /// or beside a trough, without a wash of colour under them.
    @AppStorage("radarIsobars", store: AppConfig.sharedDefaults)
    private var showIsobars: Bool = false
    /// WPC trough lines on their own chip: a trough is worth seeing on the
    /// plain radar without the rest of the surface chart.
    @AppStorage("radarTroughs", store: AppConfig.sharedDefaults)
    private var showTroughs: Bool = true
    // Overlays (any combination).
    @AppStorage("radarWindArrows", store: AppConfig.sharedDefaults)
    private var showWind: Bool = true
    @AppStorage("radarFronts", store: AppConfig.sharedDefaults)
    private var showFronts: Bool = true
    /// Station layer: "off", "barbs" (METAR wind flags) or "speeds" (labels).
    @AppStorage("radarStations", store: AppConfig.sharedDefaults)
    private var stationStyleRaw: String = "off"
    /// The style to come back to when the Stations chip is turned on again.
    @AppStorage("radarStationStyleLast", store: AppConfig.sharedDefaults)
    private var stationStyleLast: String = "barbs"
    /// Bolts where stations report lightning. On by default: a quiet day
    /// draws nothing, so it costs nothing to leave on.
    @AppStorage("radarStorms", store: AppConfig.sharedDefaults)
    private var showStorms: Bool = true
    /// "flow" (animated streaks, the default) or "arrows" (the static grid).
    @AppStorage("radarWindStyle", store: AppConfig.sharedDefaults)
    private var windStyle: String = "flow"
    // How the fronts draw (map options): all on is the classic chart.
    @AppStorage("radarFrontLines", store: AppConfig.sharedDefaults)
    private var frontLines: Bool = true
    @AppStorage("radarFrontPips", store: AppConfig.sharedDefaults)
    private var frontPips: Bool = true
    @AppStorage("radarFrontWeak", store: AppConfig.sharedDefaults)
    private var frontWeak: Bool = true
    @AppStorage("radarFrontCenters", store: AppConfig.sharedDefaults)
    private var frontCenters: Bool = true

    /// What the fronts overlay draws: the chart's parts when Fronts is on,
    /// only the trough lines when just the Troughs chip is.
    private var frontStyle: FrontStyle {
        showFronts
            ? FrontStyle(lines: frontLines, pips: frontPips, troughs: showTroughs,
                         weak: frontWeak, centers: frontCenters)
            : FrontStyle(lines: false, pips: false, troughs: showTroughs, weak: false, centers: false)
    }
    private var wantsFronts: Bool { showFronts || showTroughs }

    /// Loop on open (the default) or hold the newest frame (Settings).
    static let autoplayKey = "radarAutoplay"
    @AppStorage(RadarPanel.autoplayKey, store: AppConfig.sharedDefaults)
    private var autoplay: Bool = true

    @State private var recenterToken = 0
    /// The dashboard embed keeps the chip bar behind a button: the layers
    /// are shared with the full screen (same stored settings), so the small
    /// map follows whatever was chosen there and rarely needs its own bar.
    @State private var showEmbeddedChips = false
    @State private var showKey = false
    @State private var showMore = false
    @State private var selectedStation: StationObs?

    private let ticker = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()
    /// The flash slice ages a minute at a time; the server polls NOAA per minute.
    private let lightningTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var field: RadarField { RadarField(rawValue: fieldRaw) ?? .off }
    private var stationStyle: StationLayerStyle { StationLayerStyle(rawValue: stationStyleRaw) ?? .off }
    private var stationsOn: Bool { stationStyle != .off }
    /// The station slice feeds the station layer, the storm bolts, and the
    /// home barb's sheet; any of them wants it.
    private var wantsStations: Bool { stationsOn || showStorms || home?.asBarb == true }

    /// Anything that needs the gridded pressure field behind it.
    private var wantsPressure: Bool { field != .off || showIsobars }

    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var pressureUnitRaw: String = PressureUnit.inHg.rawValue

    private var pressureState: PressureFieldState? {
        guard wantsPressure else { return nil }
        // Lighter shading over the radar so the rain still reads through it.
        let opacity = showRadar ? 0.30 : 0.42
        let shade: PressureShade
        switch field {
        case .off: shade = .off
        case .pressure: shade = .pressure
        case .change: shade = .change
        }
        // Isallobars belong to the change field; they mean nothing without it.
        return PressureFieldState(field: model.pressureField,
                                  showIsobars: showIsobars,
                                  showIsallobars: field == .change,
                                  shade: shade, shadeOpacity: opacity,
                                  unit: PressureUnit(rawValue: pressureUnitRaw) ?? .inHg,
                                  version: model.pressureVersion)
    }

    private var initialRegion: MKCoordinateRegion {
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                           span: MKCoordinateSpan(latitudeDelta: 3.2, longitudeDelta: 3.2))
    }

    var body: some View {
        Group {
            if model.failed {
                VStack(spacing: 10) {
                    Text("Couldn't load radar. Check your connection.")
                        .foregroundStyle(.secondary)
                    Button("Try again") { Task { await model.load() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.frames.isEmpty {
                ProgressView("Loading radar…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .task {
            // The old exclusive base setting becomes a field choice once.
            if let old = AppConfig.sharedDefaults.string(forKey: "radarBase") {
                if old == "pressure" || old == "change" { fieldRaw = old }
                AppConfig.sharedDefaults.removeObject(forKey: "radarBase")
            }
            // Isobars used to be drawn by the Pressure shading. Now that they
            // are their own chip, anyone who had Pressure on keeps their lines.
            if !AppConfig.sharedDefaults.bool(forKey: "radarIsobarsSplit") {
                if field == .pressure { showIsobars = true }
                AppConfig.sharedDefaults.set(true, forKey: "radarIsobarsSplit")
            }
            model.frontStyle = frontStyle
            await model.load()
            model.playing = autoplay
            model.lockedToNow = !autoplay
            if showWind {
                await model.fetchField(region: model.lastRegion ?? initialRegion)
            }
            if wantsFronts {
                await model.fetchFronts()
            }
            if wantsStations {
                await model.fetchStations(region: model.lastRegion ?? initialRegion)
            }
            if showStorms {
                await model.fetchLightning(center: initialRegion.center)
            }
            if wantsPressure {
                await model.fetchPressureField(region: model.lastRegion ?? initialRegion)
            }
        }
        .onReceive(lightningTicker) { _ in
            guard showStorms else { return }
            Task { await model.fetchLightning(center: model.lastRegion?.center ?? initialRegion.center, force: true) }
        }
        .onReceive(ticker) { _ in
            guard showRadar, active, model.playing, !model.frames.isEmpty else { return }
            // Dwell at the end of the loop (the freshest picture) before
            // restarting — the Dark Sky rhythm, and it reads far calmer.
            if dwellTicks > 0 {
                dwellTicks -= 1
                return
            }
            // The loop is the last hour: the observed frames through now.
            // Nowcast and model frames are there for the scrubber.
            let last = model.nowIndex
            model.index = model.index >= last ? 0 : model.index + 1
            if model.index == last {
                dwellTicks = 3
            }
        }
    }

    @ViewBuilder private var content: some View {
        Group {
            if embedded {
                embeddedContent
            } else {
                fullScreenContent
            }
        }
        .sheet(item: $selectedStation) { st in
            StationDetailSheet(obs: st, now: Date())
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showKey) {
            RadarKeySheet(radar: showRadar, field: field, isobars: showIsobars,
                          wind: showWind, windStyle: windStyle,
                          fronts: showFronts, troughs: showTroughs,
                          frontValidText: frontValidText, stations: stationsOn,
                          stationStyle: stationStyle, storms: showStorms,
                          pressureStations: model.pressureField?.stations ?? 0,
                          lightningCoverage: model.lightning.response?.coverage)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showMore) {
            RadarMoreSheet(windStyle: $windStyle, stationStyle: $stationStyleLast,
                           onStationStyleChange: { style in
                               if stationsOn { stationStyleRaw = style }
                           },
                           frontLines: $frontLines, frontPips: $frontPips,
                           frontWeak: $frontWeak, frontCenters: $frontCenters)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: stationStyleRaw) { _, raw in
            if raw != "off" {
                Task { await model.fetchStations(region: model.lastRegion ?? initialRegion) }
            }
        }
        .onChange(of: showStorms) { _, on in
            if on {
                Task {
                    await model.fetchStations(region: model.lastRegion ?? initialRegion)
                    await model.fetchLightning(center: model.lastRegion?.center ?? initialRegion.center)
                }
            }
        }
        .onChange(of: showFronts) { _, on in
            if on, model.frontFrames.isEmpty {
                Task { await model.fetchFronts() }
            }
        }
        .onChange(of: showTroughs) { _, on in
            if on, model.frontFrames.isEmpty {
                Task { await model.fetchFronts() }
            }
        }
        .onChange(of: fieldRaw) { _, _ in
            if wantsPressure {
                Task { await model.fetchPressureField(region: model.lastRegion ?? initialRegion) }
            }
        }
        .onChange(of: showIsobars) { _, on in
            if on {
                Task { await model.fetchPressureField(region: model.lastRegion ?? initialRegion) }
            }
        }
        .onChange(of: showWind) { _, on in
            if on {
                Task { await model.fetchField(region: model.lastRegion ?? initialRegion) }
            }
        }
        .onChange(of: frontStyle) { _, style in
            model.frontStyle = style
        }
    }

    /// The map itself, shared by both layouts.
    private var mapView: some View {
        RadarMapView(host: model.host,
                     frames: model.frames,
                     index: model.index,
                     radarVisible: showRadar,
                     center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                     windArrows: model.windArrows,
                     showWind: showWind && windStyle == "arrows",
                     windFlow: (showWind && windStyle == "flow") ? model.windField : nil,
                     embedded: embedded,
                     animating: active,
                     frontState: wantsFronts ? model.frontState : nil,
                     stations: model.stationObs,
                     stationStyle: stationStyle,
                     showStorms: showStorms,
                     lightning: model.lightning,
                     onSelectStation: { selectedStation = $0 },
                     home: home,
                     pressureState: pressureState,
                     recenterToken: recenterToken,
                     onRegionChange: { region in
                         model.scheduleFieldReload(for: region,
                                                   wind: showWind,
                                                   stations: wantsStations,
                                                   pressure: wantsPressure,
                                                   storms: showStorms)
                     })
    }

    /// Full screen: the map fills the view; the chip bar and the timeline
    /// float in a card at the bottom, the key behind a button at the top.
    private var fullScreenContent: some View {
        ZStack(alignment: .bottom) {
            mapView
                .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Spacer()
                    keyButton
                }
                .padding(12)

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    recenterButton
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                bottomCard
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
    }

    /// The Maps convention: a location arrow that glides the map back to
    /// the home station at the opening zoom.
    private var recenterButton: some View {
        Button { recenterToken += 1 } label: {
            Image(systemName: "location")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 20, height: 20)
                .padding(9)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to my station")
    }

    /// The iPad dashboard embed: map in a rounded card, the same chip bar
    /// and timeline below it.
    private var embeddedContent: some View {
        VStack(spacing: 10) {
            mapView
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomTrailing) {
                    recenterButton
                        .padding(10)
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { showEmbeddedChips.toggle() }
                        } label: {
                            Image(systemName: "square.3.layers.3d")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 20, height: 20)
                                .padding(9)
                                .background(.thinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showEmbeddedChips ? "Hide layers" : "Layers")
                        keyButton
                        if let onExpand {
                            Button(action: onExpand) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .padding(9)
                                    .background(.thinMaterial, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Expand radar")
                        .accessibilityIdentifier("radar.expand")
                        }
                    }
                    .padding(10)
                }

            if showEmbeddedChips {
                chipBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            timeline
            attribution
        }
    }

    private var keyButton: some View {
        Button { showKey = true } label: {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 20, height: 20)
                .padding(9)
                .background(.thinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map key")
    }

    /// The things you actually touch: the chip bar, the base's timeline, and
    /// the one-line attribution that must stay on screen.
    private var bottomCard: some View {
        VStack(spacing: 8) {
            chipBar
            timeline
            attribution
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var attribution: some View {
        Text("Radar RainViewer · NOAA NEXRAD · Lightning NOAA GOES · Wind Open-Meteo · Fronts NWS WPC · Stations AWC")
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Chip bar

    /// One scrollable row of layer chips, then More. Radar first, then the
    /// field pair (one at a time), then the rest. No paragraphs; the key
    /// explains.
    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Radar", icon: "antenna.radiowaves.left.and.right", isOn: $showRadar)
                chip("Pressure", icon: "circle.circle", isOn: fieldBinding(.pressure))
                chip("Change", icon: "arrow.up.arrow.down", isOn: fieldBinding(.change))
                chip("Isobars", icon: "circle.dashed", isOn: $showIsobars)
                chip("Wind", icon: "wind", isOn: $showWind)
                chip("Fronts", icon: "line.diagonal", isOn: $showFronts)
                chip("Troughs", icon: "point.topleft.down.to.point.bottomright.curvepath", isOn: $showTroughs)
                chip("Stations", icon: "flag", isOn: Binding(
                    get: { stationsOn },
                    set: { stationStyleRaw = $0 ? stationStyleLast : "off" }))
                chip("Lightning", icon: "bolt.fill", isOn: $showStorms)

                Button { showMore = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 18)
                }
                .buttonStyle(ChipStyle(on: false))
                .accessibilityLabel("More options")
            }
        }
        .accessibilityIdentifier("radar.chips")
    }

    /// Pressure and Change share one slot: turning one on turns the other off.
    private func fieldBinding(_ f: RadarField) -> Binding<Bool> {
        Binding(get: { field == f }, set: { fieldRaw = $0 ? f.rawValue : RadarField.off.rawValue })
    }

    /// An overlay chip: solid accent when on, the segmented control's gray
    /// when off, so the state reads at a glance in either appearance.
    private func chip(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .fixedSize()  // never wrap the title mid-word under compression
        }
        .buttonStyle(ChipStyle(on: isOn.wrappedValue))
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
        .accessibilityIdentifier("radar.chip.\(title)")
    }

    // MARK: - Timeline (belongs to the base)

    @ViewBuilder private var timeline: some View {
        if showRadar {
            radarControls
        }
        windCalmNote
        stormsNote
    }

    /// Lightning on but the server's mapper feed is stale: say so, or an
    /// empty map reads as "no lightning".
    @ViewBuilder private var stormsNote: some View {
        if showStorms, let r = model.lightning.response, !r.coverage {
            Text("Lightning feed catching up.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Local valid time of the analysis on screen.
    private var frontChipTime: String {
        guard let f = model.analysisFrame else { return "" }
        return "at " + f.valid.formatted(.dateTime.weekday(.abbreviated).hour())
    }

    private var frontValidText: String {
        "WPC fronts \(frontChipTime), to about 50 mi"
    }

    /// A toggled-on layer that draws nothing must say why, or it reads as broken.
    @ViewBuilder private var windCalmNote: some View {
        if showWind, model.windSampled, model.windArrows.isEmpty {
            Text("Wind under 3 kt across the map.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Now parks the map on the freshest observation and keeps it there.
    /// The loop plays the last hour through now and dwells on the freshest
    /// frame. A scrub pauses where the finger left it until the loop is
    /// tapped again. The frame's time sits under the slider.
    private var radarControls: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Button {
                    model.playing = false
                    model.lockedToNow = true
                    model.index = model.nowIndex
                } label: {
                    Text("Now")
                        .font(.caption.weight(.semibold))
                        .fixedSize()
                }
                .buttonStyle(ChipStyle(on: model.lockedToNow && !model.playing))
                .accessibilityAddTraits(model.lockedToNow && !model.playing ? .isSelected : [])
                .accessibilityIdentifier("radar.now")

                Button {
                    if model.playing {
                        model.playing = false
                    } else {
                        model.lockedToNow = false
                        model.playing = true
                    }
                } label: {
                    Image(systemName: "goforward.60")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(ChipStyle(on: model.playing))
                .accessibilityAddTraits(model.playing ? .isSelected : [])
                .accessibilityLabel(model.playing ? "Pause the loop" : "Loop the last hour")
                .accessibilityIdentifier("radar.loop")

                Slider(
                    value: Binding(
                        get: { Double(model.index) },
                        set: {
                            model.index = Int($0.rounded())
                            model.playing = false
                            model.lockedToNow = false
                        }
                    ),
                    in: 0...Double(max(1, model.frames.count - 1)),
                    step: 1
                )
            }
            Text(frameTimeText)
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(timeLabelColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("radar.frameTime")
        }
    }

    private var currentFrame: RadarFrame? {
        model.frames.indices.contains(model.index) ? model.frames[model.index] : nil
    }

    /// Purple = model reflectivity, orange = short nowcast, gray = observed —
    /// three sources, three colors, no ambiguity about what you're looking at.
    private var timeLabelColor: Color {
        guard let f = currentFrame else { return .secondary }
        if f.iemLayer != nil { return .purple }
        return f.nowcast ? .orange : .secondary
    }

    /// "8:20 PM · 20m ago", "8:50 PM · nowcast", "10 PM · model +2h".
    private var frameTimeText: String {
        guard let f = currentFrame else { return " " }
        let clock = Date(timeIntervalSince1970: Double(f.time)).formatted(date: .omitted, time: .shortened)
        if f.iemLayer != nil {
            let hrs = max(1, Int(((Double(f.time) - Date().timeIntervalSince1970) / 3600).rounded()))
            return "\(clock) · model +\(hrs)h"
        }
        let mins = Int((Date().timeIntervalSince1970 - Double(f.time)) / 60)
        if f.nowcast { return "\(clock) · nowcast" }
        let age = mins <= 1 ? "now" : "\(mins)m ago"
        return model.lockedToNow && !model.playing ? "\(clock) · latest, \(age)" : "\(clock) · \(age)"
    }
}


/// Chip look for the map's overlay toggles: filled accent when on, the
/// same quiet gray the segmented base picker uses when off.
struct ChipStyle: ButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}
