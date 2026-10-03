//  RadarModel.swift
//  Barry — iOS
//
//  State for the radar screen: the frames and their two spans, the model
//  wind grid, WPC fronts and the isobars on the frames' clock, the station
//  layer and the pressure field. All data comes through the Barry backend.

import Combine
import SwiftUI
import MapKit

// MARK: - Frames

struct RadarFrame: Equatable, Identifiable {
    let time: Int      // unix epoch (valid time)
    let path: String   // e.g. /radar/tiles/1790959200, /radar/model/1790964003
    /// Observed, the nowcast (the newest frame carried forward), or the
    /// model's own reflectivity: a guess about where, not a measurement,
    /// and the time line under the slider says which.
    let kind: RadarFrameKind
    /// What the map keeps this frame's tiles under. A valid time can have
    /// two pictures (the hour span's nowcast and the day span's model), and
    /// a newer run draws a new picture for the same time, so the time alone
    /// will not do: the number the path ends in names the picture.
    let key: Int
    var nowcast: Bool { kind != .observed }
    var id: Int { key }

    init(time: Int, path: String, kind: RadarFrameKind) {
        self.time = time
        self.path = path
        self.kind = kind
        let tail = path.split(separator: "/").last.flatMap { Int($0) }
        switch kind {
        case .observed: key = time
        case .nowcast: key = tail ?? time + 7
        case .model: key = -(tail ?? time)
        }
    }

    init(_ f: RadarFrameOut) {
        self.init(time: f.time, path: f.path,
                  kind: f.kind.flatMap(RadarFrameKind.init(rawValue:)) ?? (f.nowcast ? .nowcast : .observed))
    }
}

/// One wind-field sample: where, how hard, and from which direction.
struct WindArrow: Equatable {
    let lat: Double
    let lon: Double
    let speedKmh: Double
    let fromDeg: Double
}

/// A stop on the radar's altitude rail: the surface, or a pressure level
/// with the height it sits near.
struct WindAltitude: Identifiable, Equatable {
    let hPa: Int          // 0 = the surface
    let ft: Int
    let short: String
    /// The speed that reads as full strength on the streak ramp here. Winds
    /// aloft run far faster than at the ground; one scale would draw every
    /// streak at 18,000 ft solid black.
    let rampKmh: Double
    var id: Int { hPa }

    static let all: [WindAltitude] = [
        WindAltitude(hPa: 0, ft: 0, short: "SFC", rampKmh: 35),
        WindAltitude(hPa: 925, ft: 2_500, short: "2.5k", rampKmh: 50),
        WindAltitude(hPa: 850, ft: 5_000, short: "5k", rampKmh: 65),
        WindAltitude(hPa: 700, ft: 10_000, short: "10k", rampKmh: 85),
        WindAltitude(hPa: 600, ft: 14_000, short: "14k", rampKmh: 105),
        WindAltitude(hPa: 500, ft: 18_000, short: "18k", rampKmh: 130),
    ]

    static func stop(_ hPa: Int) -> WindAltitude { all.first { $0.hPa == hPa } ?? all[0] }
}

@MainActor
final class RadarModel: ObservableObject {
    @Published var frames: [RadarFrame] = []
    @Published var host = "https://tilecache.rainviewer.com"
    /// Tile template for the chance of lightning in the next hour, when
    /// Barry serves it.
    @Published private(set) var lightningNextTemplate: String?
    @Published var index = 0 {
        didSet { if index != oldValue { playheadMoved() } }
    }
    /// Which replay chip the timeline is on (RadarTimeline.swift). Not
    /// remembered between opens: the radar always opens on the hour.
    @Published private(set) var span: RadarSpan = .hour
    private var framesBySpan: [RadarSpan: [RadarFrame]] = [:]
    private var framesLoadedAt: [RadarSpan: Date] = [:]
    /// A loop has been asked for and is waiting for its frames to load, the
    /// way a video buffers: the map holds on the newest frame meanwhile
    /// (RadarMapView's `syncBuffer` reports back). The replay chip reads as
    /// on from the tap, so the wait is not mistaken for a tap that missed.
    @Published private(set) var buffering = false
    private(set) var bufferID = 0

    /// Ask for the span's loop: show now, load the loop's frames, then play.
    func startLoop() {
        guard !frames.isEmpty else { return }
        playing = false
        lockedToNow = false
        index = nowIndex
        bufferID += 1
        buffering = true
        ensureMotion()
        ensureClockLayers()
    }

    /// The map's word that the frames are loaded (or the wait ran out).
    func bufferReady(_ id: Int) {
        guard buffering, id == bufferID else { return }
        buffering = false
        restartLoop()
        playing = true
    }

    /// Stop a loop, playing or still loading.
    func stopLoop() {
        buffering = false
        playing = false
    }

