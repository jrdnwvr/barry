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

struct BuoyDecodeTests {
    @Test func aBuoyDecodesWithItsOwnFields() throws {
        let json = """
        {"stations":[{"id":"44013","lat":42.346,"lon":-70.651,"kind":"buoy","windKt":17.5,"windDir":30,
          "slp":1028.9,"presTend":-1.2,"waveFt":3.9,"wavePeriodS":6,"waterTempC":16.5,"fltCatDerived":false},
          {"id":"KBOS","lat":42.36,"lon":-71.0,"windKt":12,"fltCat":"VFR","fltCatDerived":false}],
         "cachedAt":"2026-09-24T21:10:00Z"}
        """
        let r = try BarryAPI.decoder.decode(StationsResponse.self, from: Data(json.utf8))
        #expect(r.stations[0].isBuoy && r.stations[0].waveFt == 3.9 && r.stations[0].presTend == -1.2)
        #expect(!r.stations[1].isBuoy && r.stations[1].kind == nil)
    }
}

struct FieldsCardTests {
    @Test func theLineTakesTheVerdictsFirstSentence() {
        #expect(FieldsCard.firstSentence("Pressure bottoming out. Front passing now.") == "Pressure bottoming out")
        #expect(FieldsCard.firstSentence("Holding steady.") == "Holding steady")
    }

    @Test func aGlanceDecodes() throws {
        let json = """
        {"items":[{"station":"KLUK","fltCat":"MVFR","windKt":9,"windDir":50,"altim":1024.7,
          "delta3h":-1.1,"class":"falling","verdict":"Pressure falling. Rain likely around 5 PM."}],
         "cachedAt":"2026-09-24T21:10:00Z"}
        """
        let r = try BarryAPI.decoder.decode(GlanceResponse.self, from: Data(json.utf8))
        #expect(r.items.first?.cls == .falling && r.items.first?.fltCat == "MVFR")
    }
}

struct LayoutUpgradeTests {
    @Test func aNewCardLandsWhereTheDefaultOrderHasIt() {
        // A layout saved before the Fields card existed, in a custom order.
        let saved = HomeLayout(order: [.lightning, .radar, .chart, .taf, .rainWind, .conditions,
                                       .strip, .wind, .sensor, .sources],
                               hidden: [.taf])
        let up = saved.normalized()
        let i = up.order.firstIndex(of: .fields), c = up.order.firstIndex(of: .chart)
        #expect(i != nil && c != nil && i! == c! + 1)
        #expect(up.order.count == HomeCard.allCases.count && up.isVisible(.fields))
        #expect(up.order.first == .lightning && up.order[1] == .radar)
    }
}

struct AdvisoryTests {
    @Test func heightsReadTheWayPilotsSayThem() {
        let a = AdvisoryArea(kind: "airmet", hazard: "TURB-LO", label: "AIRMET Turb", baseFt: 5000, topFt: 22000)
        #expect(AdvisoryInk.heights(a) == "5,000 ft to FL220")
        let c = AdvisoryArea(kind: "convective", hazard: "CONVECTIVE", label: "Convective SIGMET 38W", topFt: 43000)
        #expect(AdvisoryInk.heights(c) == "Up to FL430" && AdvisoryInk.short(c) == "Conv")
        let s = AdvisoryArea(kind: "airmet", hazard: "IFR", label: "AIRMET IFR")
        #expect(AdvisoryInk.heights(s) == "" && AdvisoryInk.short(s) == "IFR")
    }

    @Test func intensityColours() {
        #expect(AdvisoryInk.intensity("MOD") == .systemOrange)
        #expect(AdvisoryInk.intensity("LGT-MOD") == .systemOrange)
        #expect(AdvisoryInk.intensity("SEV") == .systemRed)
        #expect(AdvisoryInk.intensity("NEG") == .systemGray)
        #expect(AdvisoryInk.words("LGT-MOD") == "light to moderate" && AdvisoryInk.words("SEV") == "severe")
    }
}
