//  RadarTimelineTests.swift
//  BarryTests
//
//  The radar's clock: the two spans' loops, the line under the slider, and
//  which isobars and fronts go with the moment the slider is on.

import Foundation
import Testing
@testable import Barry

struct RadarTimelineTests {
    private let t0 = 1_790_960_400            // 2026-10-02 17:00 UTC, on the hour

    private func observed(_ t: Int) -> RadarFrame {
        RadarFrame(time: t, path: "/radar/tiles/\(t)", kind: .observed)
    }

    private func hourFrames() -> [RadarFrame] {
        (-12...0).map { observed(t0 + $0 * 600) }
            + (1...3).map { RadarFrame(time: t0 + $0 * 600, path: "/radar/tiles/\(t0 + $0)", kind: .nowcast) }
    }

    private func dayFrames() -> [RadarFrame] {
        (-6...0).map { observed(t0 + $0 * 3600) }
            + [RadarFrame(time: t0 + 3600, path: "/radar/tiles/\(t0 + 6)", kind: .nowcast)]
            + (2...12).map { RadarFrame(time: t0 + $0 * 3600, path: "/radar/model/\(t0 + $0 * 3600 + $0)", kind: .model) }
    }

    private func chart(_ hours: Int, valid: Int, lat: Double) -> FrontFrame {
        FrontFrame(hours: hours, valid: Date(timeIntervalSince1970: Double(valid)),
                   fronts: [FrontLine(type: "cold", points: [[lat, -90], [lat - 2, -88]])])
    }

    @Test func theHourLoopIsTheLastHourOfATwoHourSpan() {
        let f = hourFrames()
        #expect(RadarTimeline.loopStart(frames: f, nowIndex: 12, span: .hour) == 6)
    }

    @Test func theLoopsClockRunsEvenlyRestsOnNowAndGoesRound() {
        let start = Double(t0 - 3600), end = Double(t0)
        func step(_ clock: Double, _ dwell: Double = 0, dt: Double = 0.55, span: RadarSpan = .hour) -> (Double, Double) {
            let r = RadarTimeline.advance(clock: clock, dwellLeft: dwell, by: dt, span: span, start: start, end: end)
            return (r.clock, r.dwellLeft)
        }
        // The hour: ten minutes of weather every 0.55 s, as the frames always stepped.
        #expect(abs(step(start).0 - (start + 600)) < 1e-6)
        // The six hours in eight seconds.
        let day = RadarTimeline.advance(clock: Double(t0 - 6 * 3600), dwellLeft: 0, by: 4, span: .day,
                                        start: Double(t0 - 6 * 3600), end: end)
        #expect(abs(day.clock - Double(t0 - 3 * 3600)) < 1e-6)
        // Reaching now: it stops there and rests, then goes back to the start.
        #expect(step(end - 100) == (end, RadarTimeline.dwell))
        #expect(step(end, 1.0).0 == end)
        #expect(abs(step(end, 1.0).1 - 0.45) < 1e-9)
        #expect(step(end, 0.3) == (start, 0))
        // A clock outside the loop (the slider was elsewhere) rejoins at the start.
        #expect(step(start - 5000) == (start, 0))
        #expect(step(end + 1800) == (start, 0))
    }

    @Test func theRadarShowsTheFrameNearestTheClock() {
        let f = hourFrames()
        func at(_ offset: Int) -> Int {
            RadarTimeline.frameIndex(nearest: Double(t0 + offset), frames: f, start: 6, nowIndex: 12)
        }
        #expect(at(-3600) == 6)
        #expect(at(-3600 + 290) == 6)
        #expect(at(-3600 + 310) == 7)
        #expect(at(0) == 12)
        // Never a frame outside the loop: not the older ones, not the forecast.
        #expect(at(-7200) == 6)
        #expect(at(1200) == 12)
        // The day span's frames are uneven near now (twenty minutes, then ten).
        let d = [-2400, -1200, -600, 0].map { observed(t0 + $0) }
        #expect(RadarTimeline.frameIndex(nearest: Double(t0 - 700), frames: d, start: 0, nowIndex: 3) == 2)
    }

