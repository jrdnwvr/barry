//  TemperatureUnitTests.swift
//  BarryTests

import Foundation
import Testing
@testable import Barry

struct TemperatureUnitTests {
    @Test func conversionsAndWords() {
        #expect(TemperatureUnit.celsius.format(16.4) == "16°" && TemperatureUnit.celsius.format(-3.6) == "−4°")
        #expect(TemperatureUnit.fahrenheit.format(0) == "32°" && TemperatureUnit.fahrenheit.format(100) == "212°")
        #expect(TemperatureUnit.fahrenheit.format(-40) == "−40°")
        #expect(TemperatureUnit.fahrenheit.formatWithUnit(20) == "68°F" && TemperatureUnit.celsius.formatWithUnit(20) == "20°C")
        #expect(TemperatureUnit.fahrenheit.formatDelta(5) == "9°" && TemperatureUnit.celsius.formatDelta(5) == "5°")
        #expect(TemperatureUnit.fahrenheit.freezing == 32 && TemperatureUnit.celsius.freezing == 0)
        #expect(TemperatureUnit.allCases.map(\.label) == ["°C", "°F"])
    }
}

struct PressureUnitTests {
    @Test func deltasFollowTheUnit() {
        // −1.6 hPa is −0.05 inHg; the bare form carries no unit, the full form does.
        #expect(PressureUnit.hPa.formatDeltaBare(-1.6) == "−1.6")
        #expect(PressureUnit.inHg.formatDeltaBare(-1.6) == "−0.05")
        #expect(PressureUnit.inHg.formatDeltaBare(0) == "0.00")
        #expect(PressureUnit.hPa.formatDeltaBare(2.4) == "+2.4")
        #expect(PressureUnit.inHg.formatDelta(-1.6) == "−0.05 inHg")
    }

    @Test func compassWords() {
        #expect(Cardinal.word("W") == "west" && Cardinal.word("nw") == "northwest")
        #expect(Cardinal.word("SSW") == "south-southwest")
        #expect(Cardinal.word("ALQDS") == "alqds")
    }

    @Test func aReportWithCloudHasClouds() {
        var obs = CurrentObs(slp: nil, presTend: nil)
        #expect(!obs.hasClouds)
        obs.ceilingFt = 4500
        #expect(obs.hasClouds)
        obs.ceilingFt = nil
        obs.clouds = [CloudLayer(cover: "FEW", baseFt: 2500)]
        #expect(obs.hasClouds)
        obs.clouds = []
        #expect(!obs.hasClouds)
    }
}

struct CloudBaseTests {
    @Test func fourHundredFeetPerDegreeOfSpread() {
        #expect(CloudBase.aglFt(tempC: 20, dewC: 8) == 4800)
        #expect(CloudBase.aglFt(tempC: 15.3, dewC: 12.1) == 1300)
    }

    @Test func noBaseForFogOrADesert() {
        #expect(CloudBase.aglFt(tempC: 10, dewC: 9.5) == nil)
        #expect(CloudBase.aglFt(tempC: 40, dewC: -5) == nil)
        #expect(CloudBase.aglFt(tempC: nil, dewC: 5) == nil)
    }
}
