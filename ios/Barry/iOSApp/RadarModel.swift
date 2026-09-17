//  RadarModel.swift
//  Barry — iOS
//
//  State for the radar screen: RainViewer frames and playback, the model
//  wind grid, WPC fronts with their morphing timeline, the station layer and
//  the pressure field. All data comes through the Barry backend.

import Combine
import SwiftUI
import MapKit

// MARK: - Frames

struct RadarFrame: Equatable, Identifiable {
    let time: Int      // unix epoch (valid time)
    let path: String   // e.g. /v2/radar/1720100000 (RainViewer frames)
    let nowcast: Bool
    /// Set for HRRR model frames: the full IEM tile layer name
    /// ("hrrr::REFD-F0180-202607161800"). These are MODEL reflectivity — a
    /// guess about where, not a measurement — and the UI labels them so.
    var iemLayer: String? = nil
    var id: Int { time }
}

/// One wind-field sample: where, how hard, and from which direction.
struct WindArrow: Equatable {
    let lat: Double
    let lon: Double
    let speedKmh: Double
    let fromDeg: Double
}

@MainActor
final class RadarModel: ObservableObject {
    @Published var frames: [RadarFrame] = []
    @Published var host = "https://tilecache.rainviewer.com"
    @Published var index = 0
    @Published var playing = true
    @Published var failed = false
    @Published var windArrows: [WindArrow] = []
    /// The whole wind grid, calm points included — the flow layer's field.
    @Published var windField: [WindArrow] = []
    /// Reporting stations with their latest wind (barb / speed layer).
    @Published var stationObs: [StationObs] = []
    private var stationTask: Task<Void, Never>?
    private var stationsFetchedAround: CLLocationCoordinate2D?

    /// Fetch stations for a region center. The backend slices ±3° out of its
    /// in-memory METAR table (no upstream call), so this is cheap; still, only
    /// bother it after a real move (~1.5°, half the box).
    func fetchStations(center: CLLocationCoordinate2D) async {
        if let prev = stationsFetchedAround,
           abs(prev.latitude - center.latitude) < 1.5, abs(prev.longitude - center.longitude) < 1.5,
           !stationObs.isEmpty {
            return
        }
        guard let resp = try? await BarryAPI().metars(lat: center.latitude, lon: center.longitude) else { return }
        stationsFetchedAround = center
        stationObs = resp.stations
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
        lightning = LightningState(response: resp, version: lightning.version + 1)
    }

    /// Last region the map reported — used when a toggle flips on.
    var lastRegion: MKCoordinateRegion?
    private var fieldTask: Task<Void, Never>?
    private var pressureTask: Task<Void, Never>?

    /// Isobars / isallobars / shaded grids for the current region (server
    /// contours its station table; nothing upstream).
    @Published var pressureField: PressureFieldResponse?
    @Published var pressureVersion = 0

