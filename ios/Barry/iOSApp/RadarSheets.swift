//  RadarSheets.swift
//  Barry — iOS
//
//  Two small sheets off the radar's chip bar. The KEY lists only what is on
//  screen right now (rain swatches, the pressure ramps, front symbols,
//  category colors, the bolts) with the explainer sentences that used to sit
//  on the map. MORE holds the style choices that don't deserve a chip.

import SwiftUI

struct RadarKeySheet: View {
    let base: RadarBase
    let wind: Bool
    let windStyle: String
    let fronts: Bool
    let frontValidText: String
    let stations: Bool
    let stationStyle: StationLayerStyle
    let storms: Bool
    let pressureStations: Int
    var lightningCoverage: Bool? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Key")
                    .font(.title3.weight(.semibold))

                baseSection

                if wind {
                    section("Wind", icon: "wind") {
                        Text(windStyle == "arrows"
                             ? "Arrows point where the model's 10 m wind is blowing, and grow with speed from about 3 kt."
                             : "Streaks drift with the model's 10 m wind. Faster wind, longer and brighter streaks.")
                    }
                }

                if fronts {
                    section("Fronts", icon: "line.diagonal") {
                        FrontKeyView(validText: frontValidText, compact: false)
                        Text("Pips sit on the side the front is moving toward. Positions from the NWS Weather Prediction Center, good to about 50 miles.")
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

                if storms {
                    section("Lightning from orbit", icon: "sparkles") {
                        HStack(spacing: 10) {
                            dotKey(.white, "new", halo: true)
                            dotKey(Color(red: 0.90, green: 0.82, blue: 1.0), "5 min")
                            dotKey(Color(red: 0.68, green: 0.42, blue: 0.95), "10 min")
                            dotKey(Color(red: 0.45, green: 0.25, blue: 0.70).opacity(0.7), "20 min")
                        }
                        .font(.caption)
                        Text("Each dot is a flash seen by NOAA's GOES satellites over the last 20 minutes, bigger where more fell, fading as they age. The radar dims a little while this layer is on so the dots stay readable.")
                        Text("How a satellite sees lightning: from 22,000 miles up, the mapper watches for the burst of light a stroke throws onto the top of its cloud. It sees lightning inside a cloud and strikes to the ground alike, and cannot tell them apart. A dot marks where the cloud lit up, good to about 5 miles, not where a bolt touched down. A stroke buried under a thick anvil, or a weak one in bright daylight, can be missed, and dots arrive a minute or two after the flash.")
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
                        Text("What each station reports in its own METAR. A station with no bolt may simply have no lightning sensor.")
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
        switch base {
        case .radar:
            section("Radar", icon: "antenna.radiowaves.left.and.right") {
                HStack(spacing: 14) {
                    swatch(Color(red: 0.55, green: 0.75, blue: 0.95), "Light")
                    swatch(Color(red: 0.13, green: 0.42, blue: 0.82), "Moderate")
                    swatch(Color(red: 0.94, green: 0.65, blue: 0.15), "Heavy")
                }
                Text("Observed frames every 10 minutes; the last two (orange time) are a short nowcast.")
            }
        case .pressure:
            section("Pressure", icon: "circle.circle") {
                ramp([Color(red: 0.45, green: 0.2, blue: 0.7), Color(red: 0.2, green: 0.45, blue: 0.9),
                      Color(red: 0.2, green: 0.7, blue: 0.5), Color(red: 0.85, green: 0.8, blue: 0.2),
                      Color(red: 0.95, green: 0.5, blue: 0.15)], low: "lower", high: "higher")
                Text("Sea-level pressure from \(pressureStations) reporting stations, gridded by Barry. Isobars every 4 hPa, or 2 on a flat day. The shading is stretched over this area's own range, so it shows structure even when the whole map is within a few hPa.")
            }
        case .change:
            section("Pressure change", icon: "arrow.down.right.circle") {
                ramp([Color(red: 0.9, green: 0.35, blue: 0.15), Color(red: 0.9, green: 0.35, blue: 0.15).opacity(0.15),
                      Color(red: 0.15, green: 0.43, blue: 0.9).opacity(0.15), Color(red: 0.15, green: 0.43, blue: 0.9)],
                     low: "falling", high: "rising")
                Text("How much the pressure moved over the last 3 h at each station, gridded. Solid lines are rises, dashed lines are falls, one line per hPa. H and L mark the strongest rise and fall. Pressure falling toward a front is the change to watch.")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Map options")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Label("Wind style", systemImage: "wind")
                    .font(.subheadline.weight(.semibold))
                Picker("Wind style", selection: $windStyle) {
                    Text("Flow").tag("flow")
                    Text("Arrows").tag("arrows")
                }
                .pickerStyle(.segmented)
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

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
