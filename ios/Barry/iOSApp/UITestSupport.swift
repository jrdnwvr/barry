//  UITestSupport.swift
//  Barry — iOS
//
//  The known state a UI test launches into. Only the "-uitest" launch
//  argument turns it on; a normal launch never touches this.

import Foundation

enum UITestSupport {
    static var active: Bool { ProcessInfo.processInfo.arguments.contains("-uitest") }

    /// KLUK unless "-uitest-station KXXX" names another, for hands-on checks
    /// of weather that is somewhere else today.
    static var station: String {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-uitest-station"), args.indices.contains(i + 1) {
            return args[i + 1].uppercased()
        }
        return "KLUK"
    }

    static func prepare() {
        let d = AppConfig.sharedDefaults
        d.set(true, forKey: "hasOnboarded")
        d.set(station, forKey: AppConfig.syncStationKey)
        // The selected airport: no location prompt, a station that always
        // reports, runways for the winds card.
        let airport = SavedLocation(kind: .airport(icao: station))
        let list = [SavedLocation(kind: .currentLocation), airport]
        if let data = try? JSONEncoder().encode(list) {
            d.set(data, forKey: SavedLocationsStore.listKey)
            d.set(airport.id.uuidString, forKey: SavedLocationsStore.selectedKey)
        }
        // The radar's defaults: base on, every overlay off, so the test
        // turns each one on itself.
        d.set(true, forKey: "radarShowRadar")
        d.set("off", forKey: "radarField")
        for key in ["radarIsobars", "radarTroughs", "radarWindArrows", "radarFronts", "radarStorms"] {
            d.set(false, forKey: key)
        }
        d.set("off", forKey: "radarStations")
        d.set(false, forKey: "phoneBarometerEnabled")
        d.set(false, forKey: StormAlerter.enabledKey)
        d.set(false, forKey: StormAlerter.pressureKey)
        RouteSettings.clear()
    }
}
