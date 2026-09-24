//  HomeLayout.swift
//  Barry — iOS
//
//  Which cards the home screen shows and in what order. The hero and the
//  verdict are fixed; everything under them is a card in this list. Each
//  card still decides for itself whether it has anything to say (lightning
//  only when there is lightning, the Strip card only off-field), so hiding
//  is a second gate on top of that, not a replacement for it.

import SwiftUI

enum HomeCard: String, CaseIterable, Codable, Identifiable {
    case lightning
    case chart
    case taf
    case rainWind
    case conditions
    case strip
    case wind
    case radar
    case sensor
    case sources

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lightning:  return "Lightning nearby"
        case .chart:      return "Trend chart"
        case .taf:        return "TAF timeline"
        case .rainWind:   return "Forecast"
        case .conditions: return "Conditions"
        case .strip:      return "Here (off-field)"
        case .wind:       return "Wind"
        case .radar:      return "Radar"
        case .sensor:     return "Sensor vs station"
        case .sources:    return "Data sources"
        }
    }

    /// The chart is the app; it can move but not hide. The sources line
    /// carries the forecast data's required credit, so it stays too; it is
    /// drawn at the foot of the page and left out of the editor.
    var canHide: Bool { self != .chart && self != .sources }

    /// Cards with a long-press menu. The chart and the radar map have press
    /// gestures of their own; the sources line is not a card.
    var hasMenu: Bool { canHide && self != .radar }
}

struct HomeLayout: Codable, Equatable {
    var order: [HomeCard]
    var hidden: Set<HomeCard>

    static let everything = HomeLayout(order: HomeCard.allCases, hidden: [])

    /// Cards that start hidden until someone turns them on: the TAF strip,
    /// since a pilot already knows the home field's category at a glance.
    static let offByDefault: Set<HomeCard> = [.taf]

    /// A fresh install: everything, minus the cards that start hidden.
    static let initial = HomeLayout(order: HomeCard.allCases, hidden: offByDefault)


    func isVisible(_ card: HomeCard) -> Bool { !hidden.contains(card) || !card.canHide }

    /// Bring a stored layout up to date: drop ids that no longer exist,
    /// append cards added since it was saved (hidden when they start that
    /// way), never hide the chart.
    func normalized() -> HomeLayout {
        var seen = Set<HomeCard>()
        var order = self.order.filter { seen.insert($0).inserted }
        var hidden = self.hidden
        for c in HomeCard.allCases where !seen.contains(c) {
            order.append(c)
            if Self.offByDefault.contains(c) { hidden.insert(c) }
        }
        return HomeLayout(order: order, hidden: hidden.filter { $0.canHide })
    }
}

// MARK: - What Barry is set up for

