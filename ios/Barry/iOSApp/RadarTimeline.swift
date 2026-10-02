//  RadarTimeline.swift
//  Barry — iOS
//
//  The radar's clock: which frames a span lists, where its loop starts, what
//  the time line under the slider says, and which isobars and which front
//  positions go with the moment the slider is on. Pure functions, so the
//  rules are tested without a map.

import Foundation

/// The two replay chips. `hour` is every ten minutes from two hours back and
/// the nowcast; its loop is the last hour. `day` is on the hour from six
/// hours back to twelve ahead; its loop is the last six hours. Forecast
/// frames are scrubbed to, never looped.
enum RadarSpan: String {
    case hour, day

    /// How far back the loop starts, seconds before the newest observed frame.
    var loopSeconds: Int { self == .hour ? 3_600 : 6 * 3_600 }

    /// How fast the loop's clock runs, in seconds of weather per second:
    /// the hour in just under four seconds (a ten-minute frame every 0.55 s,
    /// as it always was), the six hours in eight.
    var rate: Double { self == .hour ? 600 / 0.55 : Double(loopSeconds) / 8 }
}

enum RadarFrameKind: String {
    case observed, nowcast, model
}

enum RadarTimeline {
    /// A moment this close to the newest observed frame is "now": the layers
    /// that only know the present are right for it, and the isobars are the
    /// live field's.
    static let nowToleranceS = 15 * 60
    /// Where the loop starts: the first frame within the span's loop length
    /// of the newest observed one.
    static func loopStart(frames: [RadarFrame], nowIndex: Int, span: RadarSpan) -> Int {
        guard frames.indices.contains(nowIndex) else { return 0 }
        let from = frames[nowIndex].time - span.loopSeconds
        return frames.firstIndex { $0.time >= from } ?? 0
    }

    /// How long the loop rests on the newest frame before going round, seconds.
    static let dwell = 1.65

    /// The loop's clock, one tick on. The clock is a moment in the weather,
    /// in seconds, not a frame number: it runs evenly from the loop's start
    /// to the newest observed frame, rests there, and goes round. The radar
    /// shows the frame nearest it; the fronts and the isobars are drawn for
    /// the moment itself, which is what makes them glide. A clock outside
    /// the loop (the slider was further back, or in the forecast) rejoins
    /// at the start. Returns the new clock and what is left of the rest.
    static func advance(clock: Double, dwellLeft: Double, by dt: Double, span: RadarSpan,
                        start: Double, end: Double) -> (clock: Double, dwellLeft: Double) {
        guard end > start else { return (end, 0) }
        if clock < start || clock > end { return (start, 0) }
        if dwellLeft > 0 {
            let left = dwellLeft - dt
            return left > 0 ? (end, left) : (start, 0)
        }
        let next = clock + dt * span.rate
        return next >= end ? (end, dwell) : (next, 0)
    }

    /// The frame the radar shows for a moment on the loop's clock: the
    /// nearest in time among the loop's own.
    static func frameIndex(nearest clock: Double, frames: [RadarFrame], start: Int, nowIndex: Int) -> Int {
        guard start <= nowIndex, frames.indices.contains(start), frames.indices.contains(nowIndex) else { return nowIndex }
        var best = start
        for i in start...nowIndex where abs(Double(frames[i].time) - clock) <= abs(Double(frames[best].time) - clock) {
            best = i
        }
        return best
    }

    static func isNow(_ time: Int, nowTime: Int) -> Bool {
        abs(time - nowTime) <= nowToleranceS
    }

    /// "8:20 PM · 20m ago", "11 AM · 5h ago", "8:50 PM · nowcast +40m",
    /// "10 PM · model +2h", "8:40 PM · latest, 3m ago".
    static func frameText(_ f: RadarFrame, nowTime: Int, wallClock: Date, parked: Bool,
                          clock: (Date) -> String) -> String {
        let at = clock(Date(timeIntervalSince1970: Double(f.time)))
        switch f.kind {
        case .model:
            let hrs = max(1, Int((Double(f.time - nowTime) / 3600).rounded()))
            return "\(at) · model +\(hrs)h"
        case .nowcast:
            let mins = max(10, Int((Double(f.time - nowTime) / 600).rounded()) * 10)
            return "\(at) · nowcast +\(mins)m"
        case .observed:
            let mins = Int((wallClock.timeIntervalSince1970 - Double(f.time)) / 60)
            let age: String
            if mins <= 1 { age = "now" }
            else if mins < 100 { age = "\(mins)m ago" }
            else { age = "\(Int((Double(mins) / 60).rounded()))h ago" }
            return parked ? "\(at) · latest, \(age)" : "\(at) · \(age)"
        }
    }

