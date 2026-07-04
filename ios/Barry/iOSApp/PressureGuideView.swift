//  PressureGuideView.swift
//  Barry — iOS
//
//  "What do pressure changes mean?" explainer, opened from the ⓘ next to the reading.
//
//  The content is grounded in published meteorology, not folklore — every claim maps
//  to one of the cited sources listed at the bottom of the sheet:
//    • Pressure *tendency* = the 3-hour change (NWS Glossary).
//    • Low pressure / falling → clouds, rain; high pressure / rising → settled, dry
//      (UK Met Office, "High and low pressure").
//    • Wind is set by the pressure gradient — closely spaced isobars (i.e. fast
//      pressure change) mean strong winds (UK Met Office, synoptic charts).
//    • The most extreme drops mark rapidly intensifying storms — "bombogenesis",
//      ~24 hPa in 24 h at 60° latitude, less nearer the equator (NOAA Ocean Service).

import SwiftUI

struct PressureGuideView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Movement: Identifiable {
        let id = UUID()
        let cls: TendencyClass
        let intensity: Double
        let title: String
        let detail: String
    }

    private let movements: [Movement] = [
        Movement(cls: .fallingFast, intensity: 1.0, title: "Falling fast",
                 detail: "A sharp drop usually means a storm system is moving in fast. Expect thickening cloud, rain, and often stronger wind. The steepest drops mark rapidly intensifying storms. The extreme case is called bombogenesis, roughly a 24 hPa fall in 24 hours (less at lower latitudes)."),
        Movement(cls: .fallingMod, intensity: 0.5, title: "Falling",
                 detail: "Falling pressure means a low or a front is headed your way. Expect more cloud and a better chance of rain."),
        Movement(cls: .steady, intensity: 0, title: "Steady",
                 detail: "Little change expected soon. Whatever it's doing now will probably keep doing it for a while."),
        Movement(cls: .rising, intensity: 0, title: "Rising",
                 detail: "Rising pressure means high pressure is building in. Expect drier, more settled weather."),
        Movement(cls: .risingFast, intensity: 0, title: "Rising fast",
                 detail: "A sharp rise usually comes right after a cold front clears through. Skies brighten, but the wind behind the front is often strong and gusty for a while."),
    ]

    private struct Term: Identifiable {
        let id = UUID()
        let name: String
        let meaning: String
    }

    // Terms Barry uses in its verdicts and on the chart (pins like "trough",
    // "front edge"). Definitions follow the NWS Weather Glossary (see Sources).
    private let terms: [Term] = [
        Term(name: "Front",
             meaning: "A boundary between two air masses of different temperature. When one passes you usually get a wind shift, more cloud, and rain. It shows up as a pressure trough."),
        Term(name: "Trough",
             meaning: "A stretch of relatively low pressure, where the curve bottoms out. Often marks a front and unsettled weather. Barry pins the low as trough, then past trough once pressure is recovering."),
        Term(name: "Ridge",
             meaning: "A stretch of relatively high pressure, where the curve peaks. Generally fair, settled weather."),
        Term(name: "Front edge",
             meaning: "The sharp kink where a front's pressure change starts. Barry flags it when the curve turns down abruptly."),
        Term(name: "Gust front",
             meaning: "The leading edge of gusty wind pushed out ahead of a storm's downdraft. A sudden burst of wind, often with a sharp pressure rise."),
        Term(name: "Tendency",
             meaning: "How fast and which way the pressure has moved over the last 3 hours or so. This is the signal Barry reads."),
    ]

    private struct Source: Identifiable {
        let id = UUID()
        let name: String
        let url: URL
    }

    // Verified reachable 2026-07 — SciJinks (expired TLS cert) and RMetS (blocked)
    // were replaced by the Met Office pressure-systems page, which covers the same
    // claims (high = settled, low = unsettled/rain/wind).
    private let sources: [Source] = [
        Source(name: "US National Weather Service — Weather Glossary (pressure tendency, front, trough, ridge, gust front)",
               url: URL(string: "https://forecast.weather.gov/glossary.php")!),
        Source(name: "UK Met Office — High and low pressure",
               url: URL(string: "https://weather.metoffice.gov.uk/learn-about/weather/how-weather-works/high-and-low-pressure")!),
        Source(name: "UK Met Office — How to read synoptic charts (isobars & wind)",
               url: URL(string: "https://weather.metoffice.gov.uk/learn-about/weather/how-weather-works/synoptic-weather-chart")!),
        Source(name: "NOAA Ocean Service — What is bombogenesis?",
               url: URL(string: "https://oceanservice.noaa.gov/facts/bombogenesis.html")!),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Barry watches how fast the pressure is changing over the last few hours. That shift matters more than the number itself. It's what hints at the weather to come.")
                        .font(.subheadline)
                        .listRowSeparator(.hidden)
                }

                Section("What each movement suggests") {
                    ForEach(movements) { m in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: m.cls.symbolName)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(m.cls.color(intensity: m.intensity))
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(m.title).font(.subheadline.weight(.semibold))
                                Text(m.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section("Why fast changes hint at wind") {
                    Text("Wind comes from pressure differences. The same steep gradients that make pressure move quickly also bring stronger, gustier wind. A fast move in either direction is a heads-up for wind, not just rain or clearing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("A big change isn't a guarantee") {
                    Text("Pressure can move a lot without any dramatic weather. Dry fronts pass with little more than a wind shift, and some swings are just the atmosphere rebalancing. Read the trend along with the sky and the wind and rain forecast below the chart. If it already looks bad out, the trend is your best clue for timing and intensity. If the forecast stays calm and dry, a big move might just mean a breezy change.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Terms you'll see") {
                    ForEach(terms) { term in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(term.name).font(.subheadline.weight(.semibold))
                            Text(term.meaning).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    Text("These are general tendencies, not guarantees. Terrain, season, and the specific system all shape what actually happens. Treat the trend as a nudge, not a certainty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Sources") {
                    ForEach(sources) { s in
                        Link(destination: s.url) {
                            HStack {
                                Text(s.name).font(.caption)
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pressure & weather")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
