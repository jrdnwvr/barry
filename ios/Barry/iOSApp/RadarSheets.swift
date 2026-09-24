//  RadarSheets.swift
//  Barry — iOS
//
//  Two small sheets off the radar's chip bar. The KEY lists only what is on
//  screen right now (rain swatches, the pressure ramps, front symbols,
//  category colors, the bolts) with the explainer sentences that used to sit
//  on the map. MORE holds the style choices that don't deserve a chip.

import SwiftUI

struct RadarKeySheet: View {
    let radar: Bool
    let field: RadarField
    let isobars: Bool
    let wind: Bool
    let windStyle: String
    let fronts: Bool
    let troughs: Bool
    let frontValidText: String
    let stations: Bool
    let stationStyle: StationLayerStyle
    let storms: Bool
    let pressureStations: Int
    var lightningCoverage: Bool? = nil
    /// The altitude rail's stop in feet, 0 at the surface.
    var windLevelFt: Int = 0
    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var pressureUnitRaw: String = PressureUnit.inHg.rawValue
    private var inHg: Bool { pressureUnitRaw == PressureUnit.inHg.rawValue }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Key")
                    .font(.title3.weight(.semibold))

                baseSection

                if wind {
                    section("Wind", icon: "wind") {
                        let level = windLevelFt > 0
                            ? "the model's wind at about \(windLevelFt.formatted()) ft"
                            : "the model's 10 m wind"
                        Text(windStyle == "arrows"
                             ? "Arrows follow \(level) and scale with speed."
                             : "Streaks drift with \(level).")
                    }
                }

                if fronts {
                    section("Fronts", icon: "line.diagonal") {
                        FrontKeyView(validText: frontValidText, compact: false)
                        Text("Pips sit on the side the front is moving toward. NWS positions, good to about 50 miles.")
                    }
                }

                if stations {
                    section("Stations", icon: "flag") {
                        HStack(spacing: 12) {
                            ForEach(FlightCategory.order, id: \.self) { cat in
                                HStack(spacing: 4) {
                                    Circle().fill(FlightCategory.color(cat)).frame(width: 8, height: 8)
                                    Text(cat)
                                }
                            }
                        }
                        .font(.caption)
                        Text(stationStyle == .speeds
                             ? "Latest METAR wind in knots, tinted by flight category. Tap a station for its report."
                             : "METAR wind barbs: the staff points into the wind, a full barb is 10 kt, a half barb 5, a pennant 50. Tinted by flight category. Tap a station for its report.")
                    }
                }

                if troughs, !fronts {
                    section("Troughs", icon: "point.topleft.down.to.point.bottomright.curvepath") {
                        Text("Dashed lines where the NWS marks a trough: a line of low pressure without a front's temperature change. Showers and a wind shift often ride along it.")
                    }
                }

