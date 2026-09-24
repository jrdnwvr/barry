//  StormAlerter.swift
//  Barry — iOS
//
//  Local notifications, two kinds, each its own switch:
//    Pressure changes: the 3-hour tendency crosses into falling_fast (weather
//      on the way) or rising_fast (a gust front, sharp clearing).
//    Storms: lightning within reach and heading this way, or thunderstorms
//      likely at the station in the next few hours.
//  No push server: everything is local, driven by the existing
//  BGAppRefreshTask (BackgroundRefresh). Each kind has a latch so an ongoing
//  event alerts once per cooldown, not once per background check.

import Foundation
import UserNotifications

enum StormAlerter {
    /// The user-facing switches (shared suite). `enabledKey` kept its old
    /// name so nobody's storms switch resets; pressure alerts got their own
    /// and are seeded from it once (migrateKeys).
    static let enabledKey = "stormAlertsEnabled"
    static let pressureKey = "pressureAlertsEnabled"
    private static let migratedKey = "alerts.migrated.v2"

    static let pressureCooldown: TimeInterval = 3 * 3600
    static let lightningCooldown: TimeInterval = 1 * 3600
    static let forecastCooldown: TimeInterval = 6 * 3600
    static let lightningRangeMi = 25
    static let lightningCloseMi = 10
    static let forecastWindow: TimeInterval = 3 * 3600

    /// Before the split, one switch meant pressure alerts. Anyone who had it
    /// on keeps them, and gets storms as well, which is what the switch said.
    static func migrateKeys() {
        let d = AppConfig.sharedDefaults
        guard !d.bool(forKey: migratedKey) else { return }
        if d.object(forKey: pressureKey) == nil, d.bool(forKey: enabledKey) {
            d.set(true, forKey: pressureKey)
        }
        d.set(true, forKey: migratedKey)
    }

    /// "3.2 hPa" or "0.09 inHg": the 3 h change in the unit the user chose.
    static func magnitude(_ deltaHPa: Double) -> String {
        let unit = PressureUnit(rawValue: AppConfig.sharedDefaults.string(forKey: "pressureUnit") ?? "") ?? .inHg
        let v = abs(unit.convertDelta(deltaHPa))
        return String(format: unit == .hPa ? "%.1f %@" : "%.2f %@", v, unit.label)
    }

    // MARK: - Authorization

    @discardableResult
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Decisions (pure, so they test)

    struct Alert: Equatable {
        let latch: String          // which ongoing event this is
        let cooldown: TimeInterval
        let title: String
        let body: String
    }

    /// The pressure alert the reading calls for, if any.
    static func pressureAlert(_ combined: CombinedResponse) -> Alert? {
        guard let tendency = combined.tendency else { return nil }
        let place = combined.pressure.name ?? combined.pressure.station
        let mag = magnitude(tendency.delta3h)
        switch tendency.cls {
        case .fallingFast:
            return Alert(latch: "pressure.falling_fast", cooldown: pressureCooldown,
                         title: "Pressure dropping fast",
                         body: "Down \(mag) in 3 h at \(place). \(combined.verdict)")
        case .risingFast:
            return Alert(latch: "pressure.rising_fast", cooldown: pressureCooldown,
                         title: "Pressure rising sharply",
                         body: "Up \(mag) in 3 h at \(place). \(combined.verdict)")
        default:
            return nil
        }
    }

