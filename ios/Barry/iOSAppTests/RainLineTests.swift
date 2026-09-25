//  RainLineTests.swift
//  BarryTests
//
//  The rain row's words, and that the server's rain line decodes.

import Foundation
import Testing
@testable import Barry

struct RainLineTests {
    private let now = Date(timeIntervalSince1970: 1_790_341_200)      // 2026-09-25 13:00Z

    private func rain(_ status: String, start: TimeInterval? = nil, end: TimeInterval? = nil,
                      detail: String) -> RainOut {
        RainOut(status: status, startsAt: start.map { now.addingTimeInterval($0) },
                endsAt: end.map { now.addingTimeInterval($0) }, intensity: "light",
                distanceMi: 12, fromCardinal: "west", moving: "east", speedMph: 25, detail: detail, asOf: now)
    }

    @Test func rainOnTheWayNamesItsStartAndTheClearingTimeFillsTheDetail() {
        let r = rain("soon", start: 1800, end: 4200,
                     detail: "Light rain 12 mi to the west, moving east at 25 mph. Clearing by about {end}.")
        #expect(RainLine.title(r, now: now) == "Rain from about \(RainLine.time(r.startsAt!))")
        #expect(RainLine.detail(r) == "Light rain 12 mi to the west, moving east at 25 mph. Clearing by about \(RainLine.time(r.endsAt!)).")
        #expect(RainLine.title(rain("soon", start: 60, detail: ""), now: now) == "Rain any minute")
    }

    @Test func rainNowSaysSoOrWhenItClears() {
        let steady = rain("now", detail: "Moderate rain here, moving east at 20 mph.")
        #expect(RainLine.title(steady, now: now) == "Raining now")
        #expect(RainLine.detail(steady) == "Moderate rain here, moving east at 20 mph.")
        let clearing = rain("now", end: 1500, detail: "Light rain here, nearly stationary. Clearing by about {end}.")
        #expect(RainLine.title(clearing, now: now) == "Rain until about \(RainLine.time(clearing.endsAt!))")
    }

    @Test func theRainLineDecodesInCombinedAndEarnsTheCard() throws {
        let c = try BarryAPI.decoder.decode(CombinedResponse.self, from: Fixtures.data("combined_noaa"))
        let rain = try #require(c.conditions?.rain)
        #expect(rain.status == "soon" && rain.source == "mrms" && rain.fromCardinal == "west")
        #expect(ConditionsOut(rain: rain).hasContent)
    }
}
