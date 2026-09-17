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
enum RadarBase: String, CaseIterable, Identifiable {
    case radar, pressure, change
    var id: String { rawValue }
    var title: String {
        switch self {
        case .radar: return "Radar"
        case .pressure: return "Pressure"
        case .change: return "Change"
        }
    }
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

    @StateObject private var model = RadarModel()
    @State private var dwellTicks = 0

    // Base layer (exclusive).
    @AppStorage("radarBase", store: AppConfig.sharedDefaults)
    private var baseRaw: String = RadarBase.radar.rawValue
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

    /// Loop on open (the default) or hold the newest frame (Settings).
    static let autoplayKey = "radarAutoplay"
    @AppStorage(RadarPanel.autoplayKey, store: AppConfig.sharedDefaults)
    private var autoplay: Bool = true

    @State private var showFrontRow = false
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

    private var base: RadarBase { RadarBase(rawValue: baseRaw) ?? .radar }
    private var stationStyle: StationLayerStyle { StationLayerStyle(rawValue: stationStyleRaw) ?? .off }
    private var stationsOn: Bool { stationStyle != .off }
    /// The station slice feeds the station layer, the storm bolts, and the
    /// home barb's sheet; any of them wants it.
    private var wantsStations: Bool { stationsOn || showStorms || home?.asBarb == true }

