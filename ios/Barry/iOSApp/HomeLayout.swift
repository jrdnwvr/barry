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
    /// carries the forecast data's required credit, so it stays too.
    var canHide: Bool { self != .chart && self != .sources }
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

    /// A pilot's day: the field first, the phone sensor out of the way.
    static let pilot = HomeLayout(
        order: [.lightning, .chart, .taf, .conditions, .wind, .strip, .rainWind, .radar, .sensor, .sources],
        hidden: [.sensor, .taf])

    /// Weather first: the map and the sky, no runway talk.
    static let weather = HomeLayout(
        order: [.lightning, .chart, .radar, .rainWind, .conditions, .sensor, .taf, .wind, .strip, .sources],
        hidden: [.wind, .strip, .taf])

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
                HStack(spacing: 8) {
                    presetButton("Pilot", .pilot)
                    presetButton("Weather", .weather)
                    presetButton("Everything", .everything)
                }
                .buttonStyle(.bordered)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } header: {
                Text("Presets")
            }

            Section {
                ForEach(store.layout.order) { card in
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

    private func presetButton(_ title: String, _ preset: HomeLayout) -> some View {
        Button(title) { withAnimation { store.apply(preset) } }
            .frame(maxWidth: .infinity)
            .tint(store.layout == preset.normalized() ? .accentColor : .secondary)
    }
}
