//  LayerTimelineTests.swift
//  BarryTests
//
//  The wind, the stations and the lightning on the radar's clock: which
//  hour's grids a moment sits between and how they blend, which report a
//  station shows for a moment, which ten-minute frame the lightning
//  shows, and where each says it cannot reach.

import Foundation
import Testing
@testable import Barry

struct LayerTimelineTests {
    func point(_ lat: Double, _ lon: Double, _ kmh: Double, _ deg: Double) -> FieldPoint {
        FieldPoint(lat: lat, lon: lon, windKmh: kmh, windDeg: deg, blM: nil, capeJkg: nil)
    }

    @Test func theWindOfAMomentIsTheHoursEitherSideSlidTogether() throws {
        let h = 3600
        let resp = FieldSeriesResponse(frames: [
            FieldFrame(time: 0, points: [point(39, -84, 20, 270), point(39, -85, 10, 180)]),
            FieldFrame(time: h, points: [point(39, -84, 20, 180), point(39, -85, 10, 180)]),
            FieldFrame(time: 5 * h, points: [point(39, -84, 40, 90), point(39, -85, 10, 180)],
                       levels: [FieldLevelPoint(lat: 39, lon: -84, levels: [LevelWind(hPa: 850, windKmh: 60, windDeg: 250)])]),
        ], source: "hrrr", cachedAt: Date())
        let line = try #require(WindTimeline(resp, nowTime: 5 * h))
        // Half way from west to south: southwest, through the vector, not calm.
        let mid = try #require(line.fields(at: 1800, level: 0))
        #expect(mid.f == 0.5 && mid.a.count == 2 && mid.b.count == 2)
        let blended = try #require(line.field(at: 1800, level: 0))
        #expect(blended[0].fromDeg == 225 && abs(blended[0].speedKmh - 14.1) < 0.2)
        #expect(blended[1].fromDeg == 180 && blended[1].speedKmh == 10, "a steady point stays put")
        // On a frame: that frame alone.
        let on = try #require(line.fields(at: Double(h), level: 0))
        #expect(on.f == 0 && on.a[0].fromDeg == 180)
        // An hour past the second frame, with the next four hours off: the
        // second alone. Two hours from either: out of reach, the layer stays at now.
        let lone = try #require(line.fields(at: Double(2 * h), level: 0))
        #expect(lone.f == 0 && lone.a[0].fromDeg == 180 && lone.b[0].fromDeg == 180)
        #expect(line.fields(at: Double(3 * h), level: 0) == nil)
        #expect(!line.covers(Double(3 * h), level: 0) && line.covers(1800, level: 0))
        // A level only the newest frame has reaches only around it.
        #expect(line.fields(at: Double(5 * h), level: 850)?.a.first?.speedKmh == 60)
        #expect(line.fields(at: 1800, level: 850) == nil)
        #expect(WindTimeline(FieldSeriesResponse(frames: [], cachedAt: Date()), nowTime: 0) == nil)
    }

    @Test func aStationShowsItsLatestReportAtOrBeforeTheMoment() throws {
        let h = 3600
        let resp = StationSeriesResponse(stations: [
            StationSeries(id: "KLUK", lat: 39.1, lon: -84.4, reports: [
                StationReport(t: 53 * 60, windKt: 8, windDir: 270, gustKt: nil, fltCat: "VFR"),
                StationReport(t: h + 53 * 60, windKt: 12, windDir: 250, gustKt: 20, fltCat: "MVFR"),
            ]),
            StationSeries(id: "KCVG", lat: 39.05, lon: -84.67, reports: [
                StationReport(t: h + 53 * 60, windKt: 3, windDir: 90, gustKt: nil, fltCat: "VFR"),
                StationReport(t: 5 * h, windKt: 5, windDir: 180, gustKt: nil, fltCat: "IFR"),
            ]),
        ], cachedAt: Date())
        let line = try #require(StationTimeline(resp, nowTime: 6 * h))
        // At 1:30: the :53 report of the first hour stands; the second has not come.
        let early = try #require(line.observations(at: Double(h) + 1800))
        #expect(early.map(\.id) == ["KLUK"] && early[0].windKt == 8 && early[0].fltCat == "VFR")
        // At 1:50, three minutes before the report's own time: it is taken (the report stands for its hour).
        #expect(line.observations(at: Double(h) + 50 * 60)?.first?.windKt == 12)
        // At 2:30 the newer one, with its gust; both stations have one.
        let later = try #require(line.observations(at: Double(2 * h) + 1800))
        #expect(later[0].windKt == 12 && later[0].gustKt == 20 && later[0].fltCat == "MVFR")
        #expect(later.count == 2 && line.covers(Double(2 * h) + 1800))
        // Four hours on: KLUK's last report is too old, KCVG's is current:
        // one of two is not coverage, the layer stays at now.
        let late = try #require(line.observations(at: Double(5 * h) + 600))
        #expect(late.map(\.id) == ["KCVG"] && !line.covers(Double(5 * h) + 600))
        // Before any report: nothing.
        #expect(line.observations(at: 600) == nil && !line.covers(600))
        // At 1:30 only KLUK has reported: not coverage either.
        #expect(!line.covers(Double(h) + 1800))
    }

    @Test func theLightningOfAMomentIsTheLastTenMinuteFrame() throws {
        let cell = LightningCell(lat: 39.2, lon: -84.5, count: 3, ageSec: 120)
        let resp = LightningSeriesResponse(frames: [
            LightningFrame(time: 1200, cells: [cell]),
            LightningFrame(time: 600, cells: []),
            LightningFrame(time: 1800, cells: [cell, cell]),
        ], windowSec: 1200, binDeg: 0.02, cachedAt: Date())
        let line = try #require(LightningTimeline(resp, nowTime: 1800))
        #expect(line.frames.map(\.time) == [600, 1200, 1800])
        #expect(line.frame(at: 1500)?.time == 1200 && line.frame(at: 1800)?.time == 1800)
        let state = try #require(line.state(at: 1500))
        #expect(state.response?.cells.count == 1 && state.response?.coverage == true && state.version == 1200)
        #expect(state.receivedAt == .distantPast, "no arrival pulse for old strikes")
        // Before the first frame, or long after the last: nothing.
        #expect(line.frame(at: 300) == nil && line.frame(at: 1800 + 1300) == nil)
        #expect(!line.covers(300) && line.covers(2000))
    }
}
