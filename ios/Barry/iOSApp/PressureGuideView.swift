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
                 detail: "A sharp drop usually means a vigorous storm system is moving in quickly — expect thickening cloud, rain, and often strengthening winds. The steepest, deepest drops mark rapidly intensifying storms (an extreme case is called “bombogenesis” — roughly a 24 hPa fall in 24 hours, less at lower latitudes)."),
        Movement(cls: .fallingMod, intensity: 0.5, title: "Falling",
                 detail: "Falling pressure signals an approaching low-pressure system or front. Weather tends to deteriorate: increasing cloud, with rain becoming more likely."),
        Movement(cls: .steady, intensity: 0, title: "Steady",
                 detail: "Little change expected in the near term — whatever it’s doing now is likely to continue for a while."),
        Movement(cls: .rising, intensity: 0, title: "Rising",
                 detail: "Rising pressure means high pressure is building in. Expect improving, drier, more settled weather."),
        Movement(cls: .risingFast, intensity: 0, title: "Rising fast",
                 detail: "A sharp rise often comes right after a cold front clears through: skies brighten, but the tight pressure gradient behind the front commonly brings gusty, strong winds for a time."),
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
             meaning: "A boundary between two air masses of different temperature. Its passage often brings a wind shift, more cloud, and rain — and it usually shows up as a pressure trough."),
        Term(name: "Trough",
             meaning: "An elongated area of relatively low pressure — where the curve bottoms out. Often marks a front and more unsettled weather. Barry pins the low as “trough,” and “past trough” once pressure is recovering."),
        Term(name: "Ridge",
             meaning: "An elongated area of relatively high pressure — where the curve peaks. Generally fair, settling weather."),
        Term(name: "Front edge",
             meaning: "The sharp kink where a front’s pressure change begins — Barry flags it when the curve turns down abruptly."),
        Term(name: "Gust front",
             meaning: "The leading edge of gusty winds pushed out ahead of a storm’s downdraft — a sudden burst of wind, often with a sharp pressure rise."),
        Term(name: "Tendency",
             meaning: "The direction and rate of the pressure change over the last ~3 hours — the signal Barry reads to say what’s coming."),
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

                Section("A big change isn't a guarantee") {
                    Text("Pressure can move sharply without dramatic weather — dry fronts and troughs pass with little more than a wind shift, and some swings are just the atmosphere rebalancing. Read the trend **together with** the sky and the wind/rain forecast below the chart: if conditions already look threatening, the trend is your best clue to **timing and intensity**; if the forecast stays calm and dry, a big move may amount to nothing more than a breezy change.")
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