    @Test func theDayLoopIsTheSixHoursBeforeNow() {
        let f = dayFrames()
        #expect(f.lastIndex { !$0.nowcast } == 6)
        #expect(RadarTimeline.loopStart(frames: f, nowIndex: 6, span: .day) == 0)
        #expect(RadarTimeline.loopStart(frames: [], nowIndex: 0, span: .day) == 0)
    }

    @Test func aFramesKeyNamesItsPicture() {
        // The hour span's nowcast and the day span's model can share a valid time.
        let cast = RadarFrame(time: t0 + 3600, path: "/radar/tiles/\(t0 + 6)", kind: .nowcast)
        let model = RadarFrame(time: t0 + 3600, path: "/radar/model/\(t0 + 3601)", kind: .model)
        #expect(observed(t0).key == t0)
        #expect(cast.key == t0 + 6)
        #expect(model.key == -(t0 + 3601))
        #expect(Set([observed(t0 + 3600).key, cast.key, model.key]).count == 3)
        // A server that only knows the nowcast flag, and RainViewer's unnumbered paths.
        let old = RadarFrame(RadarFrameOut(time: t0 + 600, path: "/v2/radar/nowcast_abc", nowcast: true))
        #expect(old.kind == .nowcast)
        #expect(old.key == t0 + 607)
        #expect(RadarFrame(RadarFrameOut(time: t0, path: "/radar/model/5", nowcast: true, kind: "model")).kind == .model)
    }

    @Test func theLineUnderTheSliderSaysWhatTheFrameIs() {
        let wall = Date(timeIntervalSince1970: Double(t0 + 240))
        func text(_ f: RadarFrame, parked: Bool = false) -> String {
            RadarTimeline.frameText(f, nowTime: t0, wallClock: wall, parked: parked) { _ in "X" }
        }
        #expect(text(observed(t0)) == "X · 4m ago")
        #expect(text(observed(t0), parked: true) == "X · latest, 4m ago")
        #expect(text(observed(t0 - 3000)) == "X · 54m ago")
        #expect(text(observed(t0 - 5 * 3600)) == "X · 5h ago")
        #expect(text(hourFrames()[14]) == "X · nowcast +20m")
        #expect(text(dayFrames()[7]) == "X · nowcast +60m")
        #expect(text(dayFrames()[9]) == "X · model +3h")
        let fresh = Date(timeIntervalSince1970: Double(t0 + 30))
        #expect(RadarTimeline.frameText(observed(t0), nowTime: t0, wallClock: fresh, parked: false) { _ in "X" } == "X · now")
    }

    /// A field rising a hectopascal a degree north from `base` at 38 N, on a
    /// lattice a quarter degree apart over 38 to 40 N and 86 to 84 W.
    private func plane(_ base: Double, hole: Bool = false) -> GridOut {
        let n = 9
        var rows: [[Double?]] = (0..<n).map { j in (0..<n).map { _ in base + Double(j) * 0.25 } }
        if hole { rows[4][4] = nil }
        return GridOut(lat0: 38, lon0: -86, dlat: 0.25, dlon: 0.25, ny: n, nx: n, values: rows)
    }

    @Test func aContourRunsWhereTheFieldCrossesTheLevel() {
        let g = plane(1011.5)                       // 1012 half a degree north of the south edge
        let values = g.values.flatMap { $0.map { $0 ?? .nan } }
        let lines = Contour.lines(values: values, nx: 9, ny: 9, lat0: 38, lon0: -86, dlat: 0.25, dlon: 0.25, level: 1012)
        #expect(lines.count == 1)
        #expect(lines[0].count == 9)                // one piece, joined end to end across the lattice
        #expect(lines[0].allSatisfy { abs($0[0] - 38.5) < 1e-9 })
        #expect(Set(lines[0].map { $0[1] }) == Set(stride(from: -86.0, through: -84.0, by: 0.25)))
        // A level the field never reaches, and a lattice too small to contour.
        #expect(Contour.lines(values: values, nx: 9, ny: 9, lat0: 38, lon0: -86, dlat: 0.25, dlon: 0.25, level: 1020).isEmpty)
        #expect(Contour.lines(values: [1, 2], nx: 2, ny: 1, lat0: 0, lon0: 0, dlat: 1, dlon: 1, level: 1.5).isEmpty)
        // A cell with no data has no line through the squares that touch it.
        var holed = values
        holed[2 * 9 + 4] = .nan
        let broken = Contour.lines(values: holed, nx: 9, ny: 9, lat0: 38, lon0: -86, dlat: 0.25, dlon: 0.25, level: 1012)
        #expect(broken.count == 2)
        #expect(broken.flatMap { $0 }.allSatisfy { $0[1] <= -85.25 || $0[1] >= -84.75 })
    }