                if storms {
                    section("Lightning from orbit", icon: "sparkles") {
                        HStack(spacing: 10) {
                            dotKey(.white, "new", halo: true)
                            dotKey(Color(red: 0.90, green: 0.82, blue: 1.0), "5 min")
                            dotKey(Color(red: 0.68, green: 0.42, blue: 0.95), "10 min")
                            dotKey(Color(red: 0.45, green: 0.25, blue: 0.70).opacity(0.7), "20 min")
                        }
                        .font(.caption)
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color(red: 0.62, green: 0.30, blue: 0.95), lineWidth: 2)
                                .frame(width: 22, height: 12)
                            Text("outline: a cell the satellite has seen fire")
                        }
                        Text("Flashes seen by NOAA's GOES satellites in the last 20 minutes. Bigger where more fell, fading with age.")
                        Text("The satellite sees the light a stroke throws onto the cloud top, in-cloud and ground strikes alike. A dot is where the cloud lit up, good to about 5 miles, a minute or two late.")
                        if lightningCoverage == false {
                            Text("The feed is catching up right now, so flashes may be missing.")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if storms || stations {
                    section("Station lightning", icon: "bolt.fill") {
                        HStack(spacing: 14) {
                            boltKey("bolt.fill", LightningInk.color("thunderstorm"), "at the field")
                            boltKey("bolt.fill", LightningInk.color("vicinity"), "close by")
                            boltKey("bolt", LightningInk.color("distant"), "distant")
                        }
                        .font(.caption)
                        Text("Lightning as reported in each station's METAR.")
                    }
                }

                Text("Radar by RainViewer from NOAA NEXRAD. Lightning from NOAA's GOES satellites. Wind and pressure fields from Open-Meteo. Stations from aviationweather.gov. Fronts from the NWS Weather Prediction Center.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var baseSection: some View {
        if radar {
            section("Radar", icon: "antenna.radiowaves.left.and.right") {
                HStack(spacing: 10) {
                    swatch(Color(red: 0.50, green: 0.72, blue: 0.99), "Light")
                    swatch(Color(red: 0.24, green: 0.45, blue: 0.90), "Moderate")
                    swatch(Color(red: 0.22, green: 0.18, blue: 0.68), "Heavy")
                }
                HStack(spacing: 10) {
                    swatch(Color(red: 1.00, green: 0.60, blue: 0.16), "Convective 45+")
                    swatch(Color(red: 0.84, green: 0.13, blue: 0.13), "Severe 55+")
                    swatch(Color(red: 0.90, green: 0.16, blue: 0.86), "Hail likely 60+")
                }
                Text("Blues are rain. Orange is where an echo stops being just rain, in dBZ. Frames every 10 minutes; the ones with an orange time are a short nowcast.")
            }
        }
        switch field {
        case .off:
            EmptyView()
        case .pressure:
            section("Pressure", icon: "circle.circle") {
                ramp([Color(red: 0.45, green: 0.2, blue: 0.7), Color(red: 0.2, green: 0.45, blue: 0.9),
                      Color(red: 0.2, green: 0.7, blue: 0.5), Color(red: 0.85, green: 0.8, blue: 0.2),
                      Color(red: 0.95, green: 0.5, blue: 0.15)], low: "lower", high: "higher")
                Text("Sea-level pressure from \(pressureStations) stations, gridded.")
            }
        case .change:
            section("Pressure change", icon: "arrow.down.right.circle") {
                ramp([Color(red: 0.9, green: 0.35, blue: 0.15), Color(red: 0.9, green: 0.35, blue: 0.15).opacity(0.15),
                      Color(red: 0.15, green: 0.43, blue: 0.9).opacity(0.15), Color(red: 0.15, green: 0.43, blue: 0.9)],
                     low: "falling", high: "rising")
                Text("3 h pressure change at each station, gridded. Solid rising, dashed falling, one line per \(inHg ? "0.03 inHg" : "hPa"). H and L mark the strongest.")
            }
        }
        if isobars {
            section("Isobars", icon: "circle.dashed") {
                Text("Equal sea-level pressure, every \(inHg ? "0.12 inHg, or 0.06" : "4 hPa, or 2") on a flat day. Tighter spacing means more wind, and it runs along them rather than across.")
            }
        }
    }

    private func section<Content: View>(_ title: String, icon: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            content()
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 16, height: 9)
            Text(label)
        }
    }

    private func dotKey(_ color: Color, _ label: String, halo: Bool = false) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color)
                .overlay(Circle().stroke(Color.black.opacity(halo ? 0.55 : 0.25), lineWidth: 1))
                .frame(width: 9, height: 9)
            Text(label)
        }
    }

    private func boltKey(_ symbol: String, _ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(label)
        }
    }

    private func ramp(_ colors: [Color], low: String, high: String) -> some View {
        HStack(spacing: 6) {
            Text(low)
            LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                .frame(height: 10)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(high)
        }
        .font(.caption)
    }
}

struct RadarMoreSheet: View {
    @Binding var windStyle: String
    @Binding var stationStyle: String
    var onStationStyleChange: (String) -> Void
    @Binding var frontLines: Bool
    @Binding var frontPips: Bool
    @Binding var frontWeak: Bool
    @Binding var frontCenters: Bool

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("Map options")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Label("Fronts", systemImage: "line.diagonal")
                    .font(.subheadline.weight(.semibold))
                Toggle("Front lines", isOn: $frontLines)
                Toggle("Cold and warm symbols", isOn: $frontPips)
                Toggle("Fronts marked weak", isOn: $frontWeak)
                Toggle("H and L pressure centers", isOn: $frontCenters)
                Text("Symbols sit on the side the front is moving toward.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            VStack(alignment: .leading, spacing: 6) {
                Label("Wind style", systemImage: "wind")
                    .font(.subheadline.weight(.semibold))
                Picker("Wind style", selection: $windStyle) {
                    Text("Flow").tag("flow")
                    Text("Arrows").tag("arrows")
                }
                .pickerStyle(.segmented)
                Text("Arrows leave out wind under 3 kt; streaks drift everywhere. Station barbs show calm as an open circle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Stations", systemImage: "flag")
                    .font(.subheadline.weight(.semibold))
                Picker("Stations", selection: $stationStyle) {
                    Text("Wind barbs").tag("barbs")
                    Text("Speeds").tag("speeds")
                }
                .pickerStyle(.segmented)
                .onChange(of: stationStyle) { _, style in onStationStyleChange(style) }
                Text("Station names appear once you zoom in; the home station always keeps its name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
