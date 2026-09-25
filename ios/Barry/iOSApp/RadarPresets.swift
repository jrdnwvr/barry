//  RadarPresets.swift
//  Barry — iOS
//
//  Radar layer presets the user saves: every chip's state (and the wind
//  style and buoys that go with them) under a name, kept in the shared
//  store. Map options lists them; a tap puts the map back the way it was
//  saved. They replaced the fixed layer sets (2026-09-25).

import Foundation

struct RadarPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var radar = true
    var field = "off"            // off, pressure, change
    var isobars = false
    var wind = true
    var windStyle = "flow"
    var fronts = true
    var troughs = true
    var stations = "off"         // off, barbs, speeds
    var lightning = true
    var advisories = false
    var buoys = false

    /// The map as it is now, from the same switches the chips write. The
    /// defaults match the radar screen's own.
    static func current(named name: String = "", defaults d: UserDefaults = AppConfig.sharedDefaults) -> RadarPreset {
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        return RadarPreset(
            name: name,
            radar: bool("radarShowRadar", true),
            field: d.string(forKey: "radarField") ?? "off",
            isobars: bool("radarIsobars", false),
            wind: bool("radarWindArrows", true),
            windStyle: d.string(forKey: "radarWindStyle") ?? "flow",
            fronts: bool("radarFronts", true),
            troughs: bool("radarTroughs", true),
            stations: d.string(forKey: "radarStations") ?? "off",
            lightning: bool("radarStorms", true),
            advisories: bool("radarAdvisories", false),
            buoys: bool(RadarModel.buoysKey, false))
    }

    /// Write every switch; the map follows through its stored settings.
    func apply(defaults d: UserDefaults = AppConfig.sharedDefaults) {
        d.set(radar, forKey: "radarShowRadar")
        d.set(field, forKey: "radarField")
        d.set(isobars, forKey: "radarIsobars")
        d.set(wind, forKey: "radarWindArrows")
        d.set(windStyle, forKey: "radarWindStyle")
        d.set(fronts, forKey: "radarFronts")
        d.set(troughs, forKey: "radarTroughs")
        d.set(stations, forKey: "radarStations")
        if stations != "off" { d.set(stations, forKey: "radarStationStyleLast") }
        d.set(lightning, forKey: "radarStorms")
        d.set(advisories, forKey: "radarAdvisories")
        d.set(buoys, forKey: RadarModel.buoysKey)
    }

    func with(id: UUID) -> RadarPreset {
        var p = self
        p.id = id
        return p
    }

    /// Same layers, whatever the name.
    func sameLayers(as other: RadarPreset) -> Bool {
        var a = self, b = other
        a.id = b.id
        a.name = b.name
        return a == b
    }
}

enum RadarPresetStore {
    static let key = "radarPresets.v1"

    static func load(_ d: UserDefaults = AppConfig.sharedDefaults) -> [RadarPreset] {
        guard let data = d.data(forKey: key),
              let list = try? JSONDecoder().decode([RadarPreset].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [RadarPreset], _ d: UserDefaults = AppConfig.sharedDefaults) {
        if let data = try? JSONEncoder().encode(list) { d.set(data, forKey: key) }
    }
}