    @Published var playing = false {
        didSet {
            guard playing != oldValue else { return }
            if playing {
                // Pick the clock up where the slider is.
                clockFrontPick = nil
                dwellLeft = 0
                playClock = Double(playheadTime)
            } else {
                clockFrontPick = nil
                updateFrontState(force: true)
            }
        }
    }
    /// The Now pill: the map stays on the freshest observed frame, through
    /// reloads, until the loop or a scrub moves it.
    @Published var lockedToNow = false
    @Published var failed = false
    @Published var windArrows: [WindArrow] = []
    /// The whole wind grid, calm points included — the flow layer's field.
    @Published var windField: [WindArrow] = []

    /// The altitude the wind layer shows: 0 is the surface, otherwise a
    /// pressure level from `WindAltitude.all`. Not remembered between opens:
    /// the map always starts at the ground.
    @Published var windLevel = 0 {
        didSet {
            guard windLevel != oldValue else { return }
            applyLevel()
            ensureClockLayers()
            heights = nil
            if windLevel != 0, let r = lastRegion {
                Task { await fetchLevels(region: r) }
                Task { await fetchHeights(region: r) }
            }
        }
    }
    /// Height contours at `windLevel`, drawn by the pressure renderer while
    /// the rail is off the surface. Nil at the surface or outside HRRR.
    @Published private(set) var heights: HeightsResponse?
    private var heightsFetchedFor: MKCoordinateRegion?
    /// The wind grid at `windLevel` when it is not the surface.
    @Published private(set) var levelField: [WindArrow] = []
    private var levels: FieldLevelsResponse?
    private var levelsFetchedFor: MKCoordinateRegion?

    /// What the wind layer draws: the surface grid or the chosen level's.
    var shownWindField: [WindArrow] { windLevel == 0 ? windField : levelField }
    var shownWindArrows: [WindArrow] {
        windLevel == 0 ? windArrows : levelField.filter { $0.speedKmh >= Self.minArrowKmh }
    }
    /// Reporting stations with their latest wind (barb / speed layer).
    @Published var stationObs: [StationObs] = []
    private var stationTask: Task<Void, Never>?
    private var stationsFetchedFor: MKCoordinateRegion?

    /// Fetch stations for a region center. The backend slices ±3° out of its
    /// in-memory METAR table (no upstream call), so this is cheap; still, only
    /// bother it after a real move (~1.5°, half the box).
    /// Box half-width for a region: wide enough to cover what is on screen,
    /// with the old ±3° as the floor so a close-in view behaves as before.
    private static func stationHalf(_ r: MKCoordinateRegion) -> Double {
        (max(3.0, min(30.0, r.span.latitudeDelta * 0.7)) * 2).rounded() / 2
    }

    static let buoysKey = "radarBuoys"

    func fetchStations(region: MKCoordinateRegion, force: Bool = false) async {
        // Reuse what we have while the fetched box still comfortably covers
        // the map and the zoom has not changed much.
        if !force, let prev = stationsFetchedFor, !stationObs.isEmpty {
            let ratio = region.span.latitudeDelta / prev.span.latitudeDelta
            let slack = Self.stationHalf(prev) * 0.5
            if ratio > 0.6, ratio < 1.6,
               abs(prev.center.latitude - region.center.latitude) < slack,
               abs(prev.center.longitude - region.center.longitude) < slack {
                return
            }
        }
        guard let resp = try? await BarryAPI().metars(lat: region.center.latitude,
                                                      lon: region.center.longitude,
                                                      half: Self.stationHalf(region),
                                                      buoys: AppConfig.sharedDefaults.bool(forKey: Self.buoysKey))
        else { return }
        stationsFetchedFor = region
        stationObs = resp.stations
    }

    /// SIGMETs, G-AIRMETs and PIREPs for the region (the server cuts them
    /// from national feeds; refetched when the map moves well away).
    @Published var advisories: AdvisoriesResponse?
    private var advisoriesFetchedFor: MKCoordinateRegion?
    private var advisoriesTask: Task<Void, Never>?

    func fetchAdvisories(region: MKCoordinateRegion, force: Bool = false) async {
        let half = max(3, min(30, region.span.latitudeDelta))
        if !force, let prev = advisoriesFetchedFor, advisories != nil {
            let ratio = region.span.latitudeDelta / prev.span.latitudeDelta
            if ratio > 0.6, ratio < 1.6,
               abs(prev.center.latitude - region.center.latitude) < half * 0.4,
               abs(prev.center.longitude - region.center.longitude) < half * 0.4 { return }
        }
        guard let resp = try? await BarryAPI().advisories(lat: region.center.latitude,
                                                          lon: region.center.longitude, half: half)
        else { return }
        advisoriesFetchedFor = region
        advisories = resp
    }

    /// GLM flashes for the Storms overlay (backend memory; polled per minute).
    @Published var lightning: LightningState = LightningState()
    private var lightningTask: Task<Void, Never>?
    private var lightningFetchedAround: CLLocationCoordinate2D?

