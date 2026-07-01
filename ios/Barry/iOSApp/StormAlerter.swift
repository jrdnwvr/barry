//  StormAlerter.swift
//  Barry — iOS
//
//  Local "storm alert" notifications on a rapid pressure change. When a background
//  refresh sees the 3-hour tendency cross into falling_fast (a storm drop) or
//  rising_fast (a gust front / sharp clearing), Barry posts a local notification —
//  the app's core promise, delivered without opening it.
//
//  No push server: everything is local, driven by the existing BGAppRefreshTask
//  (BackgroundRefresh). Throttled with a per-class latch so an ongoing event alerts
//  at most once per cooldown, and the two fast classes are tracked separately (a
//  drop and a later rise are distinct events).

import Foundation
import UserNotifications

enum StormAlerter {
    /// One ongoing event alerts at most once per this window.
    static let cooldown: TimeInterval = 3 * 3600

    /// AppStorage key for the user-facing toggle (shared suite).
    static let enabledKey = "stormAlertsEnabled"

    private static let lastClassKey = "stormAlert.lastClass"
    private static let lastDateKey = "stormAlert.lastDate"

    // MARK: - Authorization

    /// Ask for notification permission. Returns whether alerts are authorized.
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

    // MARK: - Evaluate

    /// Evaluate the latest reading and post a notification if it just crossed into a
    /// fast-changing class we haven't already alerted for (within the cooldown).
    /// Safe to call from a background task; a no-op unless enabled + authorized.
    static func evaluate(_ combined: CombinedResponse?, enabled: Bool, now: Date = Date()) async {
        guard enabled, let combined, let tendency = combined.tendency else { return }
        let cls = tendency.cls
        guard cls == .fallingFast || cls == .risingFast else { return }
        guard shouldAlert(for: cls, now: now) else { return }
        guard await authorizationStatus() == .authorized else { return }

        let content = makeContent(cls: cls, tendency: tendency, combined: combined)
        let request = UNNotificationRequest(
            identifier: "storm_alert_\(Int(now.timeIntervalSince1970))",
            content: content, trigger: nil)  // nil trigger = deliver now
        try? await UNUserNotificationCenter.current().add(request)
        latch(cls: cls, now: now)
    }

    // MARK: - Test

    /// Fire a sample alert (used by the Settings "Send a test alert" button) so
    /// testers can confirm permission + see what an alert looks like. Delayed a few
    /// seconds so the phone can be locked to see it land on the lock screen.
    static func sendTestAlert() {
        let c = UNMutableNotificationContent()
        c.title = "⚠️ Pressure dropping fast"
        c.body = "Down 3.2 hPa in 3h at your station. Storm may be approaching. (Test alert)"
        c.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        let req = UNNotificationRequest(identifier: "storm_alert_test", content: c, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Throttle latch

    private static func shouldAlert(for cls: TendencyClass, now: Date) -> Bool {
        let d = AppConfig.sharedDefaults
        let lastClass = d.string(forKey: lastClassKey)
        let lastDate = d.object(forKey: lastDateKey) as? Date
        // Same ongoing class still within the cooldown → stay quiet.
        if lastClass == cls.rawValue, let lastDate, now.timeIntervalSince(lastDate) < cooldown {
            return false
        }
        return true
    }

    private static func latch(cls: TendencyClass, now: Date) {
        let d = AppConfig.sharedDefaults
        d.set(cls.rawValue, forKey: lastClassKey)
        d.set(now, forKey: lastDateKey)
    }

    // MARK: - Content

    private static func makeContent(cls: TendencyClass, tendency: TendencyOut,
                                    combined: CombinedResponse) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        let place = combined.pressure.name ?? combined.pressure.station
        let mag = String(format: "%.1f", abs(tendency.delta3h))
        switch cls {
        case .fallingFast:
            c.title = "⚠️ Pressure dropping fast"
            c.body = "Down \(mag) hPa in 3h at \(place). \(combined.verdict)"
        case .risingFast:
            c.title = "Pressure rising sharply"
            c.body = "Up \(mag) hPa in 3h at \(place). \(combined.verdict)"
        default:
            c.title = "Pressure change"
            c.body = combined.verdict
        }
        c.sound = .default
        return c
    }
}

// MARK: - Foreground presentation

/// Lets storm alerts surface as a banner even while Barry is open — useful for the
/// test button and any alert that lands mid-session.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
