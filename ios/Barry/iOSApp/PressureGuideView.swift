//  PressureGuideView.swift
//  Barry — iOS
//
//  "What do pressure changes mean?" explainer, opened from the ⓘ next to the reading.
//
//  The content is grounded in published meteorology, not folklore — every claim maps
//  to one of the cited sources listed at the bottom of the sheet:
//    • Pressure *tendency* = the 3-hour change (NWS Glossary).
//    • Low pressure / falling → clouds, rain; high pressure / rising → fair, dry;
//      an approaching storm shows up as falling pressure (NOAA SciJinks).
//    • Wind is set by the pressure gradient — closely spaced isobars (i.e. fast
//      pressure change) mean strong winds (UK Met Office; Royal Meteorological Soc.).
//    • The most extreme drops mark rapidly intensifying storms — "bombogenesis",
//      ~24 hPa in 24 h at high latitudes (NOAA Ocean Service).

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
                 detail: "A sharp drop usually means a vigorous storm system is moving in quickly — expect thickening cloud, rain, and often strengthening winds. The steepest, deepest drops mark rapidly intensifying storms (an extreme case is called “bombogenesis” — on the order of a 24 hPa fall in 24 hours)."),
        Movement(cls: .fallingMod, intensity: 0.5, title: "Falling",
                 detail: "Falling pressure signals an approaching low-pressure system or front. Weather tends to deteriorate: increasing cloud, with rain becoming more likely."),
        Movement(cls: .steady, intensity: 0, title: "Steady",
                 detail: "Little change expected in the near term — whatever it’s doing now is likely to continue for a while."),
        Movement(cls: .rising, intensity: 0, title: "Rising",
                 detail: "Rising pressure means high pressure is building in. Expect improving, drier, more settled weather."),
        Movement(cls: .risingFast, intensity: 0, title: "Rising fast",
                 detail: "A sharp rise often comes right after a cold front clears through: skies brighten, but the tight pressure gradient behind the front commonly brings gusty, strong winds for a time."),
    ]

    private struct Source: Identifiable {
        let id = UUID()
        let name: String
        let url: URL
    }

    private let sources: [Source] = [
        Source(name: "NOAA SciJinks — High & low pressure systems",
               url: URL(string: "https://scijinks.gov/high-and-low-pressure-systems/")!),
        Source(name: "US National Weather Service — Glossary: pressure tendency",
               url: URL(string: "https://forecast.weather.gov/glossary.php?word=pressure%20tendency")!),
        Source(name: "UK Met Office — How to read synoptic charts (isobars & wind)",
               url: URL(string: "https://weather.metoffice.gov.uk/learn-about/weather/how-weather-works/synoptic-weather-chart")!),
        Source(name: "Royal Meteorological Society — The highs and lows of wind strength",
               url: URL(string: "https://www.rmets.org/metmatters/highs-and-lows-wind-strength")!),
        Source(name: "NOAA Ocean Service — What is bombogenesis?",
               url: URL(string: "https://oceanservice.noaa.gov/facts/bombogenesis.html")!),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Barry watches how fast pressure is **changing** — its “tendency” over the last few hours — because that shift, more than the number itself, is what hints at the weather to come.")
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
                    Text("Wind is driven by how sharply pressure changes across distance. The same steep gradients that make pressure rise or fall **quickly** also tend to bring stronger, gustier winds — so a fast move in either direction is often a heads-up for wind, not just rain or clearing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("These are general tendencies, not guarantees — local terrain, season, and the specific weather system all shape what actually happens. Treat the trend as a nudge, not a certainty.")
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
