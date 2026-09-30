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

/// Dates from the server, with and without fractional seconds, on every iOS
/// version the app runs on. Uses the same legacy formatter iOS 17 uses, so
/// the check holds on the newer simulators too.
struct ServerDateTests {
    @Test func wholeAndFractionalSecondsBothParse() throws {
        let whole = try #require(BarryAPI.parseDate("2026-09-27T00:57:07Z"))
        let frac = try #require(BarryAPI.parseDate("2026-09-27T00:57:07.402195Z"))
        #expect(whole == frac)
        let offset = try #require(BarryAPI.parseDate("2026-09-26T20:57:07.5-04:00"))
        #expect(offset == whole)
        #expect(BarryAPI.parseDate("not a date") == nil)
        #expect(BarryAPI.parseDate("2026-09-27") == nil)
    }

    @Test func aResponseWithMicrosecondsDecodes() throws {
        let json = #"{"hourly":[],"sun":{"sunrise":["2026-09-26T11:29:10.071551Z"],"sunset":["2026-09-26T23:29:30Z"]},"source":"hrrr+nbm","cachedAt":"2026-09-27T01:06:54.159412Z"}"#
        let r = try BarryAPI.decoder.decode(ForecastResponse.self, from: Data(json.utf8))
        #expect(r.sun?.sunrise.count == 1 && r.source == "hrrr+nbm")
    }
}

/// The phone's clock in words: "4 PM" on a 12-hour clock, "16:00" on a
/// 24-hour one, the way the system formats every other time.
struct ClockTextTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let t = Date(timeIntervalSince1970: 1_790_352_000)       // 2026-09-26 16:00Z

    @Test func hoursReadInTheClockThePhoneUses() {
        // The system writes a narrow no-break space before PM, as in every other time on the phone.
        let twelve = ClockText.hour(t, h24: false, locale: Locale(identifier: "en_US"), timeZone: utc)
        #expect(twelve.replacingOccurrences(of: "\u{202F}", with: " ") == "4 PM")
        #expect(ClockText.hour(t, h24: true, locale: Locale(identifier: "da_DK"), timeZone: utc) == "16.00")
        #expect(ClockText.hour(t, h24: true, locale: Locale(identifier: "en_US"), timeZone: utc) == "16:00")
        let nine = t.addingTimeInterval(-7 * 3600)
        #expect(ClockText.hour(nine, h24: true, locale: Locale(identifier: "en_US"), timeZone: utc) == "09:00")
    }

    @Test func theRegionDecidesTheClockWhenNothingIsOverridden() {
        #expect(!ClockText.uses24Hour(locale: Locale(identifier: "en_US")))
        #expect(ClockText.uses24Hour(locale: Locale(identifier: "en_GB")))
        #expect(ClockText.uses24Hour(locale: Locale(identifier: "de_DE")))
    }
}

/// The watch face shows a new report soon after it lands: its next refresh
/// is at :08, when the hour's METAR has reached the server, or twenty
/// minutes on, whichever comes first.
struct ComplicationRefreshTests {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func at(_ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: h, minute: m))! }

    @Test func refreshesJustAfterTheNewReportLands() {
        #expect(TendencyProvider.nextRefresh(after: at(10, 50), calendar: cal) == at(11, 8))
        #expect(TendencyProvider.nextRefresh(after: at(11, 0), calendar: cal) == at(11, 8))
        #expect(TendencyProvider.nextRefresh(after: at(11, 7), calendar: cal) == at(11, 27))   // :08 too close; the regular twenty
        #expect(TendencyProvider.nextRefresh(after: at(11, 20), calendar: cal) == at(11, 40))
    }

    @Test func thePhoneWidgetsKeepTheAirportRule() throws {
        let c = try Fixtures.combinedKLUK()
        let away = TendencySnapshot(from: c, atAirport: false)
        let here = TendencySnapshot(from: c, atAirport: true)
        #expect(!away.showsAltimeter && away.displayPressureHPa == c.currentPressure)
        #expect(here.showsAltimeter && here.displayPressureHPa == c.pressure.current.altim)
    }
}
