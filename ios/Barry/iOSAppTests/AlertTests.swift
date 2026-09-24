//  AlertTests.swift
//  BarryTests
//
//  What each kind of alert fires on, from a real payload with the relevant
//  bits set, and the words it uses.

import Foundation
import Testing
@testable import Barry

struct AlertTests {
    /// The KLUK payload with the tendency rewritten in its JSON (the model
    /// keeps that field immutable) and the storm parts set directly.
    private func combined(delta3h: Double? = nil, lightning: LightningNearby? = nil, storm: StormOut? = nil) throws -> CombinedResponse {
        var data = try Fixtures.data("combined_kluk")
        if let d = delta3h {
            var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            var pressure = try #require(obj["pressure"] as? [String: Any])
            pressure["tendency"] = ["delta3h": d, "class": TendencyClass.classify(delta3h: d).rawValue, "intensity": 0.5]
            obj["pressure"] = pressure
            data = try JSONSerialization.data(withJSONObject: obj)
        }
        var c = try BarryAPI.decoder.decode(CombinedResponse.self, from: data)
        c.lightningNearby = lightning
        if let storm { c.conditions?.storm = storm }
        return c
    }

    @Test func pressureAlertsOnlyOnTheFastClasses() throws {
        #expect(StormAlerter.pressureAlert(try combined(delta3h: -1.0)) == nil)
        let fall = try #require(StormAlerter.pressureAlert(try combined(delta3h: -3.4)))
        #expect(fall.title == "Pressure dropping fast" && fall.body.hasPrefix("Down ") && fall.latch == "pressure.falling_fast")
        let rise = try #require(StormAlerter.pressureAlert(try combined(delta3h: 2.0)))
        #expect(rise.title == "Pressure rising sharply" && rise.body.hasPrefix("Up "))
    }

    @Test func theLevelDecidesHowBigAChangeAlerts() throws {
        let gentle = try combined(delta3h: -1.2)
        #expect(StormAlerter.pressureAlert(gentle, level: .fast) == nil)
        #expect(StormAlerter.pressureAlert(gentle, level: .moderate) == nil)
        let small = try #require(StormAlerter.pressureAlert(gentle, level: .small))
        #expect(small.title == "Pressure falling" && small.latch == "pressure.falling_fast")
        let moderate = try #require(StormAlerter.pressureAlert(try combined(delta3h: -2.0), level: .moderate))
        #expect(moderate.title == "Pressure falling")
        let sharp = try #require(StormAlerter.pressureAlert(try combined(delta3h: -3.4), level: .small))
        #expect(sharp.title == "Pressure dropping fast")
        let rise = try #require(StormAlerter.pressureAlert(try combined(delta3h: 1.1), level: .small))
        #expect(rise.title == "Pressure rising")
        #expect(StormAlerter.pressureAlert(try combined(delta3h: 1.1), level: .moderate) == nil)
    }

    @Test func quietHoursWrapMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        func at(_ h: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: h))! }
        let q = StormAlerter.Quiet.h22to7
        #expect(q.contains(at(23), calendar: cal) && q.contains(at(3), calendar: cal))
        #expect(!q.contains(at(7), calendar: cal) && !q.contains(at(21), calendar: cal))
        #expect(!StormAlerter.Quiet.off.contains(at(2), calendar: cal))
    }

    @Test func lightningAlertsWhenCloseOrComing() throws {
        let now = Date()
        func bolt(_ mi: Int, toward: Bool?, age: TimeInterval = 60) -> LightningNearby {
            LightningNearby(station: "GLM", name: nil, distanceMi: mi, bearingDeg: 270, cardinal: "W", status: "strikes",
                            at: now.addingTimeInterval(-age), moving: "E", towardYou: toward, continuesUntil: nil,
                            source: "glm", flashes: 40, speedKmh: 30, etaAt: now.addingTimeInterval(40 * 60))
        }
        #expect(StormAlerter.stormAlert(try combined(lightning: bolt(40, toward: true)), now: now) == nil)     // too far
        #expect(StormAlerter.stormAlert(try combined(lightning: bolt(20, toward: false)), now: now) == nil)    // near, but going away
        #expect(StormAlerter.stormAlert(try combined(lightning: bolt(20, toward: true, age: 3600)), now: now) == nil)  // old news
        let coming = try #require(StormAlerter.stormAlert(try combined(lightning: bolt(20, toward: true)), now: now))
        #expect(coming.title == "Lightning nearby" && coming.body.hasPrefix("20 mi to the west") && coming.body.contains("moving this way"))
        let close = try #require(StormAlerter.stormAlert(try combined(lightning: bolt(6, toward: nil)), now: now))
        #expect(close.body.hasPrefix("6 mi") && !close.body.contains("moving"))
        let here = try #require(StormAlerter.stormAlert(try combined(lightning: bolt(1, toward: nil)), now: now))
        #expect(here.body.hasPrefix("At "))
    }

    @Test func observedStormsFillTheEtaSlot() throws {
        let now = Date()
        let s = StormOut(risk: "observed", start: nil, end: nil, detail: "Moving east, toward you. Here around {eta}.",
                         distanceMi: 8, cardinal: "west", moving: "E", towardYou: true,
                         etaAt: now.addingTimeInterval(30 * 60))
        let a = try #require(StormAlerter.stormAlert(try combined(storm: s), now: now))
        #expect(a.title.hasPrefix("Thunderstorms at") && a.body.hasPrefix("Moving east"))
        #expect(!a.body.contains("{eta}") && a.body.contains("Here around "))
    }

    @Test func forecastStormsAlertWhenLikelyAndSoon() throws {
        let now = Date()
        func storm(_ risk: String, startIn: TimeInterval?) -> StormOut {
            StormOut(risk: risk, start: startIn.map { now.addingTimeInterval($0) },
                     end: startIn.map { now.addingTimeInterval($0 + 3 * 3600) }, detail: "Storms around.")
        }
        #expect(StormAlerter.stormAlert(try combined(storm: storm("possible", startIn: 3600)), now: now) == nil)
        #expect(StormAlerter.stormAlert(try combined(storm: storm("likely", startIn: 5 * 3600)), now: now) == nil)   // not yet
        let soon = try #require(StormAlerter.stormAlert(try combined(storm: storm("likely", startIn: 3600)), now: now))
        #expect(soon.title == "Thunderstorms likely" && soon.body.hasPrefix("At ") && soon.body.contains(" from ") && soon.latch == "storm.forecast")
    }
}
