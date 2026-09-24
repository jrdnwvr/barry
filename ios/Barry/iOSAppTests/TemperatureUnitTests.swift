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

struct AudienceTests {
    @Test func everyLayoutHasEveryCardOnce() {
        for a in Audience.allCases {
            let l = a.layout.normalized()
            #expect(Set(l.order) == Set(HomeCard.allCases), "\(a)")
            #expect(l.order.count == HomeCard.allCases.count, "\(a)")
            #expect(l.isVisible(.chart) && l.isVisible(.sources), "\(a)")
        }
    }

    @Test func theBundlesSuitTheirPeople() {
        #expect(Audience.pilot.runwayWinds == .auto && Audience.pilot.windUnit == .knots)
        #expect(Audience.drone.runwayWinds == .compass && Audience.drone.radarLayers.wind)
        #expect(!Audience.everyday.layout.isVisible(.taf) && !Audience.everyday.layout.isVisible(.wind))
        #expect(Audience.everyday.alertLevel == .moderate && Audience.pilot.alertLevel == .fast)
        #expect(Audience.marine.radarLayers.isobars && Audience.marine.windUnit == .knots)
        #expect(Audience.marine.radarLayers.buoys && Audience.marine.radarLayers.stations == "barbs")
        #expect(!Audience.pilot.radarLayers.buoys)
    }

    @Test func justTheRadarIsJustTheRadar() {
        let r = Audience.RadarLayers.justRadar
        #expect(r.radar && !r.lightning && !r.wind && !r.isobars && !r.fronts && r.stations == "off")
    }
}

struct DroneWindTests {
    private func hour(_ offsetH: Double, _ kmh: Double?, now: Date) -> ForecastHour {
        ForecastHour(t: now.addingTimeInterval(offsetH * 3600), pressure_msl: nil, windspeed: nil, winddir: nil,
                     precip_prob: nil, wind80m: kmh)
    }

    @Test func nowAndTheBuild() {
        let now = Date(timeIntervalSince1970: 1_790_035_800)
        let hours = [hour(0, 18.5, now: now), hour(1, 22, now: now), hour(3, 37, now: now), hour(8, 60, now: now)]
        let line = DroneWind.line(hours: hours, now: now)
        #expect(line?.hasPrefix("At 260 ft: 10 kt now, 20 kt by ") == true, "\(line ?? "nil")")
    }

    @Test func aSteadyWindIsOneNumber() {
        let now = Date(timeIntervalSince1970: 1_790_035_800)
        let hours = [hour(0, 18.5, now: now), hour(2, 20, now: now)]
        #expect(DroneWind.line(hours: hours, now: now) == "At 260 ft: 10 kt now.")
        #expect(DroneWind.line(hours: [hour(0, nil, now: now)], now: now) == nil)
    }
}