    /// Fetch the flash slice around a center. Cheap on the server (memory),
    /// so re-fetch on a real move (~1.5°) and on the minute tick.
    func fetchLightning(center: CLLocationCoordinate2D, force: Bool = false) async {
        if !force, let prev = lightningFetchedAround,
           abs(prev.latitude - center.latitude) < 1.5, abs(prev.longitude - center.longitude) < 1.5,
           lightning.response != nil {
            return
        }
        guard let resp = try? await BarryAPI().lightning(lat: center.latitude, lon: center.longitude) else { return }
        lightningFetchedAround = center
        lightning = LightningState(response: resp, version: lightning.version + 1, receivedAt: Date())
    }

    /// Last region the map reported — used when a toggle flips on.
    var lastRegion: MKCoordinateRegion?
    private var fieldTask: Task<Void, Never>?
    private var pressureTask: Task<Void, Never>?

    /// Isobars / isallobars / shaded grids for the current region (server
    /// contours its station table; nothing upstream).
    @Published var pressureField: PressureFieldResponse?
    @Published var pressureVersion = 0

    func fetchPressureField(region: MKCoordinateRegion, retried: Bool = false) async {
        if Self.nearEnough(region, to: pressureFetchedFor), pressureField != nil { return }
        let resp: PressureFieldResponse
        do {
            resp = try await BarryAPI().pressureField(
                lat: region.center.latitude, lon: region.center.longitude,
                latSpan: region.span.latitudeDelta, lonSpan: region.span.longitudeDelta)
        } catch {
            // The old window stays drawn meanwhile (enrichment). One more
            // try after the edge's rate-limit block, if the map has not moved.
            if !retried { retryLater(for: region) { [weak self] in await self?.fetchPressureField(region: region, retried: true) } }
            return
        }
        pressureFetchedFor = region
        pressureField = resp
        pressureVersion += 1
    }