    @Test func isobarsSlideBetweenTheHoursEitherSideOfAMoment() throws {
        // 1011.5 at the south edge at 16:00, a hectopascal higher by 17:00:
        // the 1012 line starts half a degree up and moves off the south edge.
        let series = PressureSeriesResponse(
            frames: [PressureFrame(time: t0 - 3600, kind: "observed", pressureGrid: plane(1011.5)),
                     PressureFrame(time: t0, kind: "now", pressureGrid: plane(1012.5))],
            stepHPa: 1, run: nil, cachedAt: Date())
        let line = try #require(PressureTimeline(series))
        func lat(of level: Double, at t: Int) -> Double? {
            line.isobars(line.values(at: Double(t))).first { $0.level == level }?.points.first?[0]
        }
        #expect(lat(of: 1012, at: t0 - 3600) == 38.5)
        #expect(abs((lat(of: 1012, at: t0 - 2700) ?? 0) - 38.25) < 1e-9)      // a quarter of the way: a quarter degree south
        #expect(lat(of: 1013, at: t0) == 38.5)
        // Before the first frame and after the last: the end frames, held.
        #expect(lat(of: 1012, at: t0 - 9000) == 38.5)
        #expect(lat(of: 1013, at: t0 + 9000) == 38.5)
        #expect(line.range == Double(t0 - 3600)...Double(t0))
        // Every whole hectopascal the field crosses, and the grid for the shading.
        #expect(Set(line.isobars(line.values(at: Double(t0))).map(\.level)) == [1013, 1014])
        #expect(line.grid(line.values(at: Double(t0))).values[0][0] == 1012.5)
    }

    @Test func theSixHourLoopShowsTheFieldsShapeNotItsRise() throws {
        // Two hectopascals up everywhere between 11:00 and now, and the
        // gradient unchanged: the isobars cross the whole lattice, the
        // shape has not moved at all.
        func series(_ then: GridOut) -> PressureTimeline? {
            PressureTimeline(PressureSeriesResponse(
                frames: [PressureFrame(time: t0 - 6 * 3600, kind: "observed", pressureGrid: then),
                         PressureFrame(time: t0, kind: "now", pressureGrid: plane(1012.5)),
                         PressureFrame(time: t0 + 3600, kind: "model", pressureGrid: plane(1013.5))],
                stepHPa: 1, run: nil, cachedAt: Date()))
        }
        let line = try #require(series(plane(1010.5)))
        func lats(_ values: [Double]) -> [Double: Double] {
            Dictionary(uniqueKeysWithValues: line.isobars(values).map { ($0.level, $0.points[0][0]) })
        }
        let now = lats(line.values(at: Double(t0)))
        #expect(lats(line.values(at: Double(t0 - 6 * 3600)))[1012] == 39.5)       // the true line, a degree and a half north
        #expect(lats(line.pattern(at: Double(t0 - 6 * 3600))) == now)             // the shape: where it is now
        #expect(lats(line.pattern(at: Double(t0 - 3 * 3600))) == now)             // and all the way between
        #expect(lats(line.pattern(at: Double(t0))) == now)
        // A trough that really moved still moves: the same rise, and the
        // field tilted the other way six hours ago.
        var tilted = plane(1010.5)
        tilted = GridOut(lat0: tilted.lat0, lon0: tilted.lon0, dlat: tilted.dlat, dlon: tilted.dlon, ny: 9, nx: 9,
                         values: (0..<9).map { j in (0..<9).map { _ in 1012.5 - Double(j) * 0.25 } })
        let moved = try #require(series(tilted))
        let then = moved.pattern(at: Double(t0 - 6 * 3600))
        #expect(then[0] > then[8 * 9])                                            // higher in the south then
        let today = moved.pattern(at: Double(t0))
        #expect(today[0] < today[8 * 9])                                          // higher in the north now
        #expect(abs(then.reduce(0, +) - today.reduce(0, +)) < 1e-6)               // the same mean throughout
    }

