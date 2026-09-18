//  LiveActivityManager.swift
//  Barry — iOS
//
//  Starts, updates and ends the pressure Live Activity. Only an event earns
//  one: pressure falling or rising fast, a front passing, lightning close,
//  or the user asking to follow the next hours. iOS lets an app start an
//  activity only while it is in front (or from a server push, which Barry
//  does not send yet), so an event that begins while the app is closed
//  starts its activity the next time the app opens. Updates and endings
//  run from the background refresh as well.

import ActivityKit
import Foundation

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    static let enabledKey = "liveActivityEnabled"
    private static let followUntilKey = "liveActivity.followUntil"

    /// Lightning closer than this starts an activity.
    static let lightningMiles = 30
    static let followHours: Double = 6

    private init() {}

    /// Off until the user turns it on, in onboarding or Settings.
    var isEnabled: Bool {
        AppConfig.sharedDefaults.bool(forKey: Self.enabledKey)
    }

    var isFollowing: Bool {
        guard let until = AppConfig.sharedDefaults.object(forKey: Self.followUntilKey) as? Date else { return false }
        return until > Date()
    }

    private var current: Activity<PressureActivityAttributes>? {
        Activity<PressureActivityAttributes>.activities.first
    }

    // MARK: Events

    private struct Event { let kind: String; let label: String }

    private func detect(_ c: CombinedResponse) -> Event? {
        if let n = c.lightningNearby, n.distanceMi <= Self.lightningMiles {
            return Event(kind: "lightning", label: "Lightning \(n.distanceMi) mi \(cardinalWord(n.cardinal))")
        }
        let feature = c.reading?.feature
        let cls = c.tendency?.cls
        if feature == "rapid_fall" || cls == .fallingFast { return Event(kind: "fall", label: "Falling fast") }
        if feature == "rapid_rise" || cls == .risingFast { return Event(kind: "rise", label: "Rising fast") }
        if feature == "trough_passing" || feature == "front_knee" { return Event(kind: "front", label: "Front passing") }
        if isFollowing { return Event(kind: "follow", label: "Following") }
        return nil
    }

    private func cardinalWord(_ c: String) -> String {
        ["N": "north", "NE": "northeast", "E": "east", "SE": "southeast",
         "S": "south", "SW": "southwest", "W": "west", "NW": "northwest"][c] ?? c
    }

    private func state(_ c: CombinedResponse, atAirport: Bool, label: String) -> PressureActivityAttributes.ContentState {
        let head = c.headlinePressure(atAirport: atAirport)
        let t = c.tendency
        let snap = TendencySnapshot(from: c, atAirport: atAirport)
        return .init(pressureHPa: head?.hPa, isAltimeter: head?.isAltimeter ?? false,
                     delta3h: t?.delta3h ?? 0, cls: t?.cls ?? .steady, intensity: t?.intensity ?? 0,
                     trendSymbol: snap.trendSymbolName, verdict: c.verdict, eventLabel: label,
                     updatedAt: Date())
    }

    // MARK: Sync

    /// Bring the activity in line with the data: start one for a new event
    /// (foreground only), update a running one, end one whose event is over.
    func sync(_ c: CombinedResponse, atAirport: Bool, foreground: Bool) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("Barry live activity: activities disabled for this app")
            return
        }
        let running = current
        guard isEnabled else {
            if let running { await end(running, with: running.content.state) }
            return
        }
        guard let event = detect(c) else {
            if let running { await end(running, with: state(c, atAirport: atAirport, label: running.content.state.eventLabel)) }
            return
        }
        let s = state(c, atAirport: atAirport, label: event.label)
        let content = ActivityContent(state: s, staleDate: Date().addingTimeInterval(2 * 3600))
        if let running {
            if running.attributes.kind == event.kind || !foreground {
                await running.update(content)
                return
            }
            await end(running, with: running.content.state)
        }
        guard foreground else { return }
        let attrs = PressureActivityAttributes(station: c.pressure.station, stationName: c.pressure.name,
                                               kind: event.kind, startedAt: Date())
        do {
            _ = try Activity.request(attributes: attrs, content: content, pushType: nil)
        } catch {
            NSLog("Barry live activity: request failed: %@", String(describing: error))
        }
    }

    private func end(_ a: Activity<PressureActivityAttributes>, with s: PressureActivityAttributes.ContentState) async {
        await a.end(ActivityContent(state: s, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(15 * 60)))
    }

    // MARK: Follow

    /// Pin the trend to the lock screen for the next hours, or stop.
    func toggleFollow(_ c: CombinedResponse, atAirport: Bool) async {
        if isFollowing {
            AppConfig.sharedDefaults.removeObject(forKey: Self.followUntilKey)
        } else {
            AppConfig.sharedDefaults.set(Date().addingTimeInterval(Self.followHours * 3600), forKey: Self.followUntilKey)
        }
        await sync(c, atAirport: atAirport, foreground: true)
    }
}