/// Who Barry is set up for: a bundle of settings that already exist (the
/// cards and their order, wind unit, runway winds, the radar's layers, the
/// Aloft ceiling, how big a pressure change alerts). Choosing one writes
/// them; everything stays editable afterwards, and nothing new is stored
/// beyond the choice itself (review 2026-09-24).
enum Audience: String, CaseIterable, Identifiable {
    case pilot, soaring, drone, marine, everyday, weather
    static let key = "audience"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .pilot: return "Flying"
        case .soaring: return "Soaring and free flight"
        case .drone: return "Drones"
        case .marine: return "On the water"
        case .everyday: return "Everyday, and feeling the weather"
        case .weather: return "Weather watching"
        }
    }

    var shortLabel: String {
        switch self {
        case .pilot: return "Flying"
        case .soaring: return "Soaring"
        case .drone: return "Drones"
        case .marine: return "On the water"
        case .everyday: return "Everyday"
        case .weather: return "Weather watching"
        }
    }

    var icon: String {
        switch self {
        case .pilot: return "airplane"
        case .soaring: return "wind"
        case .drone: return "paperplane"
        case .marine: return "sailboat"
        case .everyday: return "house"
        case .weather: return "cloud.sun"
        }
    }

    static var stored: Audience? {
        Audience(rawValue: AppConfig.sharedDefaults.string(forKey: key) ?? "")
    }

    var layout: HomeLayout {
        switch self {
        case .pilot:
            // The field first, the phone sensor out of the way.
            return HomeLayout(order: [.lightning, .chart, .taf, .conditions, .wind, .strip, .rainWind, .radar, .sensor, .sources],
                              hidden: [.sensor, .taf])
        case .soaring:
            // Conditions (the ride, the cloud base) right under the trend.
            return HomeLayout(order: [.lightning, .chart, .conditions, .rainWind, .radar, .wind, .strip, .taf, .sensor, .sources],
                              hidden: [.taf, .sensor])
        case .drone:
            // Wind first; no runways, no approach-plate talk.
            return HomeLayout(order: [.lightning, .wind, .rainWind, .chart, .radar, .conditions, .strip, .taf, .sensor, .sources],
                              hidden: [.taf, .sensor, .strip])
        case .marine:
            return HomeLayout(order: [.lightning, .chart, .wind, .rainWind, .radar, .conditions, .strip, .taf, .sensor, .sources],
                              hidden: [.taf, .conditions, .strip])
        case .everyday:
            // The trend and the forecast; the aviation cards hidden.
            return HomeLayout(order: [.lightning, .chart, .rainWind, .radar, .sensor, .conditions, .wind, .taf, .strip, .sources],
                              hidden: [.conditions, .wind, .taf, .strip])
        case .weather:
            // The map and the sky, no runway talk.
            return HomeLayout(order: [.lightning, .chart, .radar, .rainWind, .conditions, .sensor, .taf, .wind, .strip, .sources],
                              hidden: [.wind, .strip, .taf])
        }
    }

    /// Knots where the wind is a working number; the region's everyday
    /// unit otherwise.
    var windUnit: WindUnit {
        switch self {
        case .pilot, .soaring, .drone, .marine: return .knots
        case .everyday, .weather: return Locale.current.measurementSystem == .us ? .mph : .kmh
        }
    }

    var runwayWinds: RunwayWindsMode { self == .pilot || self == .soaring ? .auto : .compass }

    var aloftCeilingFt: Int {
        switch self {
        case .pilot: return 18_000
        case .soaring: return 12_000
        case .drone, .marine: return 6_000
        case .everyday, .weather: return 12_000
        }
    }

    var alertLevel: StormAlerter.Level { self == .everyday ? .moderate : .fast }

    /// The radar layers that open by default.
    struct RadarLayers: Equatable {
        var radar = true, isobars = false, troughs = false, wind = false, fronts = false
        var stations = "off", lightning = true
    }

    var radarLayers: RadarLayers {
        switch self {
        case .pilot: return RadarLayers(fronts: true, stations: "barbs")
        case .soaring, .drone: return RadarLayers(wind: true)
        case .marine: return RadarLayers(isobars: true, wind: true, fronts: true)
        case .everyday: return RadarLayers()
        case .weather: return RadarLayers(isobars: true, troughs: true, fronts: true)
        }
    }

    /// Write the bundle. The layout goes through the store when there is one
    /// on screen, so the page follows at once.
    @MainActor
    func apply(store: HomeLayoutStore? = nil) {
        let d = AppConfig.sharedDefaults
        d.set(rawValue, forKey: Self.key)
        d.set(windUnit.rawValue, forKey: "windUnit")
        d.set(runwayWinds.rawValue, forKey: RunwayWindsMode.key)
        d.set(aloftCeilingFt, forKey: AloftLayer.ceilingKey)
        d.set(alertLevel.rawValue, forKey: StormAlerter.levelKey)
        let r = radarLayers
        d.set(r.radar, forKey: "radarShowRadar")
        d.set("off", forKey: "radarField")
        d.set(r.isobars, forKey: "radarIsobars")
        d.set(r.troughs, forKey: "radarTroughs")
        d.set(r.wind, forKey: "radarWindArrows")
        d.set(r.fronts, forKey: "radarFronts")
        d.set(r.stations, forKey: "radarStations")
        if r.stations != "off" { d.set(r.stations, forKey: "radarStationStyleLast") }
        d.set(r.lightning, forKey: "radarStorms")
        if let store {
            store.apply(layout)
        } else if let data = try? JSONEncoder().encode(layout.normalized()) {
            d.set(data, forKey: HomeLayoutStore.key)
        }
    }
}

@MainActor
final class HomeLayoutStore: ObservableObject {
    static let key = "homeLayout.v1"

    @Published var layout: HomeLayout {
        didSet { save() }
    }

    init() {
        if let data = AppConfig.sharedDefaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(HomeLayout.self, from: data) {
            layout = stored.normalized()
        } else {
            layout = .initial
        }
    }

    func isVisible(_ card: HomeCard) -> Bool { layout.isVisible(card) }

    func setHidden(_ card: HomeCard, _ hidden: Bool) {
        guard card.canHide else { return }
        if hidden { layout.hidden.insert(card) } else { layout.hidden.remove(card) }
    }

    func move(from source: IndexSet, to destination: Int) {
        layout.order.move(fromOffsets: source, toOffset: destination)
    }

    func apply(_ preset: HomeLayout) { layout = preset.normalized() }

    private func save() {
        if let data = try? JSONEncoder().encode(layout) {
            AppConfig.sharedDefaults.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Settings screen

struct HomeLayoutView: View {
    @EnvironmentObject var store: HomeLayoutStore

    var body: some View {
        List {
            Section {
                ForEach(store.layout.order.filter { $0 != .sources }) { card in
                    Toggle(card.title, isOn: Binding(
                        get: { store.isVisible(card) },
                        set: { store.setHidden(card, !$0) }))
                    .disabled(!card.canHide)
                }
                .onMove { store.move(from: $0, to: $1) }
            } header: {
                Text("Cards")
            }
        }
        .navigationTitle("Cards")
        .navigationBarTitleDisplayMode(.inline)
        // Nothing to delete, so the grips can stay out all the time.
        .environment(\.editMode, .constant(.active))
    }
}
