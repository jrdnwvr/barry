//  SavedLocations.swift
//  Barry — Shared
//
//  Multiple saved locations: a pinned "My location" entry plus any number of
//  airports and geocoded places, with one selected at a time. Replaces the old
//  single-choice locationMode/homeStation/place keys on iOS (which are migrated
//  on first run and left in place for the watch, whose store is device-local).
//
//  The backend was multi-station from day one (registry + batched scheduler
//  scale by station, not user) — this is purely client-side state.

import Foundation
import SwiftUI

struct SavedLocation: Codable, Equatable, Identifiable {
    enum Kind: Codable, Equatable {
        case currentLocation
        case airport(icao: String)
        case place(lat: Double, lon: Double, label: String)
    }

    var id = UUID()
    var kind: Kind

    var title: String {
        switch kind {
        case .currentLocation:          return "My location"
        case .airport(let icao):        return icao
        case .place(_, _, let label):   return label
        }
    }

    var subtitle: String? {
        switch kind {
        case .currentLocation:        return "Nearest station to you"
        case .airport:                return "Airport station"
        case .place(let lat, let lon, _):
            return String(format: "%.3f, %.3f", lat, lon)
        }
    }

    /// True when this entry describes where the device physically is — the only
    /// place the phone barometer's calibration and LOCAL readings are valid.
    var isPhysical: Bool {
        if case .currentLocation = kind { return true }
        return false
    }
}

@MainActor
final class SavedLocationsStore: ObservableObject {
    @Published var locations: [SavedLocation] {
        didSet { save() }
    }
    @Published var selectedID: UUID {
        didSet { save() }
    }

    private static let listKey = "savedLocations.v1"
    private static let selectedKey = "savedLocations.selected.v1"

    var selected: SavedLocation {
        locations.first { $0.id == selectedID } ?? locations[0]
    }

    init() {
        let d = AppConfig.sharedDefaults
        if let data = d.data(forKey: Self.listKey),
           let list = try? JSONDecoder().decode([SavedLocation].self, from: data),
           !list.isEmpty {
            locations = list
            if let raw = d.string(forKey: Self.selectedKey),
               let id = UUID(uuidString: raw),
               list.contains(where: { $0.id == id }) {
                selectedID = id
            } else {
                selectedID = list[0].id
            }
            return
        }

        // First run after upgrade: seed from the legacy single-location keys so
        // nobody's saved airport or place silently vanishes.
        var list = [SavedLocation(kind: .currentLocation)]
        let legacyStation = (d.string(forKey: "homeStation") ?? "").uppercased()
        if !legacyStation.isEmpty, legacyStation != AppConfig.defaultStation {
            list.append(SavedLocation(kind: .airport(icao: legacyStation)))
        }
        let label = d.string(forKey: "placeLabel") ?? ""
        let lat = d.double(forKey: "placeLat")
        let lon = d.double(forKey: "placeLon")
        if !label.isEmpty, lat != 0 || lon != 0 {
            list.append(SavedLocation(kind: .place(lat: lat, lon: lon, label: label)))
        }

        let selected: SavedLocation
        switch d.string(forKey: "locationMode") {
        case "airport":
            selected = list.first { if case .airport = $0.kind { return true }; return false } ?? list[0]
        case "place":
            selected = list.first { if case .place = $0.kind { return true }; return false } ?? list[0]
        default:
            selected = list[0]
        }
        locations = list
        selectedID = selected.id
        save()
    }

    /// Add and (optionally) select. Airports de-dup by ICAO — adding an existing
    /// one just selects it.
    func add(_ location: SavedLocation, select: Bool = true) {
        if case .airport(let icao) = location.kind,
           let existing = locations.first(where: {
               if case .airport(let e) = $0.kind { return e == icao }
               return false
           }) {
            if select { selectedID = existing.id }
            return
        }
        locations.append(location)
        if select { selectedID = location.id }
    }

    /// Remove entries (the pinned current-location entry is never removable).
    /// Removing the selected entry falls back to "My location".
    func remove(at offsets: IndexSet) {
        let removable = offsets.filter { !locations[$0].isPhysical }
        let removedIDs = removable.map { locations[$0].id }
        locations.remove(atOffsets: IndexSet(removable))
        if removedIDs.contains(selectedID), let first = locations.first {
            selectedID = first.id
        }
    }

    private func save() {
        let d = AppConfig.sharedDefaults
        if let data = try? JSONEncoder().encode(locations) {
            d.set(data, forKey: Self.listKey)
        }
        d.set(selectedID.uuidString, forKey: Self.selectedKey)
    }
}