    /// Cloudflare's rate rule answers a burst (a zoom out asks for tiles and
    /// every grid at once) with 429 for ten seconds, and the grids kept their
    /// old window until the next pan. So a failed grid fetch is tried once
    /// more after the block, if the map is still where it was.
    private func retryLater(for region: MKCoordinateRegion, seconds: Double = 11,
                            _ op: @escaping () async -> Void) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let last = lastRegion, Self.sameRegion(last, region) else { return }
            await op()
        }
    }

    private static func sameRegion(_ a: MKCoordinateRegion, _ b: MKCoordinateRegion) -> Bool {
        abs(a.center.latitude - b.center.latitude) < 1e-6 && abs(a.center.longitude - b.center.longitude) < 1e-6
            && abs(a.span.latitudeDelta - b.span.latitudeDelta) < 1e-6
    }

    private var fieldFetchedFor: MKCoordinateRegion?
    private var pressureFetchedFor: MKCoordinateRegion?

    /// Close enough to the region a grid was fetched for that refetching it
    /// would return the same thing. The backend quantizes these anyway, so a
    /// small move is a round trip for an identical payload.
    private static func nearEnough(_ r: MKCoordinateRegion, to prev: MKCoordinateRegion?) -> Bool {
        guard let prev else { return false }
        let ratio = r.span.latitudeDelta / prev.span.latitudeDelta
        guard ratio > 0.8, ratio < 1.25 else { return false }
        return abs(prev.center.latitude - r.center.latitude) < prev.span.latitudeDelta * 0.2
            && abs(prev.center.longitude - r.center.longitude) < prev.span.longitudeDelta * 0.2
    }

    /// Arrows render from a light breeze up (~3 kt) and fade/shrink with speed,
    /// so calm still reads calm without the layer going blank. The old ~8 kt
    /// floor applied to the MODEL grid wind, which runs lower than an airport
    /// anemometer and sat under the floor across the Ohio Valley most days —
    /// green toggle, empty map, indistinguishable from broken.
    static let minArrowKmh = 6.0
    /// Speed at which an arrow reaches full size and presence (km/h).
    static let fullArrowKmh = 45.0
    /// True once a wind fetch has answered, so "no arrows" is a real answer.
    @Published var windSampled = false

    // MARK: Fronts (WPC surface chart, on the radar's clock)

    @Published var frontFrames: [FrontFrame] = []
    /// The analyses before the current one, oldest first.
    private(set) var frontHistory: [FrontFrame] = []
    @Published var frontState: FrontRenderState = .empty
    private var frontVersion = 0
    private var shownFrontPick: RadarTimeline.FrontPick = .none

    /// The current analysis: what the map draws at now. The timeline shows
    /// the chart of the moment it is on instead: an earlier analysis behind
    /// now, WPC's forecast chart ahead (RadarTimeline.fronts), each as
    /// drawn. Until 2026-10-02 the forecast charts arrived unused, because
    /// a map that carried its own clock separate from the radar's was a
    /// good way to read tomorrow's front as today's; now there is one clock.
    var analysisFrame: FrontFrame? {
        frontFrames.first(where: { $0.hours == 0 }) ?? frontFrames.first
    }

    /// Which parts of the chart to draw (map options). Changing it
    /// re-renders the field in place.
    var frontStyle = FrontStyle() {
        didSet { if frontStyle != oldValue { clockFrontPick = nil; updateFrontState(force: true) } }
    }

    func fetchFronts() async {
        guard let resp = try? await BarryAPI().fronts() else { return }
        frontFrames = resp.frames.sorted { $0.hours < $1.hours }
        frontHistory = resp.history ?? []
        clockFrontPick = nil
        updateFrontState(force: true)
    }

    /// The chart for the moment the slider is on. While a loop plays the
    /// map reads `frontState(at:)` for the clock's own moment thirty times
    /// a second instead, and this catches up when it stops.
    func updateFrontState(force: Bool = false) {
        let pick = frontPick(at: Double(playheadTime))
        guard force || pick != shownFrontPick else { return }
        shownFrontPick = pick
        frontVersion += 1
        var next = render(pick)
        next.version = frontVersion
        frontState = next
    }

    private func frontPick(at t: Double) -> RadarTimeline.FrontPick {
        RadarTimeline.fronts(at: t, nowTime: nowTime, analysis: analysisFrame,
                             history: frontHistory, progs: frontFrames.filter { $0.hours > 0 })
    }

    private func render(_ pick: RadarTimeline.FrontPick) -> FrontRenderState {
        var next: FrontRenderState
        switch pick {
        case .none: next = .empty
        case .frame(let f): next = FrontMorph.state(for: f)
        case .fade(let a, let b, let t): next = FrontMorph.crossfade(a, b, t: t)
        }
        next.style = frontStyle
        if !frontStyle.centers { next.centers = [] }
        return next
    }

    /// The chart the map is showing, for the key to name.
    var shownFrontChart: FrontFrame? { frontPick(at: lineTime).chart }

    /// The chart at a moment, for the map's line clock: nil while it is
    /// the chart the clock was last given (a chart stands for hours of the
    /// loop, and redrawing it twenty times a second for nothing was part
    /// of what the frame rate paid for).
    func frontState(at t: Double) -> FrontRenderState? {
        let pick = frontPick(at: t)
        guard pick != clockFrontPick else { return nil }
        clockFrontPick = pick
        frontVersion += 1
        var next = render(pick)
        next.version = frontVersion
        return next
    }
    private var clockFrontPick: RadarTimeline.FrontPick?

    // MARK: The timeline

    /// Index of the most recent observed (non-forecast) frame.
    var nowIndex: Int {
        frames.lastIndex(where: { !$0.nowcast }) ?? 0
    }

    /// The newest observed frame's time: the timeline's "now".
    var nowTime: Int {
        frames.indices.contains(nowIndex) ? frames[nowIndex].time : Int(Date().timeIntervalSince1970)
    }

    /// The moment the slider is on.
    var playheadTime: Int {
        frames.indices.contains(index) ? frames[index].time : nowTime
    }

    var playheadIsNow: Bool { RadarTimeline.isNow(playheadTime, nowTime: nowTime) }

    /// Where the current span's loop starts.
    var loopStart: Int { RadarTimeline.loopStart(frames: frames, nowIndex: nowIndex, span: span) }

    /// The frames the loop plays, in order.
    var loopKeys: [Int] {
        guard !frames.isEmpty else { return [] }
        return frames[loopStart...max(loopStart, nowIndex)].map(\.key)
    }

    private func playheadMoved() {
        // While a loop plays the lines follow its clock, not the frames.
        if !playing { updateFrontState() }
        ensurePressureSeries()
        ensureClockLayers()
    }

    // MARK: The loop's clock

    /// The moment the loop is on, in seconds, running evenly while it plays
    /// (RadarTimeline.advance). Not published: thirty changes a second would
    /// rebuild the whole panel each time. The radar follows it a frame at a
    /// time through `index`; the map reads it directly for the lines.
    private(set) var playClock: Double = 0
    private var dwellLeft: Double = 0

    /// One tick of the loop, `dt` seconds on.
    func advance(by dt: Double) {
        guard playing, !frames.isEmpty else { return }
        let start = loopStart, last = nowIndex
        let moved = RadarTimeline.advance(clock: playClock, dwellLeft: dwellLeft, by: dt, span: span,
                                          start: Double(frames[start].time), end: Double(frames[last].time))
        playClock = moved.clock
        dwellLeft = moved.dwellLeft
        let i = RadarTimeline.frameIndex(nearest: playClock, frames: frames, start: start, nowIndex: last)
        if i != index { index = i }
    }

    /// Start the loop from its first frame.
    func restartLoop() {
        guard !frames.isEmpty else { return }
        dwellLeft = 0
        playClock = Double(frames[loopStart].time)
        index = loopStart
    }

    /// The moment the lines are drawn for: the clock while a loop plays,
    /// the slider's frame otherwise.
    var lineTime: Double { playing ? playClock : Double(playheadTime) }

    // MARK: Scrubbing

    /// A finger is on the slider. The GPU then draws the moment under the
    /// thumb, between frames, as it draws a loop; the frame time and the
    /// lines follow the nearest frame through `index`. Not a frame at a
    /// time through the tile layers, which fetched and crossfaded each
    /// frame the thumb crossed and lagged the finger (Jordan, 2026-10-02).
    @Published private(set) var scrubbing = false
    /// Where the thumb is, in frames (fractional), and the moment that is.
    private(set) var scrubPosition: Double = 0
    private(set) var scrubClock: Double = 0

    func scrub(to position: Double, editing: Bool) {
        guard !frames.isEmpty else { return }
        let p = max(0, min(Double(frames.count - 1), position))
        scrubPosition = p
        let i = Int(p.rounded(.down)), j = min(frames.count - 1, i + 1)
        scrubClock = Double(frames[i].time) + (Double(frames[j].time) - Double(frames[i].time)) * (p - Double(i))
        let nearest = Int(p.rounded())
        if nearest != index { index = nearest }
        if editing != scrubbing {
            scrubbing = editing
            if editing { ensureMotion() }
        }
        // A thumb that has not moved for a while is as good as lifted: the
        // frame's tiles take over under the GPU's picture, and a finger
        // still resting there loses nothing. Also the way out when the
        // slider never says the touch ended (a synthesized drag).
        scrubIdle?.cancel()
        guard scrubbing else { return }
        scrubIdle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled, self.scrubbing else { return }
            self.scrubbing = false
        }
    }
    private var scrubIdle: Task<Void, Never>?

    /// The frames the loop plays.
    var loopFrames: [RadarFrame] {
        guard !frames.isEmpty else { return [] }
        return Array(frames[loopStart...max(loopStart, nowIndex)])
    }

    // MARK: The rain's motion

    /// How the rain moved between the loop's frames over the region on
    /// screen (`/radar/motion`), for the GPU to slide the frames along
    /// (RadarGlideView). Asked for when a loop starts and again when the
    /// newest frame or the region changes; until it arrives, or where it
    /// is not given, the frames crossfade in place as they always did.
    @Published private(set) var motionField: RadarMotionField?
    private var motionFetchedFor: (span: RadarSpan, region: MKCoordinateRegion)?
    private var motionTask: Task<Void, Never>?

    func ensureMotion() {
        guard playing || buffering || scrubbing, let region = lastRegion, !frames.isEmpty else { return }
        let now = nowTime
        if let held = motionField, held.nowTime == now, let was = motionFetchedFor, was.span == span,
           Self.nearEnough(region, to: was.region) { return }
        motionTask?.cancel()
        let span = span
        motionTask = Task { [weak self] in
            guard let resp = try? await BarryAPI().radarMotion(
                span: span.rawValue, lat: region.center.latitude, lon: region.center.longitude,
                latSpan: region.span.latitudeDelta, lonSpan: region.span.longitudeDelta)
            else { return }
            guard let self, !Task.isCancelled else { return }
            self.motionFetchedFor = (span, region)
            self.motionField = RadarMotionField(resp, nowTime: now)
        }
    }

    /// A span's frame list goes stale as fast as the radar does.
    private static let framesFreshFor: TimeInterval = 5 * 60

    /// The timeline comes from the backend (`/radar/frames`), already trimmed
    /// to the span and shared across users, so a radar open costs one small
    /// request.
    func load(retries: Int = 2) async {
        failed = false
        do {
            let resp = try await BarryAPI().radarFrames(span: span.rawValue)
            let hadFrames = !frames.isEmpty
            apply(resp, to: span)
            // A reload snaps to now unless the user parked the timeline
            // somewhere or the loop is running; then the index stays.
            if lockedToNow || !hadFrames {
                index = nowIndex
            } else {
                index = min(index, max(0, frames.count - 1))
            }
        } catch {
            // A load whose own task was cancelled (its view went away) has
            // nothing to report and nothing to retry.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
            // Opening the radar asks for the frames, the grids and dozens of
            // tiles at once, and the edge's rate rule answers the tail of that
            // burst with 429 for ten seconds. Wait it out and ask again
            // before calling it a connection problem.
            if retries > 0 {
                try? await Task.sleep(nanoseconds: 11_000_000_000)
                await load(retries: retries - 1)
                return
            }
            failed = true
            return
        }
    }

    private func apply(_ resp: RadarFramesResponse, to target: RadarSpan) {
        host = resp.host
        lightningNextTemplate = resp.lightningNext.map { resp.host + $0.path + "/512/{z}/{x}/{y}.png" }
        let list = resp.frames.map(RadarFrame.init)
        framesBySpan[target] = list
        framesLoadedAt[target] = Date()
        if target == span {
            frames = list
            ensureMotion()
            ensureClockLayers()
        }
    }

    /// Put the timeline on a span, parked on now. The other span's list is
    /// fetched the first time and again once it is five minutes old; when
    /// that fails the timeline stays where it was. True when it switched.
    @discardableResult
    func setSpan(_ target: RadarSpan) async -> Bool {
        guard target != span else { return true }
        let fresh = framesLoadedAt[target].map { Date().timeIntervalSince($0) < Self.framesFreshFor } ?? false
        if !fresh || framesBySpan[target]?.isEmpty != false {
            if let resp = try? await BarryAPI().radarFrames(span: target.rawValue) {
                apply(resp, to: target)
            }
        }
        guard let list = framesBySpan[target], !list.isEmpty else { return false }
        span = target
        frames = list
        index = nowIndex
        playheadMoved()
        return true
    }

    // MARK: The wind, the stations and the lightning on the clock

    /// The past hours of each, for the moments the loop plays and the
    /// slider parks on (LayerTimelines.swift). Asked for when a loop
    /// starts or the slider leaves now, with a layer on, and again when
    /// the newest frame or the region changes; nil until it arrives, and
    /// the layer stays at now meanwhile.
    @Published private(set) var windTimeline: WindTimeline?
    @Published private(set) var stationTimeline: StationTimeline?
    @Published private(set) var lightningTimeline: LightningTimeline?
    private var windSeriesFor: (region: MKCoordinateRegion, levels: Bool)?
    private var stationSeriesFor: MKCoordinateRegion?
    private var lightningSeriesFor: MKCoordinateRegion?
    private var windSeriesTask: Task<Void, Never>?
    private var stationSeriesTask: Task<Void, Never>?
    private var lightningSeriesTask: Task<Void, Never>?
    /// The view's say: which of the layers are on.
    var wantsWindClock = false { didSet { if wantsWindClock && !oldValue { ensureClockLayers() } } }
    var wantsStationClock = false { didSet { if wantsStationClock && !oldValue { ensureClockLayers() } } }
    var wantsLightningClock = false { didSet { if wantsLightningClock && !oldValue { ensureClockLayers() } } }

    /// Whether the clock is somewhere the past matters: a loop up, or the
    /// slider away from now.
    private var clockAway: Bool { playing || buffering || !playheadIsNow }

    func ensureClockLayers() {
        guard clockAway, let region = lastRegion, !frames.isEmpty else { return }
        let now = nowTime
        if wantsWindClock {
            let levels = windLevel != 0
            let fresh = windTimeline?.nowTime == now && windSeriesFor.map { Self.nearEnough(region, to: $0.region) && ($0.levels || !levels) } == true
            if !fresh {
                windSeriesTask?.cancel()
                windSeriesTask = Task { [weak self] in
                    guard let resp = try? await BarryAPI().fieldSeries(
                        lat: region.center.latitude, lon: region.center.longitude,
                        latSpan: region.span.latitudeDelta, lonSpan: region.span.longitudeDelta,
                        pad: Self.windPad, levels: levels)
                    else { return }
                    guard let self, !Task.isCancelled else { return }
                    self.windSeriesFor = (region, levels)
                    self.windTimeline = WindTimeline(resp, nowTime: now)
                }
            }
        }
        if wantsStationClock {
            let fresh = stationTimeline?.nowTime == now && Self.nearEnough(region, to: stationSeriesFor)
            if !fresh {
                stationSeriesTask?.cancel()
                stationSeriesTask = Task { [weak self] in
                    guard let resp = try? await BarryAPI().stationSeries(
                        lat: region.center.latitude, lon: region.center.longitude, half: Self.stationHalf(region))
                    else { return }
                    guard let self, !Task.isCancelled else { return }
                    self.stationSeriesFor = region
                    self.stationTimeline = StationTimeline(resp, nowTime: now)
                }
            }
        }
        if wantsLightningClock {
            let fresh = lightningTimeline?.nowTime == now && Self.nearEnough(region, to: lightningSeriesFor)
            if !fresh {
                lightningSeriesTask?.cancel()
                lightningSeriesTask = Task { [weak self] in
                    guard let resp = try? await BarryAPI().lightningSeries(
                        lat: region.center.latitude, lon: region.center.longitude,
                        half: max(0.5, min(6, region.span.latitudeDelta * 0.7)))
                    else { return }
                    guard let self, !Task.isCancelled else { return }
                    self.lightningSeriesFor = region
                    self.lightningTimeline = LightningTimeline(resp, nowTime: now)
                }
            }
        }
    }

    /// The wind of a moment, as the two hourly grids either side.
    func windFields(at t: Double) -> (a: [WindArrow], b: [WindArrow], f: Double)? {
        windTimeline?.fields(at: t, level: windLevel)
    }

    /// What the wind layer draws while nothing plays: the live grid at
    /// now, the slider's moment's away from it when the series reaches.
    var shownWindFieldOnClock: [WindArrow] {
        guard !playing, !playheadIsNow, let f = windTimeline?.field(at: Double(playheadTime), level: windLevel) else {
            return shownWindField
        }
        return f
    }
    var shownWindArrowsOnClock: [WindArrow] {
        guard !playing, !playheadIsNow, let f = windTimeline?.field(at: Double(playheadTime), level: windLevel) else {
            return shownWindArrows
        }
        return f.filter { $0.speedKmh >= Self.minArrowKmh }
    }

    /// The stations as they reported at the slider's moment, else now.
    var shownStationObs: [StationObs] {
        guard !playing, !playheadIsNow, let line = stationTimeline, line.covers(Double(playheadTime)),
              let obs = line.observations(at: Double(playheadTime)) else { return stationObs }
        return obs
    }

    /// The lightning of the slider's moment, else now's.
    var shownLightning: LightningState {
        guard !playing, !playheadIsNow, let state = lightningTimeline?.state(at: Double(playheadTime)) else { return lightning }
        return state
    }

    /// Whether each series reaches the moments the timeline is on (the
    /// whole loop while one plays, the slider's moment otherwise), for the
    /// note under the frame time.
    func windFollowsClock() -> Bool { followsClock { windTimeline?.covers($0, level: windLevel) ?? false } }
    func stationsFollowClock() -> Bool { followsClock { stationTimeline?.covers($0) ?? false } }
    func lightningFollowsClock() -> Bool { followsClock { lightningTimeline?.covers($0) ?? false } }

    private func followsClock(_ covers: (Double) -> Bool) -> Bool {
        guard !frames.isEmpty else { return false }
        if playing || buffering {
            let start = frames[loopStart].time
            return covers(Double(start)) && covers(Double(nowTime))
        }
        return covers(Double(playheadTime))
    }

    // MARK: Isobars on the radar's clock

    /// The pressure field over the current region at each hour of the day
    /// span and at now, ready to be read at any moment (PressureTimeline).
    /// Only asked for once the slider leaves now or the day span is up, and
    /// only while a pressure layer is on.
    @Published private(set) var pressureTimeline: PressureTimeline?
    private var seriesFetchedFor: MKCoordinateRegion?
    private var seriesTask: Task<Void, Never>?
    /// The view's say: is a pressure layer showing, and does it shade.
    var wantsPressureSeries = false {
        didSet { if wantsPressureSeries && !oldValue { ensurePressureSeries() } }
    }
    var wantsPressureGrid = false

    func ensurePressureSeries() {
        guard wantsPressureSeries, span == .day || !playheadIsNow, let region = lastRegion else { return }
        if pressureTimeline != nil, Self.nearEnough(region, to: seriesFetchedFor) { return }
        seriesTask?.cancel()
        seriesTask = Task { [weak self] in
            guard let resp = try? await BarryAPI().pressureSeries(
                lat: region.center.latitude, lon: region.center.longitude,
                latSpan: region.span.latitudeDelta, lonSpan: region.span.longitudeDelta)
            else { return }
            guard let self, !Task.isCancelled else { return }
            self.seriesFetchedFor = region
            self.pressureTimeline = PressureTimeline(resp)
        }
    }

    /// The live field with the isobars (and, when the shading wants it, the
    /// grid) of a moment in place of its own: what the pressure overlay
    /// draws away from now. The change field and its lines only know now
    /// and stay as they are (the note says so). Nil when there is no
    /// series to read the moment from.
    ///
    /// `pattern` draws the field's shape instead of its values (the area's
    /// own rise or fall since then taken out, PressureTimeline.pattern):
    /// what the six-hour loop plays, without labels.
    /// `lines` false leaves the isobars out (the Metal layer is drawing
    /// them) and returns nil when the shading does not want the grid either.
    func pressureField(at t: Double, pattern: Bool = false, lines: Bool = true) -> PressureFieldResponse? {
        guard let line = pressureTimeline, var field = pressureField, lines || wantsPressureGrid else { return nil }
        let values = pattern ? line.pattern(at: t) : line.values(at: t)
        field.isobars = lines ? line.isobars(values) : []
        if wantsPressureGrid { field.pressureGrid = line.grid(values) }
        return field
    }

    /// What the pressure overlay draws while nothing is playing: the live
    /// field at now, the slider's moment away from it. While a loop plays
    /// the map reads `pressureField(at:)` for the clock's own moment.
    var shownPressureField: PressureFieldResponse? {
        guard !playing, !playheadIsNow, let moved = pressureField(at: Double(playheadTime)) else { return pressureField }
        return moved
    }

    /// Changes whenever what `shownPressureField` returns does.
    var shownPressureVersion: Int {
        let away = !playing && !playheadIsNow && pressureTimeline != nil
        return pressureVersion &* 100_003 &+ (away ? playheadTime : 0) &+ (wantsPressureGrid ? 1 : 0)
    }

    // MARK: Field overlays (wind)

    /// Debounced reload — pans/zooms fire this; only the last one within ~0.7 s wins.
    func scheduleFieldReload(for region: MKCoordinateRegion, wind: Bool,
                             stations: Bool = false, pressure: Bool = false,
                             storms: Bool = false, advisories: Bool = false) {
        lastRegion = region
        ensureMotion()
        ensureClockLayers()
        if advisories {
            advisoriesTask?.cancel()
            advisoriesTask = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await fetchAdvisories(region: region)
            }
        }
        if storms {
            lightningTask?.cancel()
            lightningTask = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await fetchLightning(center: region.center)
            }
        }
        if pressure {
            pressureTask?.cancel()
            pressureTask = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await fetchPressureField(region: region)
                ensurePressureSeries()
            }
        }
        if stations {
            stationTask?.cancel()
            stationTask = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await fetchStations(region: region)
            }
        }
        if wind {
            fieldTask?.cancel()
            fieldTask = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await fetchField(region: region)
                if windLevel != 0 {
                    await fetchLevels(region: region)
                    await fetchHeights(region: region)
                }
            }
        }
    }

    /// How far past each edge of the view the wind grid is asked for, as a
    /// fraction of the span. A grid is kept until the view has moved a
    /// fifth of its span (`nearEnough`), so with half a span to spare the
    /// wind is already there wherever a pan stops, and the points, on a
    /// lattice every region shares, are the same ones as before. Until
    /// 2026-10-02 the grid stopped short of the view's own edges and was
    /// laid out afresh for each region: a pan showed bare map, then every
    /// arrow jumped.
    static let windPad = 0.5

    /// The model wind for the region in ONE backend call (the server samples
    /// its 7×5 grid and shares one Open-Meteo request per region cell across
    /// users).
    func fetchField(region: MKCoordinateRegion, retried: Bool = false) async {
        // The station layer already skips a refetch for a small move; the wind
        // grid used to hit the network on every nudge. A fifth of the span in
        // either direction, or a quarter of a zoom step, reuses what we have.
        if Self.nearEnough(region, to: fieldFetchedFor), !windField.isEmpty { return }
        let resp: FieldGridResponse
        do {
            resp = try await BarryAPI().fieldGrid(
                lat: region.center.latitude, lon: region.center.longitude,
                latSpan: region.span.latitudeDelta, lonSpan: region.span.longitudeDelta,
                pad: Self.windPad)
        } catch {
            // Enrichment: keep whatever we had, and try once more after a block.
            if !retried { retryLater(for: region) { [weak self] in await self?.fetchField(region: region, retried: true) } }
            return
        }
        fieldFetchedFor = region
        let all = resp.points.map {
            WindArrow(lat: $0.lat, lon: $0.lon, speedKmh: $0.windKmh, fromDeg: $0.windDeg)
        }
        windField = all
        windArrows = all.filter { $0.speedKmh >= Self.minArrowKmh }
        windSampled = true
    }

    /// Winds at every altitude stop for the region, fetched only once the
    /// rail leaves the surface. Every level comes in one call, so moving
    /// between stops redraws from what is already here.
    func fetchLevels(region: MKCoordinateRegion, retried: Bool = false) async {
        if Self.nearEnough(region, to: levelsFetchedFor), levels != nil { applyLevel(); return }
        let resp: FieldLevelsResponse
        do {
            resp = try await BarryAPI().fieldLevels(
                lat: region.center.latitude, lon: region.center.longitude,
                latSpan: region.span.latitudeDelta, lonSpan: region.span.longitudeDelta,
                pad: Self.windPad)
        } catch {
            if !retried { retryLater(for: region) { [weak self] in await self?.fetchLevels(region: region, retried: true) } }
            return
        }
        levels = resp
        levelsFetchedFor = region
        applyLevel()
    }

    /// Height lines for the rail's level; enrichment, so a failure (off the
    /// HRRR grid, or before the server holds a cycle) just leaves none.
    func fetchHeights(region: MKCoordinateRegion, retried: Bool = false) async {
        let level = windLevel
        guard level != 0 else { heights = nil; return }
        if let h = heights, h.hPa == level, Self.nearEnough(region, to: heightsFetchedFor) { return }
        let resp: HeightsResponse
        do {
            resp = try await BarryAPI().heights(
                lat: region.center.latitude, lon: region.center.longitude,
                latSpan: region.span.latitudeDelta, lonSpan: region.span.longitudeDelta, hPa: level)
        } catch {
            // Keep the lines already drawn for this level (a zoom that
            // failed used to clear them, and the surface isobars came back
            // under the altitude note) and try once more after a block.
            if !retried {
                retryLater(for: region) { [weak self] in await self?.fetchHeights(region: region, retried: true) }
            }
            return
        }
        guard level == windLevel else { return }
        heights = resp
        heightsFetchedFor = region
        pressureVersion += 1
    }

    private func applyLevel() {
        guard windLevel != 0, let levels else { levelField = []; return }
        levelField = levels.points.compactMap { p in
            p.levels.first { $0.hPa == windLevel }.map {
                WindArrow(lat: p.lat, lon: p.lon, speedKmh: $0.windKmh, fromDeg: $0.windDeg)
            }
        }
    }
}
