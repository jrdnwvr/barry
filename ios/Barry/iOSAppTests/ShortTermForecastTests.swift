//  ShortTermForecastTests.swift
//  BarryTests
//
//  The changes the forecast cards name: on the front night, every one of
//  them in the right hour; on a quiet night, none.

import Foundation
import Testing
@testable import Barry

struct ShortTermForecastTests {
    private var front: ShortTermForecast {
        ShortTermForecast(forecast: Fixtures.frontForecast(), now: Fixtures.fixtureNow)
    }

    @Test func theWindowIsTwelveHoursFromNow() {
        #expect(front.hours.count == 13)
        #expect(front.hours[0].t == Date(timeIntervalSince1970: 1_790_035_200))
        #expect(ShortTermForecast(forecast: Fixtures.frontForecast(), now: Fixtures.fixtureNow, windowHours: 24).hours.count == 25)
    }

    @Test func theFrontNightFindsEveryChangeInItsHour() {
        let f = front.found
        #expect(f.rainStart == 4 && f.rainPeak == 6 && f.rainPeakEnd == 7 && f.rainEnd == 9)
        #expect(f.windUp == 7 && f.shift == 7 && f.front)
        #expect(f.low == 11 && f.high == nil)
        #expect(f.clearing == 10 && f.clouding == nil)
        #expect(f.thunder == nil)
    }

    @Test func theSentenceNamesThemInOrder() {
        let s = front.sentence(wind: .knots, temp: .fahrenheit)
        #expect(s.hasPrefix("Rain moves in around "))
        #expect(s.contains(", likeliest ") && s.contains(", easing by "))
        #expect(s.contains("Wind builds to 18 gusting 28 kts by "))
        #expect(s.contains("as a front comes through, swinging to the northwest."))
        #expect(s.contains("Clearing by ") && s.contains(" and down to 46° by "))
        let rain = s.range(of: "Rain")!.lowerBound, wind = s.range(of: "Wind")!.lowerBound, clear = s.range(of: "Clearing")!.lowerBound
        #expect(rain < wind && wind < clear)
    }

    @Test func theChangesListIsInTimeOrder() {
        let kinds = front.events(wind: .knots, temp: .fahrenheit).map(\.kind)
        #expect(kinds == [.rainStart, .front, .rainEnd, .clearing, .low])
        let frontLine = front.events(wind: .knots, temp: .fahrenheit).first { $0.kind == .front }!.text
        #expect(frontLine == "Front passes. Wind swings to the northwest, 18 gusting 28 kts, and the temperature drops.")
        let first = front.events(wind: .knots, temp: .fahrenheit)[0]
        #expect(first.text.hasPrefix("Rain moves in, 35%, rising to 70% by "))
        #expect(front.nowText(current: nil, wind: .knots, temp: .fahrenheit) == "63°, 7 kts from the southwest, dry.")
        #expect(front.readout(7, wind: .knots, temp: .fahrenheit) == "60% · 18 G28 kts · 53° · overcast")
    }

    @Test func aQuietNightSaysSoAndListsNothing() {
        let start = Date(timeIntervalSince1970: 1_790_035_200)
        let hours = (0..<13).map { i in
            ForecastHour(t: start.addingTimeInterval(Double(i) * 3600), pressure_msl: 1018, windspeed: 9, winddir: 180,
                         windgust: 12, precip_prob: 2, temperature: 15 - Double(i) * 0.1, cloudcover: 20)
        }
        let m = ShortTermForecast(forecast: hours, now: start)
        #expect(m.events(wind: .knots, temp: .celsius).isEmpty)
        let s = m.sentence(wind: .knots, temp: .celsius)
        #expect(s.hasPrefix("Steady through ") && s.contains(": dry, around 15°, wind near 5 kts."))
    }

    @Test func wordsForDirectionAndSky() {
        #expect(ShortTermForecast.cardinal(0) == "north" && ShortTermForecast.cardinal(300) == "northwest")
        #expect(ShortTermForecast.cardinal(290) == "west" && ShortTermForecast.cardinal(215) == "southwest")
        #expect(ShortTermForecast.cardinal(359) == "north" && ShortTermForecast.cardinal(-45) == "northwest")
        #expect(ShortTermForecast.angle(350, 20) == 30 && ShortTermForecast.angle(90, 270) == 180)
        #expect(ShortTermForecast.sky(10) == "clear" && ShortTermForecast.sky(100) == "overcast" && ShortTermForecast.sky(nil) == nil)
    }
}