    @Test func aSeriesOffOneLatticeOrEmptyIsNoTimeline() {
        let other = GridOut(lat0: 38, lon0: -86, dlat: 0.25, dlon: 0.25, ny: 2, nx: 2, values: [[1, 2], [3, 4]])
        let mixed = PressureSeriesResponse(
            frames: [PressureFrame(time: t0 - 3600, kind: "observed", pressureGrid: plane(1012)),
                     PressureFrame(time: t0, kind: "now", pressureGrid: other)],
            stepHPa: 4, run: nil, cachedAt: Date())
        #expect(PressureTimeline(mixed) == nil)
        #expect(PressureTimeline(PressureSeriesResponse(frames: [], stepHPa: 4, run: nil, cachedAt: Date())) == nil)
        // A cell one frame lacks is lacking between the two.
        let holed = PressureSeriesResponse(
            frames: [PressureFrame(time: t0 - 3600, kind: "observed", pressureGrid: plane(1012, hole: true)),
                     PressureFrame(time: t0, kind: "now", pressureGrid: plane(1013))],
            stepHPa: 4, run: nil, cachedAt: Date())
        let line = PressureTimeline(holed)
        #expect(line?.values(at: Double(t0 - 1800))[4 * 9 + 4].isNaN == true)
        #expect(line?.values(at: Double(t0))[4 * 9 + 4] == 1014)
    }

    @Test func eachChartHasTheMapFromItsOwnTimeAndTheNewestStandsThroughNow() {
        let v = t0 - 7200                                               // the analysis, two hours old as it usually is
        let analysis = chart(0, valid: v, lat: 40)
        let history = [chart(-6, valid: v - 6 * 3600, lat: 43), chart(-3, valid: v - 3 * 3600, lat: 42)]
        let progs = [chart(12, valid: t0 + 8 * 3600, lat: 37), chart(24, valid: t0 + 20 * 3600, lat: 35)]
        func pick(_ t: Int) -> RadarTimeline.FrontPick {
            RadarTimeline.fronts(at: Double(t), nowTime: t0, analysis: analysis, history: history, progs: progs)
        }
        // From the analysis's own time through now, and a little past: the analysis.
        #expect(pick(v) == .frame(analysis))
        #expect(pick(t0) == .frame(analysis))
        #expect(pick(t0 + 3600) == .frame(analysis))
        // Before it: the chart that was current then, back to the oldest held.
        #expect(pick(v - 3600) == .frame(history[1]))
        #expect(pick(v - 3 * 3600) == .frame(history[1]))
        #expect(pick(v - 4 * 3600) == .frame(history[0]))
        #expect(pick(v - 12 * 3600) == .frame(history[0]))
        // One gives way to the next over the twenty minutes before the next takes over.
        #expect(pick(v - 600) == .fade(history[1], analysis, 0.5))
        #expect(pick(v - 1200) == .frame(history[1]))
        #expect(pick(v - 3 * 3600 - 300) == .fade(history[0], history[1], 0.75))
        // Ahead: the forecast chart takes over half way to its own time
        // (now to +8 h: at +4 h), and the next half way from there (+14 h).
        #expect(pick(t0 + 3 * 3600) == .frame(analysis))
        #expect(pick(t0 + 4 * 3600 - 600) == .fade(analysis, progs[0], 0.5))
        #expect(pick(t0 + 4 * 3600) == .frame(progs[0]))
        #expect(pick(t0 + 12 * 3600) == .frame(progs[0]))
        #expect(pick(t0 + 14 * 3600) == .frame(progs[1]))
        #expect(pick(t0 + 30 * 3600) == .frame(progs[1]))
        // The chart with the say, for the key.
        #expect(pick(v - 900).chart == history[1])
        #expect(pick(v - 300).chart == analysis)
        // No history, no forecast charts, no chart.
        #expect(RadarTimeline.fronts(at: Double(t0 - 9 * 3600), nowTime: t0, analysis: analysis, history: [], progs: []) == .frame(analysis))
        #expect(RadarTimeline.fronts(at: Double(t0 + 3 * 3600), nowTime: t0, analysis: analysis, history: [], progs: []) == .frame(analysis))
        #expect(RadarTimeline.fronts(at: Double(t0), nowTime: t0, analysis: nil, history: history, progs: progs) == .none)
        // A forecast chart already behind now is skipped.
        let stale = [chart(12, valid: t0 - 600, lat: 39), progs[1]]
        #expect(RadarTimeline.fronts(at: Double(t0 + 3600), nowTime: t0, analysis: analysis, history: [], progs: stale) == .frame(analysis))
        #expect(RadarTimeline.fronts(at: Double(t0 + 11 * 3600), nowTime: t0, analysis: analysis, history: [], progs: stale) == .frame(progs[1]))
    }