    /// The storm alert the reading calls for, if any. Lightning wins over a
    /// forecast: something real and close beats something likely and later.
    static func stormAlert(_ combined: CombinedResponse, now: Date = Date()) -> Alert? {
        let place = combined.pressure.name ?? combined.pressure.station
        let clock = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        if let l = combined.lightningNearby,
           now.timeIntervalSince(l.at) <= 30 * 60,
           l.distanceMi <= lightningRangeMi,
           l.towardYou == true || l.distanceMi <= lightningCloseMi {
            var body = l.distanceMi < 3 ? "At \(place)." : "\(l.distanceMi) mi to the \(Cardinal.word(l.cardinal)) of \(place)"
            if l.distanceMi >= 3 {
                if l.towardYou == true {
                    body += l.etaAt.map { ", moving this way. About \(clock($0))." } ?? ", moving this way."
                } else {
                    body += "."
                }
            }
            return Alert(latch: "storm.lightning", cooldown: lightningCooldown,
                         title: "Lightning nearby", body: body)
        }
        if let s = combined.conditions?.storm {
            if s.risk == "observed", let d = s.distanceMi, d <= lightningCloseMi {
                // The server's sentence carries an {eta} slot; the card fills
                // it and so must the notification.
                let detail = s.etaAt.map { s.detail.replacingOccurrences(of: "{eta}", with: clock($0)) }
                    ?? s.detail.replacingOccurrences(of: " {eta}", with: "").replacingOccurrences(of: "{eta}", with: "")
                return Alert(latch: "storm.lightning", cooldown: lightningCooldown,
                             title: "Thunderstorms at \(place)", body: detail)
            }
            if s.risk == "likely", s.start.map({ $0.timeIntervalSince(now) <= forecastWindow }) ?? true,
               s.end.map({ $0 > now }) ?? true {
                var body = "At \(place)"
                if let a = s.start, let b = s.end, b > a { body += " from \(clock(a)) to \(clock(b))" }
                else if let a = s.start { body += " around \(clock(a))" }
                body += "."
                return Alert(latch: "storm.forecast", cooldown: forecastCooldown,
                             title: "Thunderstorms likely", body: body)
            }
        }
        return nil
    }

    // MARK: - Evaluate

    /// Post whatever the reading calls for, once per event. Safe from a
    /// background task; a no-op unless a switch is on and iOS allows it.
    static func evaluate(_ combined: CombinedResponse?, pressure: Bool, storms: Bool,
                         now: Date = Date()) async {
        guard pressure || storms, let combined else { return }
        var due: [Alert] = []
        if pressure, let a = pressureAlert(combined) { due.append(a) }
        if storms, let a = stormAlert(combined, now: now) { due.append(a) }
        due = due.filter { shouldAlert($0, now: now) }
        guard !due.isEmpty, await authorizationStatus() == .authorized else { return }
        for a in due {
            let c = UNMutableNotificationContent()
            c.title = a.title
            c.body = a.body
            c.sound = .default
            let request = UNNotificationRequest(identifier: "\(a.latch)_\(Int(now.timeIntervalSince1970))",
                                                content: c, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
            latch(a, now: now)
        }
    }

    /// The old entry point, kept for anything still calling it.
    static func evaluate(_ combined: CombinedResponse?, enabled: Bool, now: Date = Date()) async {
        await evaluate(combined, pressure: enabled, storms: enabled, now: now)
    }

    // MARK: - Test

    /// A sample of each kind that is on, a few seconds out so the phone can
    /// be locked to see it land.
    static func sendTestAlert(pressure: Bool, storms: Bool) {
        var samples: [(String, String, String)] = []
        if pressure {
            samples.append(("test_pressure", "Pressure dropping fast",
                            "Down \(magnitude(-3.2)) in 3 h at your station. Weather on the way. (Test)"))
        }
        if storms {
            samples.append(("test_storm", "Lightning nearby",
                            "12 mi to the west of your station, moving this way. (Test)"))
        }
        for (i, (id, title, body)) in samples.enumerated() {
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3 + Double(i) * 2, repeats: false)
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: trigger))
        }
    }

    static func sendTestAlert() { sendTestAlert(pressure: true, storms: false) }

    // MARK: - Throttle latch

    private static func shouldAlert(_ a: Alert, now: Date) -> Bool {
        guard let last = AppConfig.sharedDefaults.object(forKey: "alert.latch.\(a.latch)") as? Date else { return true }
        return now.timeIntervalSince(last) >= a.cooldown
    }

    private static func latch(_ a: Alert, now: Date) {
        AppConfig.sharedDefaults.set(now, forKey: "alert.latch.\(a.latch)")
    }
}

// MARK: - Foreground presentation

/// Lets alerts surface as a banner even while Barry is open — useful for the
/// test button and any alert that lands mid-session.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
