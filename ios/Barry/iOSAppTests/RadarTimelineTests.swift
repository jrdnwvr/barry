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
        // From the start through now, then around; a scrub outside rejoins at the start.
        #expect(RadarTimeline.nextLoopIndex(current: 6, start: 6, nowIndex: 12) == 7)
        #expect(RadarTimeline.nextLoopIndex(current: 12, start: 6, nowIndex: 12) == 6)
        #expect(RadarTimeline.nextLoopIndex(current: 2, start: 6, nowIndex: 12) == 6)
        #expect(RadarTimeline.nextLoopIndex(current: 14, start: 6, nowIndex: 12) == 6)
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

    @Test func isobarsComeFromTheHourNearestTheSliderAndTheLiveFieldAtNow() {
        let series = (-6...12).map { PressureFrame(time: t0 + $0 * 3600, kind: $0 <= 0 ? "observed" : "model") }
        #expect(RadarTimeline.pressureFrame(series, time: t0, nowTime: t0) == nil)
        #expect(RadarTimeline.pressureFrame(series, time: t0 + 600, nowTime: t0) == nil)       // still now
        #expect(RadarTimeline.pressureFrame(series, time: t0 - 1800, nowTime: t0)?.time == t0 - 3600)
        #expect(RadarTimeline.pressureFrame(series, time: t0 - 6600, nowTime: t0)?.time == t0 - 7200)
        #expect(RadarTimeline.pressureFrame(series, time: t0 + 5 * 3600, nowTime: t0)?.kind == "model")
        // Nothing within 35 minutes: the live field stays.
        #expect(RadarTimeline.pressureFrame(Array(series.prefix(3)), time: t0 - 3600, nowTime: t0) == nil)
        #expect(RadarTimeline.pressureFrame([], time: t0 - 3600, nowTime: t0) == nil)
    }

    @Test func frontsStandAtNowRunBackThroughTheAnalysesAndAheadToTheProgs() {
        let analysis = chart(0, valid: t0 - 7200, lat: 40)             // two hours old, as it usually is
        let history = [chart(-6, valid: t0 - 7200 - 6 * 3600, lat: 43), chart(-3, valid: t0 - 7200 - 3 * 3600, lat: 42)]
        let progs = [chart(12, valid: t0 + 7 * 3600, lat: 37), chart(24, valid: t0 + 19 * 3600, lat: 35)]
        func pick(_ t: Int) -> RadarTimeline.FrontPick {
            RadarTimeline.fronts(at: t, nowTime: t0, analysis: analysis, history: history, progs: progs)
        }
        // From the analysis's own time through now: the analysis, as before.
        #expect(pick(t0) == .frame(analysis))
        #expect(pick(t0 - 3600) == .frame(analysis))
        #expect(pick(t0 + 600) == .frame(analysis))
        // Before it: between the charts either side, by their valid times.
        #expect(pick(t0 - 7200 - 5400) == .blend(history[1], analysis, 0.5))
        #expect(pick(t0 - 7200 - 4 * 3600) == .blend(history[0], history[1], 2.0 / 3.0))
        #expect(pick(t0 - 12 * 3600) == .frame(history[0]))
        // Ahead: it leaves from now and reaches the forecast chart at that chart's time.
        #expect(pick(t0 + 3600) == .blend(analysis, progs[0], 1.0 / 7.0))
        #expect(pick(t0 + 7 * 3600) == .blend(analysis, progs[0], 1.0))
        #expect(pick(t0 + 10 * 3600) == .blend(progs[0], progs[1], 0.25))
        #expect(pick(t0 + 30 * 3600) == .frame(progs[1]))
        // No history, no progs, no chart.
        #expect(RadarTimeline.fronts(at: t0 - 9 * 3600, nowTime: t0, analysis: analysis, history: [], progs: []) == .frame(analysis))
        #expect(RadarTimeline.fronts(at: t0 + 3 * 3600, nowTime: t0, analysis: analysis, history: [], progs: []) == .frame(analysis))
        #expect(RadarTimeline.fronts(at: t0, nowTime: t0, analysis: nil, history: history, progs: progs) == .none)
        // A forecast chart already behind now is skipped.
        let stale = [chart(12, valid: t0 - 600, lat: 39), progs[1]]
        #expect(RadarTimeline.fronts(at: t0 + 3600, nowTime: t0, analysis: analysis, history: [], progs: stale) == .blend(analysis, progs[1], 1.0 / 19.0))
    }

    @Test func aBlendedFrontSitsBetweenItsTwoCharts() {
        let a = chart(0, valid: t0, lat: 40), b = chart(12, valid: t0 + 12 * 3600, lat: 38)
        let mid = FrontMorph.blend(a, b, t: 0.5)
        #expect(mid.fronts.count == 1)
        #expect(abs((mid.fronts[0].coordinates.first?.latitude ?? 0) - 39) < 0.01)
        #expect(mid.fronts[0].alpha == 1)
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