    /// Which chart the map draws at a moment.
    enum FrontPick: Equatable {
        case none
        case frame(FrontFrame)
        /// The first chart giving way to the second, 0 to 1.
        case fade(FrontFrame, FrontFrame, Double)

        /// The chart that has the say: the one being faded to once it is
        /// past half way.
        var chart: FrontFrame? {
            switch self {
            case .none: return nil
            case .frame(let f): return f
            case .fade(let a, let b, let t): return t >= 0.5 ? b : a
            }
        }
    }

    /// How long one chart takes to give way to the next, in seconds of
    /// weather: about half a second of the six-hour loop.
    static let frontFadeS = 20.0 * 60

    /// The chart for a moment on the timeline, each one as WPC drew it.
    /// An analysis has the map from its valid time until the next one's;
    /// the newest stands through now, as it always has here. Ahead of now
    /// a forecast chart takes over half way between the chart before it and
    /// its own valid time. One chart gives way to the next over
    /// `frontFadeS`, ending as the next takes over. No front is drawn
    /// anywhere a chart did not put it: sliding fronts between charts was
    /// tried and flew them across the map (FrontMorph.crossfade).
    static func fronts(at t: Double, nowTime: Int, analysis: FrontFrame?, history: [FrontFrame],
                       progs: [FrontFrame]) -> FrontPick {
        guard let analysis else { return .none }
        let now = Double(nowTime)
        // Each chart with the moment it takes over.
        var charts: [(frame: FrontFrame, from: Double)] = []
        let past = history.filter { $0.valid < analysis.valid }.sorted { $0.valid < $1.valid }
        for (i, f) in (past + [analysis]).enumerated() {
            charts.append((f, i == 0 ? -.infinity : f.valid.timeIntervalSince1970))
        }
        var before = max(now, analysis.valid.timeIntervalSince1970)
        for p in progs.sorted(by: { $0.valid < $1.valid }) {
            let at = p.valid.timeIntervalSince1970
            guard at > before else { continue }
            charts.append((p, (before + at) / 2))
            before = at
        }
        let i = charts.lastIndex { $0.from <= t } ?? 0
        if i + 1 < charts.count, t > charts[i + 1].from - frontFadeS {
            return .fade(charts[i].frame, charts[i + 1].frame, (t - (charts[i + 1].from - frontFadeS)) / frontFadeS)
        }
        return .frame(charts[i].frame)
    }

    /// Whether to say which layers are not on the slider's clock. The answer
    /// only changes when a finger does something (a chip, a scrub, Now),
    /// never as the loop plays: a line that came and went with every pass
    /// through now was the most distracting thing on the screen. The hour's
    /// loop says nothing, as it never did (those layers are an hour off at
    /// most); the six-hour loop says it throughout; a paused slider says it
    /// when it is somewhere other than now.
    static func showsNowOnlyNote(span: RadarSpan, playing: Bool, playheadIsNow: Bool) -> Bool {
        playing ? span == .day : !playheadIsNow
    }

    /// The words: the layers that stayed at now, by name while they fit
    /// beside the frame's time, nil when none of them is showing.
    static func nowOnlyNote(wind: Bool, stations: Bool, lightning: Bool, advisories: Bool,
                            change: Bool) -> String? {
        var names: [String] = []
        if wind { names.append("wind") }
        if stations { names.append("stations") }
        if lightning { names.append("lightning") }
        if advisories { names.append("advisories") }
        if change { names.append("pressure change") }
        guard let first = names.first else { return nil }
        let list: String
        switch names.count {
        case 1: list = first
        case 2: list = "\(first) and \(names[1])"
        case 3: list = "\(first), \(names[1]) and \(names[2])"
        default: return "Other layers show now."
        }
        let subject = list.prefix(1).uppercased() + list.dropFirst()
        return "\(subject) \(names.count == 1 && !first.hasSuffix("s") ? "shows" : "show") now."
    }
}
