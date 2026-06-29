//  AppConfig.swift
//  Barry — Shared
//
//  Build-wide configuration. Change `backendBaseURL` to your deployed proxy before
//  distribution; the default points at a local dev server.

import Foundation

enum AppConfig {
    /// The caching backend. For on-device testing against a Mac on the same LAN,
    /// use the Mac's LAN IP (http://192.168.x.x:8077) — `127.0.0.1` resolves to the
    /// device itself. For release, point this at the deployed HTTPS endpoint:
    /// https://barry.wide-stack.com  (set via the `BarryBackendURL` Info.plist key).
    static let backendBaseURL: URL = {
        if let s = Bundle.main.object(forInfoDictionaryKey: "BarryBackendURL") as? String,
           let u = URL(string: s) {
            return u
        }
        return URL(string: "http://127.0.0.1:8077")!
    }()

    /// App Group id shared by the iOS app, watch app, and complication so the
    /// complication can render the last-known tendency without its own fetch.
    /// Create this group in Signing & Capabilities for all three targets.
    static let appGroupID = "group.com.wide-stack.barry"

    /// Shared UserDefaults for cross-process settings (unit preference, etc.).
    /// Falls back to `.standard` if the App Group isn't provisioned.
    static let sharedDefaults: UserDefaults =
        UserDefaults(suiteName: appGroupID) ?? .standard

    /// Default home station if the user hasn't set one and location is unavailable.
    static let defaultStation = "KLUK"
}

/// How Barry chooses the "where am I" coordinates for forecast + station lookup.
/// Decoupled from any device-sensor reading (e.g. the upcoming CMAltimeter live
/// pressure dot) — that always comes from the physical device, never from this.
enum LocationMode: String, CaseIterable, Identifiable {
    case device   // CoreLocation one-shot
    case place    // saved geocoded lat/lon (custom location)
    case airport  // explicit ICAO code

    var id: String { rawValue }

    var label: String {
        switch self {
        case .device:  return "My location"
        case .place:   return "Saved place"
        case .airport: return "Airport"
        }
    }
}