    @Test func oneChartGivesWayToTheNextWithoutMovingAFront() {
        let a = chart(0, valid: t0, lat: 40), b = chart(12, valid: t0 + 12 * 3600, lat: 38)
        let mid = FrontMorph.crossfade(a, b, t: 0.25)
        // Both charts' fronts, each exactly where its chart drew it.
        #expect(mid.fronts.count == 2)
        #expect(mid.fronts[0].coordinates.first?.latitude == 40)
        #expect(mid.fronts[1].coordinates.first?.latitude == 38)
        #expect(mid.fronts[0].alpha == 0.75)
        #expect(mid.fronts[1].alpha == 0.25)
        #expect(FrontMorph.crossfade(a, b, t: 3).fronts[0].alpha == 0)
    }

    @Test func theNoteNamesTheLayersThatStayedAtNow() {
        func note(wind: Bool = false, stations: Bool = false, lightning: Bool = false,
                  advisories: Bool = false, change: Bool = false) -> String? {
            RadarTimeline.nowOnlyNote(wind: wind, stations: stations, lightning: lightning,
                                      advisories: advisories, change: change)
        }
        #expect(note() == nil)
        #expect(note(wind: true) == "Wind shows now.")
        #expect(note(stations: true) == "Stations show now.")
        #expect(note(wind: true, lightning: true) == "Wind and lightning show now.")
        #expect(note(wind: true, stations: true, lightning: true) == "Wind, stations and lightning show now.")
        #expect(note(change: true) == "Pressure change shows now.")
        // More than three would not fit beside the frame's time.
        #expect(note(wind: true, stations: true, lightning: true, advisories: true) == "Other layers show now.")
    }

    @Test func theNoteHoldsStillWhileALoopPlays() {
        // The hour's loop never says it; the six-hour loop says it on every
        // frame, now included; neither changes as the frames go by.
        for isNow in [true, false] {
            #expect(!RadarTimeline.showsNowOnlyNote(span: .hour, playing: true, playheadIsNow: isNow))
            #expect(RadarTimeline.showsNowOnlyNote(span: .day, playing: true, playheadIsNow: isNow))
        }
        // Paused: only when the slider is somewhere other than now.
        for span in [RadarSpan.hour, .day] {
            #expect(RadarTimeline.showsNowOnlyNote(span: span, playing: false, playheadIsNow: false))
            #expect(!RadarTimeline.showsNowOnlyNote(span: span, playing: false, playheadIsNow: true))
        }
    }

    @Test func nowIsAQuarterHourEitherSide() {
        #expect(RadarTimeline.isNow(t0 + 900, nowTime: t0))
        #expect(!RadarTimeline.isNow(t0 - 1200, nowTime: t0))
    }
}
