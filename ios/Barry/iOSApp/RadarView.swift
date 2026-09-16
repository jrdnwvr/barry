//  RadarView.swift
//  Barry — iOS
//
//  The radar screen: RadarScreen (pushed, full-bleed map, floating controls,
//  collapsible Layers panel) and RadarPanel, which the iPad dashboard also
//  embeds in compact form. Model and map bridge live in RadarModel.swift and
//  RadarMapView.swift.

import SwiftUI
import MapKit

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
    /// Dashboard embeds run chrome-light: the toggles compress to one button
    /// row and the attribution paragraph stays in the full-screen view, so the
    /// MAP gets the panel's height instead of its own controls (in landscape
    /// the full chrome squeezed the map to a sliver).
    var embedded: Bool = false

    @StateObject private var model = RadarModel()
    @State private var dwellTicks = 0
    @AppStorage("radarWindArrows", store: AppConfig.sharedDefaults)
    private var showWindArrows: Bool = true
    @AppStorage("radarBoundaryLayer", store: AppConfig.sharedDefaults)
    private var showBoundaryLayer: Bool = false
    @AppStorage("radarFronts", store: AppConfig.sharedDefaults)
    private var showFronts: Bool = true
    /// "flow" (animated streaks, the default) or "arrows" (the static grid).
    @AppStorage("radarWindStyle", store: AppConfig.sharedDefaults)
    private var windStyle: String = "flow"
    /// Station layer: "off", "barbs" (METAR wind flags) or "speeds" (labels).
    @AppStorage("radarStations", store: AppConfig.sharedDefaults)
    private var stationStyleRaw: String = "off"
    /// Pressure layer: isobars on by default (it's the point of the app),
    /// isallobars and the shaded field opt-in.
    @AppStorage("radarIsobars", store: AppConfig.sharedDefaults)
    private var showIsobars: Bool = true
    @AppStorage("radarIsallobars", store: AppConfig.sharedDefaults)
    private var showIsallobars: Bool = false
    @AppStorage("radarShade", store: AppConfig.sharedDefaults)
    private var shadeRaw: String = "off"
    @State private var showLayers = false
    @State private var selectedStation: StationObs?

    private var shade: PressureShade { PressureShade(rawValue: shadeRaw) ?? .off }
    private var pressureWanted: Bool { showIsobars || showIsallobars || shade != .off }
    private var pressureState: PressureFieldState? {
        guard pressureWanted else { return nil }
        return PressureFieldState(field: model.pressureField, showIsobars: showIsobars,
                                  showIsallobars: showIsallobars, shade: shade,
                                  version: model.pressureVersion)
    }
    private let ticker = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()

    private var stationStyle: StationLayerStyle { StationLayerStyle(rawValue: stationStyleRaw) ?? .off }

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
            if showWindArrows || showBoundaryLayer {
                await model.fetchField(region: model.lastRegion ?? initialRegion)
            }
            if showFronts {
                await model.fetchFronts()
            }
            // The home barb wants the station's full report (raw METAR) for
            // its sheet, which lives in the slice; fetch it even with the
            // layer off. Server-side it's a cached in-memory slice.
            if stationStyle != .off || home?.asBarb == true {
                await model.fetchStations(center: initialRegion.center)
            }
            if pressureWanted {
                await model.fetchPressureField(region: model.lastRegion ?? initialRegion)
            }
        }
        .onReceive(ticker) { _ in
            guard model.playing, !model.frames.isEmpty else { return }
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
        .onChange(of: stationStyleRaw) { _, raw in
            if raw != "off" {
                Task { await model.fetchStations(center: model.lastRegion?.center ?? initialRegion.center) }
            }
        }
        .onChange(of: showFronts) { _, on in
            if on, model.frontFrames.isEmpty {
                Task { await model.fetchFronts() }
            }
        }
        .onChange(of: pressureWanted) { _, on in
            if on, model.pressureField == nil {
                Task { await model.fetchPressureField(region: model.lastRegion ?? initialRegion) }
            }
        }
        // Fetch triggers live on the container so the compact and full toggle
        // variants share them.
        .onChange(of: showWindArrows) { _, on in
            if on {
                Task { await model.fetchField(region: model.lastRegion ?? initialRegion) }
            }
        }
        .onChange(of: showBoundaryLayer) { _, on in
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
                     center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                     windArrows: model.windArrows,
                     showWind: showWindArrows && windStyle == "arrows",
                     windFlow: (showWindArrows && windStyle == "flow") ? model.windField : nil,
                     blPoints: model.blPoints,
                     showBL: showBoundaryLayer,
                     frontState: showFronts ? model.frontState : nil,
                     stations: model.stationObs,
                     stationStyle: stationStyle,
                     onSelectStation: { selectedStation = $0 },
                     home: home,
                     pressureState: pressureState,
                     onRegionChange: { region in
                         model.scheduleFieldReload(for: region,
                                                   wind: showWindArrows,
                                                   boundaryLayer: showBoundaryLayer,
                                                   stations: stationStyle != .off,
                                                   pressure: pressureWanted)
                     })
    }

    /// Full screen: the map fills the view; the scrubber and front chips float
    /// in a card at the bottom, the layer toggles hide behind a Layers button.
    private var fullScreenContent: some View {
        GeometryReader { geo in
        ZStack(alignment: .bottom) {
            mapView
                .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Spacer()
                    // Leave room for the bottom card and the front key on
                    // short phones; the panel scrolls inside that.
                    layersColumn(maxPanelHeight: max(220, geo.size.height - 250))
                }
                .padding(12)

                Spacer(minLength: 0)

                if showFronts, !model.frontFrames.isEmpty {
                    HStack(alignment: .bottom) {
                        FrontKeyView(validText: frontValidText, compact: true)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }

                bottomCard
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        }
    }

    /// The Layers button and, when open, the panel beneath it.
    private func layersColumn(maxPanelHeight: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { showLayers.toggle() }
            } label: {
                Image(systemName: showLayers ? "xmark" : "square.3.layers.3d")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .padding(10)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showLayers ? "Hide layers" : "Layers")

            if showLayers {
                ScrollView(showsIndicators: false) {
                    layersPanel
                }
                .frame(width: 290)
                .frame(maxHeight: maxPanelHeight)
                .fixedSize(horizontal: false, vertical: true)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
            }
        }
    }

    private var layersPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $showWindArrows) {
                Label("Wind", systemImage: "wind")
            }
            if showWindArrows {
                Picker("Wind style", selection: $windStyle) {
                    Text("Flow").tag("flow")
                    Text("Arrows").tag("arrows")
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
            windCalmNote

            Toggle(isOn: $showBoundaryLayer) {
                Label("Boundary layer top", systemImage: "cloud.fog")
            }
            if showBoundaryLayer {
                Text("Model boundary layer top in feet above ground. Bumpy, hazy air mixes below it, smoother air above.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Toggle(isOn: $showFronts) {
                Label("Fronts", systemImage: "line.diagonal")
            }

            Toggle(isOn: $showIsobars) {
                Label("Isobars", systemImage: "circle.circle")
            }
            Toggle(isOn: $showIsallobars) {
                Label("Pressure change", systemImage: "arrow.down.right.circle")
            }
            if showIsallobars {
                Text("Where pressure fell or rose over the last 3 h, from Barry's own station history. Red dashed: falling. Blue: rising.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Label("Shade the map by", systemImage: "square.stack.3d.down.forward")
            Picker("Shade", selection: $shadeRaw) {
                Text("Off").tag("off")
                Text("Pressure").tag("pressure")
                Text("Change").tag("change")
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            Label("Stations", systemImage: "mappin.and.ellipse")
            Picker("Stations", selection: $stationStyleRaw) {
                Text("Off").tag("off")
                Text("Barbs").tag("barbs")
                Text("Speeds").tag("speeds")
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            if stationStyle != .off {
                HStack(spacing: 10) {
                    ForEach(FlightCategory.order, id: \.self) { cat in
                        HStack(spacing: 3) {
                            Circle().fill(FlightCategory.color(cat)).frame(width: 7, height: 7)
                            Text(cat)
                        }
                    }
                    Spacer()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Divider()
            legend
        }
        .font(.subheadline)
        .padding(12)
    }

    /// The things you actually touch: radar scrubber, front chips, and the
    /// one-line attribution that must stay on screen.
    private var bottomCard: some View {
        VStack(spacing: 8) {
            controls
            if showFronts, model.frontFrames.count > 1 {
                frontTimeline
            }
            Text("Radar RainViewer · NOAA NEXRAD · Wind Open-Meteo · Fronts NWS WPC")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The iPad dashboard embed: map in a rounded card, compact controls below.
    private var embeddedContent: some View {
        VStack(spacing: 10) {
            mapView
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomLeading) {
                    if showFronts, !model.frontFrames.isEmpty {
                        FrontKeyView(validText: frontValidText, compact: true)
                            .padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let onExpand {
                        Button(action: onExpand) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 14, weight: .semibold))
                                .padding(9)
                                .background(.thinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .accessibilityLabel("Expand radar")
                    }
                }

            controls

            if showFronts, model.frontFrames.count > 1 {
                frontTimeline
            }

            // Two short rows — one row of buttons + swatches doesn't fit the
            // portrait column and SwiftUI "fixes" that by wrapping the button
            // titles mid-word.
            VStack(alignment: .leading, spacing: 8) {
                // Two rows: five buttons on one row is wider than the iPad
                // mini's portrait column and pushes the whole dashboard off
                // the right edge of the screen.
                HStack(spacing: 10) {
                    compactToggle("Wind", icon: "wind", isOn: $showWindArrows)
                    compactToggle("Layer top", icon: "cloud.fog", isOn: $showBoundaryLayer)
                    compactToggle("Fronts", icon: "line.diagonal", isOn: $showFronts)
                    Spacer()
                }
                HStack(spacing: 10) {
                    compactToggle("Isobars", icon: "circle.circle", isOn: $showIsobars)
                    compactToggle("Barbs", icon: "flag", isOn: Binding(
                        get: { stationStyleRaw == "barbs" },
                        set: { stationStyleRaw = $0 ? "barbs" : "off" }))
                    Spacer()
                }
                windCalmNote
                HStack(spacing: 14) {
                    swatch(Color(red: 0.55, green: 0.75, blue: 0.95), "Light")
                    swatch(Color(red: 0.13, green: 0.42, blue: 0.82), "Moderate")
                    swatch(Color(red: 0.94, green: 0.65, blue: 0.15), "Heavy")
                    Spacer()
                }
            }
        }
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
        if showWindArrows, model.windSampled, model.windArrows.isEmpty {
            Text("Winds under 3 kt across the map right now, so there are no arrows to draw.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func compactToggle(_ title: String, icon: String,
                               isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: icon)
                .font(.caption)
                .lineLimit(1)
                .fixedSize()  // never wrap the title mid-word under compression
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var controls: some View {
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

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                swatch(Color(red: 0.55, green: 0.75, blue: 0.95), "Light")
                swatch(Color(red: 0.13, green: 0.42, blue: 0.82), "Moderate")
                swatch(Color(red: 0.94, green: 0.65, blue: 0.15), "Heavy")
                Spacer()
            }
            Text(footerText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// The nowcast/model sentences track the model-frames flag so the footer
    /// never describes frames that can't appear.
    private var footerText: String {
        var text = "Wind streaks and arrows are the Open-Meteo model wind; stations are real METAR reports in knots. "
        if RadarModel.modelFramesEnabled {
            text += "Purple frames are HRRR model reflectivity via Iowa Environmental Mesonet, a guess, not a measurement. "
        }
        text += "Radar by RainViewer from NOAA NEXRAD. Fronts from the NWS Weather Prediction Center, positions good to about 50 miles."
        return text
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 14, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