    private var pressureState: PressureFieldState? {
        switch base {
        case .radar: return nil
        case .pressure:
            return PressureFieldState(field: model.pressureField, showIsobars: true,
                                      showIsallobars: false, shade: .pressure, version: model.pressureVersion)
        case .change:
            return PressureFieldState(field: model.pressureField, showIsobars: false,
                                      showIsallobars: true, shade: .change, version: model.pressureVersion)
        }
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
            await model.load()
            model.playing = autoplay
            if showWind {
                await model.fetchField(region: model.lastRegion ?? initialRegion)
            }
            if showFronts {
                await model.fetchFronts()
            }
            if wantsStations {
                await model.fetchStations(center: initialRegion.center)
            }
            if showStorms {
                await model.fetchLightning(center: initialRegion.center)
            }
            if base != .radar {
                await model.fetchPressureField(region: model.lastRegion ?? initialRegion)
            }
        }
        .onReceive(lightningTicker) { _ in
            guard showStorms else { return }
            Task { await model.fetchLightning(center: model.lastRegion?.center ?? initialRegion.center, force: true) }
        }
        .onReceive(ticker) { _ in
            guard base == .radar, model.playing, !model.frames.isEmpty else { return }
            // Dwell at the end of the loop (the freshest picture) before
            // restarting — the Dark Sky rhythm, and it reads far calmer.
            if dwellTicks > 0 {
                dwellTicks -= 1
                return
            }
            model.index = (model.index + 1) % model.frames.count
            if model.index == model.frames.count - 1 {
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
            RadarKeySheet(base: base, wind: showWind, windStyle: windStyle, fronts: showFronts,
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
                           })
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: stationStyleRaw) { _, raw in
            if raw != "off" {
                Task { await model.fetchStations(center: model.lastRegion?.center ?? initialRegion.center) }
            }
        }
        .onChange(of: showStorms) { _, on in
            if on {
                Task {
                    await model.fetchStations(center: model.lastRegion?.center ?? initialRegion.center)
                    await model.fetchLightning(center: model.lastRegion?.center ?? initialRegion.center)
                }
            }
        }
        .onChange(of: showFronts) { _, on in
            if on, model.frontFrames.isEmpty {
                Task { await model.fetchFronts() }
            }
            if !on { showFrontRow = false }
        }
        .onChange(of: baseRaw) { _, _ in
            if base != .radar, model.pressureField == nil {
                Task { await model.fetchPressureField(region: model.lastRegion ?? initialRegion) }
            }
        }
        .onChange(of: showWind) { _, on in
            if on {
                Task { await model.fetchField(region: model.lastRegion ?? initialRegion) }
            }
        }
    }

    /// The map itself, shared by both layouts.
    private var mapView: some View {
        RadarMapView(host: model.host,
                     frames: model.frames,
                     index: model.index,
                     radarVisible: base == .radar,
                     center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                     windArrows: model.windArrows,
                     showWind: showWind && windStyle == "arrows",
                     windFlow: (showWind && windStyle == "flow") ? model.windField : nil,
                     frontState: showFronts ? model.frontState : nil,
                     stations: model.stationObs,
                     stationStyle: stationStyle,
                     showStorms: showStorms,
                     lightning: model.lightning,
                     onSelectStation: { selectedStation = $0 },
                     home: home,
                     pressureState: pressureState,
                     onRegionChange: { region in
                         model.scheduleFieldReload(for: region,
                                                   wind: showWind,
                                                   stations: wantsStations,
                                                   pressure: base != .radar,
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

                bottomCard
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
    }

    /// The iPad dashboard embed: map in a rounded card, the same chip bar
    /// and timeline below it.
    private var embeddedContent: some View {
        VStack(spacing: 10) {
            mapView
                .clipShape(RoundedRectangle(cornerRadius: 12))
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

    /// One scrollable row: the base picker on the left, then overlay chips
    /// with checkmarks, then More. No paragraphs; the key explains.
    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Picker("Base layer", selection: $baseRaw) {
                    ForEach(RadarBase.allCases) { b in
                        Text(b.title).tag(b.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 210)

                chip("Wind", icon: "wind", isOn: $showWind)
                chip("Fronts", icon: "line.diagonal", isOn: $showFronts)
                if showFronts, model.frontFrames.count > 1 {
                    frontTimeChip
                }
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
    }

    /// Sits next to the Fronts chip when the chart has forecast positions:
    /// shows the front time on screen and opens the Now / +12h / +24h row.
    private var frontTimeChip: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { showFrontRow.toggle() }
        } label: {
            HStack(spacing: 3) {
                Text(frontHoursLabel)
                Image(systemName: showFrontRow ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.caption.weight(.medium))
            .fixedSize()
        }
        .buttonStyle(ChipStyle(on: showFrontRow))
        .accessibilityLabel("Front forecast time")
    }

    private var frontHoursLabel: String {
        let h = Int(model.frontHours.rounded())
        return h == 0 ? "Now" : "+\(h)h"
    }

    // MARK: - Timeline (belongs to the base)

    @ViewBuilder private var timeline: some View {
        switch base {
        case .radar:
            radarControls
        case .pressure:
            baseCaption("Isobars from Barry's own station table, every 4 hPa (2 on a flat day).")
        case .change:
            baseCaption("Pressure change over the last 3 h. Solid rising, dashed falling, H and L at the strongest.")
        }
        if showFronts, showFrontRow, model.frontFrames.count > 1 {
            frontTimeline
                .transition(.move(edge: .top).combined(with: .opacity))
        }
        windCalmNote
        stormsNote
    }

    /// Lightning on but the server's mapper feed is stale: say so, or an
    /// empty map reads as "no lightning".
    @ViewBuilder private var stormsNote: some View {
        if showStorms, let r = model.lightning.response, !r.coverage {
            Text("Lightning feed is catching up; flashes may be missing for a few minutes.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func baseCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Now / +12h / +24h ... chips plus a play button. Tapping a chip glides the
    /// field there; play sweeps the whole timeline.
    private var frontTimeline: some View {
        HStack(spacing: 8) {
            // Say what the row moves: these chips slide the WPC front lines
            // and H/L centers to their forecast positions, not the radar.
            Text("Fronts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Button { model.playFronts() } label: {
                Image(systemName: model.frontPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.frontPlaying ? "Stop front movement" : "Play front movement")

            ForEach(model.frontFrames) { frame in
                let selected = abs(model.frontHours - Double(frame.hours)) < 0.5
                Button(frame.hours == 0 ? "Now" : "+\(frame.hours)h") {
                    model.animateFronts(to: Double(frame.hours))
                }
                .font(.caption.weight(selected ? .semibold : .regular))
                .buttonStyle(.bordered)
                .tint(selected ? .accentColor : .secondary)
                .controlSize(.small)
            }
            Spacer()
            Text(frontChipTime)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// Local valid time of the frame nearest the current front position.
    private var frontChipTime: String {
        guard let f = model.frontFrames.min(by: {
            abs(Double($0.hours) - model.frontHours) < abs(Double($1.hours) - model.frontHours)
        }) else { return "" }
        return "at " + f.valid.formatted(.dateTime.weekday(.abbreviated).hour())
    }

    private var frontValidText: String {
        "WPC fronts \(frontChipTime), to about 50 mi"
    }

    /// A toggled-on layer that draws nothing must say why, or it reads as broken.
    @ViewBuilder private var windCalmNote: some View {
        if showWind, model.windSampled, model.windArrows.isEmpty {
            Text("Winds under 3 kt across the map right now, so there is no wind to draw.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var radarControls: some View {
        HStack(spacing: 12) {
            Button {
                model.playing.toggle()
            } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(.plain)

            Slider(
                value: Binding(
                    get: { Double(model.index) },
                    set: { model.index = Int($0.rounded()); model.playing = false }
                ),
                in: 0...Double(max(1, model.frames.count - 1)),
                step: 1
            )

            Text(timeLabel)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(timeLabelColor)
                .frame(width: 84, alignment: .trailing)
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

    private var timeLabel: String {
        guard let f = currentFrame else { return "" }
        if f.iemLayer != nil {
            let hrs = max(1, Int(((Double(f.time) - Date().timeIntervalSince1970) / 3600).rounded()))
            return "+\(hrs)h model"
        }
        let mins = Int((Date().timeIntervalSince1970 - Double(f.time)) / 60)
        if f.nowcast { return "+\(max(0, -mins))m forecast" }
        return mins <= 1 ? "now" : "\(mins)m ago"
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