    func fetchPressureField(region: MKCoordinateRegion) async {
        guard let resp = try? await BarryAPI().pressureField(
            lat: region.center.latitude, lon: region.center.longitude,
            latSpan: region.span.latitudeDelta, lonSpan: region.span.longitudeDelta)
        else { return }
        pressureField = resp
        pressureVersion += 1
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

    // MARK: Fronts (WPC surface chart, analysis + forecast positions)

    @Published var frontFrames: [FrontFrame] = []
    /// Where on the 0...48 h front timeline we're drawing; fractional mid-glide.
    @Published var frontHours: Double = 0
    @Published var frontState: FrontRenderState = .empty
    private var frontAnimTask: Task<Void, Never>?
    private var frontVersion = 0

    func fetchFronts() async {
        guard let resp = try? await BarryAPI().fronts() else { return }
        frontFrames = resp.frames.sorted { $0.hours < $1.hours }
        frontHours = 0
        updateFrontState()
    }

    /// The drawn field for `frontHours`: an exact frame, or a morph between the
    /// two frames it sits between.
    func updateFrontState() {
        var next: FrontRenderState
        if let exact = frontFrames.first(where: { Double($0.hours) == frontHours }) {
            next = FrontMorph.state(for: exact)
        } else if let a = frontFrames.last(where: { Double($0.hours) < frontHours }),
                  let b = frontFrames.first(where: { Double($0.hours) > frontHours }) {
            let t = (frontHours - Double(a.hours)) / Double(b.hours - a.hours)
            next = FrontMorph.blend(a, b, t: t)
        } else if let edge = frontFrames.last {
            next = FrontMorph.state(for: edge)
        } else {
            next = .empty
        }
        frontVersion += 1
        next.version = frontVersion
        frontState = next
    }

    /// Glide to a valid time — the old Weather Channel move, eased, ~1.3 s.
    func animateFronts(to hours: Double, duration: Double = 1.3) {
        frontAnimTask?.cancel()
        let from = frontHours
        guard from != hours else { return }
        frontAnimTask = Task { @MainActor in
            let steps = max(1, Int(duration * 30))
            for i in 1...steps {
                guard !Task.isCancelled else { return }
                let p = Double(i) / Double(steps)
                let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
                frontHours = from + (hours - from) * eased
                updateFrontState()
                try? await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1e9))
            }
            frontHours = hours
            updateFrontState()
        }
    }

    @Published var frontPlaying = false

    /// Sweep the whole timeline from the analysis to the last prog; tapping
    /// again while it runs stops it where it is.
    func playFronts() {
        if frontPlaying {
            frontAnimTask?.cancel()
            frontPlaying = false
            return
        }
        guard let last = frontFrames.last, last.hours > 0 else { return }
        frontAnimTask?.cancel()
        frontPlaying = true
        frontAnimTask = Task { @MainActor in
            defer { frontPlaying = false }
            frontHours = 0
            updateFrontState()
            try? await Task.sleep(nanoseconds: 500_000_000)
            let total = Double(last.hours)
            let duration = 1.8 * Double(max(1, frontFrames.count - 1))
            let steps = Int(duration * 30)
            for i in 1...steps {
                guard !Task.isCancelled else { return }
                frontHours = total * Double(i) / Double(steps)
                updateFrontState()
                try? await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1e9))
            }
        }
    }

    /// Index of the most recent observed (non-forecast) frame.
    var nowIndex: Int {
        frames.lastIndex(where: { !$0.nowcast }) ?? 0
    }

    /// The timeline comes from the backend (`/radar/frames`), already trimmed
    /// to the seven observed frames plus nowcast and shared across users, so a
    /// radar open costs one small request and RainViewer sees one call every
    /// two minutes total.
    func load() async {
        failed = false
        do {
            let resp = try await BarryAPI().radarFrames()
            host = resp.host
            frames = resp.frames.map { RadarFrame(time: $0.time, path: $0.path, nowcast: $0.nowcast) }
            index = nowIndex
        } catch {
            failed = true
            return
        }
        if Self.modelFramesEnabled {
            await appendModelFrames()
        }
    }

    /// Feature flag: HRRR forecast frames on the radar timeline. OFF for now —
    /// fully built and working (backend /radar/hrrr + IEM tiles), but parked
    /// until we're ready to own the third-party tile traffic. While false the
    /// app makes ZERO requests to IEM or /radar/hrrr; flip to true to ship it.
    static let modelFramesEnabled = false

    /// Hours to extend the timeline past the nowcast with HRRR model frames.
    static let modelHours = 6

    /// Extend the timeline with hourly HRRR forecast-reflectivity frames from
    /// IEM. The backend supplies the run init time so every frame carries its
    /// TRUE valid time; if that call fails the timeline just ends at the
    /// RainViewer nowcast — model frames are enrichment, never load-bearing.
    private func appendModelFrames() async {
        guard let meta = try? await BarryAPI().hrrrRun() else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMddHHmm"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let runStamp = fmt.string(from: meta.run)
        let runEpoch = Int(meta.run.timeIntervalSince1970)

        let lastReal = frames.last?.time ?? Int(Date().timeIntervalSince1970)
        let anchor = max(lastReal, Int(Date().timeIntervalSince1970))
        // First model frame on the next full hour after the nowcast ends.
        let firstHour = (anchor / 3600 + 1) * 3600
        var model: [RadarFrame] = []
        for h in 0..<Self.modelHours {
            let valid = firstHour + h * 3600
            let fmin = (valid - runEpoch) / 60
            // HRRR hourly products run to F1080 (+18 h); both times are floored
            // to the hour so fmin is always a whole hour.
            guard fmin >= 60, fmin <= 1080 else { continue }
            let layer = String(format: "hrrr::REFD-F%04d-%@", fmin, runStamp)
            model.append(RadarFrame(time: valid, path: "", nowcast: true,
                                    iemLayer: layer))
        }
        frames += model
    }

    // MARK: Field overlays (wind)

    /// Debounced reload — pans/zooms fire this; only the last one within ~0.7 s wins.
    func scheduleFieldReload(for region: MKCoordinateRegion, wind: Bool,
                             stations: Bool = false, pressure: Bool = false,
                             storms: Bool = false) {
        lastRegion = region
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
            }
        }
        if stations {
            stationTask?.cancel()
            stationTask = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await fetchStations(center: region.center)
            }
        }
        if wind {
            fieldTask?.cancel()
            fieldTask = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await fetchField(region: region)
            }
        }
    }

    /// The model wind for the region in ONE backend call (the server samples
    /// its 7×5 grid and shares one Open-Meteo request per region cell across
    /// users).
    func fetchField(region: MKCoordinateRegion) async {
        guard let resp = try? await BarryAPI().fieldGrid(
            lat: region.center.latitude, lon: region.center.longitude,
            latSpan: region.span.latitudeDelta, lonSpan: region.span.longitudeDelta)
        else { return }   // enrichment: fail quietly and keep whatever we had
        let all = resp.points.map {
            WindArrow(lat: $0.lat, lon: $0.lon, speedKmh: $0.windKmh, fromDeg: $0.windDeg)
        }
        windField = all
        windArrows = all.filter { $0.speedKmh >= Self.minArrowKmh }
        windSampled = true
    }
}
