//  RadarView.swift
//  Barry — iOS
//
//  Lowest-angle radar sheet, Dark Sky style: a muted basemap where the rain is
//  the only saturated thing on screen, a single restrained color ramp (RainViewer's
//  "Dark Sky" scheme), the last hour of frames plus a short nowcast, and a scrubber.
//  Corroboration for the pressure trend — "here's the rain, physically, right now."
//
//  Tiles come straight from RainViewer (device → tile CDN; the Barry backend stays
//  out of the image business). Attribution required and shown in the footer.

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

/// One boundary-layer-top sample (meters AGL, from the model).
struct BLPoint: Equatable {
    let lat: Double
    let lon: Double
    let meters: Double
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
    @Published var blPoints: [BLPoint] = []
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

    /// Last region the map reported — used when a toggle flips on.
    var lastRegion: MKCoordinateRegion?
    private var fieldTask: Task<Void, Never>?

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

    func load() async {
        failed = false
        struct Maps: Decodable {
            struct Entry: Decodable { let time: Int; let path: String }
            struct Radar: Decodable { let past: [Entry]; let nowcast: [Entry] }
            let host: String
            let radar: Radar
        }
        do {
            let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let maps = try JSONDecoder().decode(Maps.self, from: data)
            host = maps.host
            let past = maps.radar.past.suffix(7)
                .map { RadarFrame(time: $0.time, path: $0.path, nowcast: false) }
            let cast = maps.radar.nowcast.prefix(3)
                .map { RadarFrame(time: $0.time, path: $0.path, nowcast: true) }
            frames = Array(past) + Array(cast)
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

    // MARK: Field overlays (wind arrows, boundary layer top)

    /// Debounced reload — pans/zooms fire this; only the last one within ~0.7 s wins.
    func scheduleFieldReload(for region: MKCoordinateRegion, wind: Bool, boundaryLayer: Bool,
                             stations: Bool = false) {
        lastRegion = region
        if stations {
            stationTask?.cancel()
            stationTask = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await fetchStations(center: region.center)
            }
        }
        if wind || boundaryLayer {
            fieldTask?.cancel()
            fieldTask = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await fetchField(region: region)
            }
        }
    }

    /// Wind and boundary-layer top for the region in ONE backend call (the
    /// server samples its 7×5 grid and shares one Open-Meteo request per
    /// region cell across users). Both layers update from the same response,
    /// so toggling either on costs nothing extra while the other is showing.
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
        blPoints = resp.points.compactMap { p in
            p.blM.map { BLPoint(lat: p.lat, lon: p.lon, meters: $0) }
        }
    }
}

// MARK: - Map (UIKit bridge)

/// MKMapView with one tile overlay per radar frame; scrubbing just flips renderer
/// alphas, so already-loaded frames replay instantly.
struct RadarMapView: UIViewRepresentable {
    let host: String
    let frames: [RadarFrame]
    let index: Int
    let center: CLLocationCoordinate2D
    var windArrows: [WindArrow] = []
    var showWind: Bool = false
    /// nil = flow layer off; otherwise the full wind grid to animate.
    var windFlow: [WindArrow]? = nil
    var blPoints: [BLPoint] = []
    var showBL: Bool = false
    /// nil = fronts layer off; otherwise the field to draw (morphs included).
    var frontState: FrontRenderState? = nil
    var stations: [StationObs] = []
    var stationStyle: StationLayerStyle = .off
    var onSelectStation: ((StationObs) -> Void)? = nil
    var onRegionChange: ((MKCoordinateRegion) -> Void)? = nil

    final class RadarTileOverlay: MKTileOverlay {
        var frameTime = 0

        /// Deepest native zoom of the tile source: RainViewer serves to z7,
        /// IEM's HRRR tiles hold up to ~z10. Beyond it we fetch the ancestor
        /// tile, crop the requested quadrant, and upscale — MapKit's maximumZ
        /// would simply stop rendering (the "radar disappears when I zoom" bug),
        /// and progressively softer rain suits the Dark Sky look anyway.
        var maxNativeZ = 7
        private static let parentCache: NSCache<NSString, NSData> = {
            let c = NSCache<NSString, NSData>()
            c.countLimit = 80
            return c
        }()

        override func loadTile(at path: MKTileOverlayPath,
                               result: @escaping (Data?, Error?) -> Void) {
            guard path.z > maxNativeZ else {
                super.loadTile(at: path, result: result)
                return
            }
            let factor = path.z - maxNativeZ
            let scale = 1 << factor
            let parentPath = MKTileOverlayPath(x: path.x / scale, y: path.y / scale,
                                               z: maxNativeZ,
                                               contentScaleFactor: path.contentScaleFactor)
            let subX = path.x % scale
            let subY = path.y % scale
            fetchCached(url(forTilePath: parentPath)) { data in
                guard let data, let cg = UIImage(data: data)?.cgImage else {
                    result(nil, nil)
                    return
                }
                let cropSide = Double(cg.width) / Double(scale)
                let rect = CGRect(x: Double(subX) * cropSide, y: Double(subY) * cropSide,
                                  width: cropSide, height: cropSide)
                guard let cropped = cg.cropping(to: rect) else {
                    result(nil, nil)
                    return
                }
                let side = 512.0
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let up = UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                                 format: format).image { _ in
                    UIImage(cgImage: cropped).draw(in: CGRect(x: 0, y: 0,
                                                              width: side, height: side))
                }
                result(up.pngData(), nil)
            }
        }

        /// Parent-tile fetch with a small in-memory cache — 4^n child tiles share
        /// one ancestor, so this collapses the request count while zoomed in.
        private func fetchCached(_ url: URL, completion: @escaping (Data?) -> Void) {
            let key = url.absoluteString as NSString
            if let hit = Self.parentCache.object(forKey: key) {
                completion(hit as Data)
                return
            }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                if let data { Self.parentCache.setObject(data as NSData, forKey: key) }
                completion(data)
            }.resume()
        }
    }

    final class WindArrowAnnotation: MKPointAnnotation {
        var speedKmh: Double = 0
        var fromDeg: Double = 0
    }

    final class BLAnnotation: MKPointAnnotation {
        var meters: Double = 0
    }

    /// A small readable height pill ("5.6k") for boundary-layer-top samples.
    final class BLLabelView: MKAnnotationView {
        private let label = UILabel()

        override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
            super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
            label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            label.textColor = .label
            label.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.72)
            label.textAlignment = .center
            label.layer.cornerRadius = 4
            label.layer.masksToBounds = true
            addSubview(label)
            isEnabled = false
            displayPriority = .defaultLow
            // Sit below the wind arrow when both layers are on.
            centerOffset = CGPoint(x: 0, y: 14)
        }

        required init?(coder: NSCoder) { fatalError("unused") }

        func set(feet: Double) {
            label.text = feet >= 1000
                ? String(format: " %.1fk ", feet / 1000)
                : " \(Int((feet / 100).rounded()) * 100) "
            label.sizeToFit()
            label.frame.size.height += 3
            label.frame.size.width += 2
            bounds = label.bounds
            label.frame = bounds
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var overlays: [Int: RadarTileOverlay] = [:]
        var renderers: [Int: MKTileOverlayRenderer] = [:]

        /// Hidden frames sit at a hair above zero instead of zero — MapKit still
        /// draws them, so every frame's tiles load and cache up front. Kills the
        /// blank pop-in on the first loop.
        static let idleAlpha: CGFloat = 0.02
        static let visibleAlpha: CGFloat = 0.75
        private static let fadeDuration: CFTimeInterval = 0.3

        private(set) var currentTime: Int = -1
        private var displayLink: CADisplayLink?
        private var fadeFrom: MKTileOverlayRenderer?
        private var fadeTo: MKTileOverlayRenderer?
        private var fadeStart: CFTimeInterval = 0

        var onRegionChange: ((MKCoordinateRegion) -> Void)?
        var onSelectStation: ((StationObs) -> Void)?

        /// A station tap opens its detail sheet; the annotation is deselected
        /// right away so the same station can be tapped again after dismissal.
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let st = view.annotation as? StationAnnotation else { return }
            mapView.deselectAnnotation(st, animated: false)
            onSelectStation?(st.obs)
        }
        var shownArrows: [WindArrow] = []
        var arrowAnnotations: [WindArrowAnnotation] = []
        var shownBL: [BLPoint] = []
        var blAnnotations: [BLAnnotation] = []
        var frontOverlay: FrontFieldOverlay?
        var frontRenderer: FrontFieldRenderer?
        var lastFrontVersion = -1
        var centerAnnotations: [PressureCenterAnnotation] = []
        var flowView: WindFlowView?
        var stationAnnotations: [StationAnnotation] = []
        var shownStations: [StationObs] = []
        var shownStationStyle: StationLayerStyle = .off

        /// Barb or speed annotations per station; rebuilt only when the set or
        /// the style changes (the style is baked into the reuse identifier).
        func syncStations(_ obs: [StationObs], style: StationLayerStyle, on map: MKMapView) {
            let want = style == .off ? [] : obs
            guard want != shownStations || style != shownStationStyle else { return }
            shownStations = want
            shownStationStyle = style
            map.removeAnnotations(stationAnnotations)
            stationAnnotations = want.map { o in
                let a = StationAnnotation()
                a.coordinate = CLLocationCoordinate2D(latitude: o.lat, longitude: o.lon)
                a.obs = o
                return a
            }
            map.addAnnotations(stationAnnotations)
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            flowView?.mapWillMove()
        }

        /// The particle layer rides on top of the map as a subview; the map
        /// tells it when it moved so it can reseed.
        func syncFlow(_ field: [WindArrow]?, on map: MKMapView) {
            guard let field else {
                flowView?.removeFromSuperview()
                flowView = nil
                return
            }
            if flowView == nil {
                let v = WindFlowView(frame: map.bounds)
                v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                v.mapView = map
                map.addSubview(v)
                flowView = v
            }
            if flowView?.samples != field {
                flowView?.samples = field
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let field = overlay as? FrontFieldOverlay {
                let r = FrontFieldRenderer(overlay: field)
                frontRenderer = r
                return r
            }
            if let tile = overlay as? RadarTileOverlay {
                let r = MKTileOverlayRenderer(tileOverlay: tile)
                r.alpha = tile.frameTime == currentTime ? Self.visibleAlpha : Self.idleAlpha
                renderers[tile.frameTime] = r
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            onRegionChange?(mapView.region)
            flowView?.mapDidMove()
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let st = annotation as? StationAnnotation {
                if shownStationStyle == .speeds {
                    let id = "stationSpeed"
                    let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? SpeedLabelView)
                        ?? SpeedLabelView(annotation: st, reuseIdentifier: id)
                    view.annotation = st
                    view.configure(st)
                    return view
                }
                let id = "stationBarb"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? WindBarbView)
                    ?? WindBarbView(annotation: st, reuseIdentifier: id)
                view.annotation = st
                view.configure(st)
                return view
            }
            if let center = annotation as? PressureCenterAnnotation {
                let id = "pressureCenter"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? PressureCenterView)
                    ?? PressureCenterView(annotation: center, reuseIdentifier: id)
                view.annotation = center
                view.configure(center)
                return view
            }
            if let bl = annotation as? BLAnnotation {
                let id = "blLabel"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? BLLabelView)
                    ?? BLLabelView(annotation: bl, reuseIdentifier: id)
                view.annotation = bl
                view.set(feet: bl.meters * 3.281)
                return view
            }
            guard let wind = annotation as? WindArrowAnnotation else {
                // The home-station pin. Explicit so it always outranks the
                // station layer in collisions instead of vanishing under a barb.
                let id = "homePin"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.displayPriority = .required
                view.collisionMode = .circle
                return view
            }
            let id = "windArrow"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKAnnotationView(annotation: wind, reuseIdentifier: id)
            view.annotation = wind
            // Light air = small and faint, a real wind = full size and dark: the
            // map reads the wind field at a glance instead of hiding half of it.
            let t = CGFloat(min(1.0, max(0.0,
                (wind.speedKmh - RadarModel.minArrowKmh)
                    / (RadarModel.fullArrowKmh - RadarModel.minArrowKmh))))
            let cfg = UIImage.SymbolConfiguration(pointSize: 9 + 7 * t, weight: .bold)
            view.image = UIImage(systemName: "arrow.up", withConfiguration: cfg)?
                .withTintColor(.label, renderingMode: .alwaysOriginal)
            // Wind FROM fromDeg blows TOWARD fromDeg+180 — point the arrow with the flow.
            view.transform = CGAffineTransform(
                rotationAngle: CGFloat((wind.fromDeg + 180) * .pi / 180))
            view.alpha = 0.3 + 0.55 * t
            view.isEnabled = false
            view.displayPriority = .defaultLow
            return view
        }

        /// Sync arrow annotations only when the set actually changed — updateUIView
        /// runs every animation tick and must not churn annotations.
        func syncArrows(_ arrows: [WindArrow], on map: MKMapView) {
            guard arrows != shownArrows else { return }
            shownArrows = arrows
            map.removeAnnotations(arrowAnnotations)
            arrowAnnotations = arrows.map { a in
                let ann = WindArrowAnnotation()
                ann.coordinate = CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon)
                ann.speedKmh = a.speedKmh
                ann.fromDeg = a.fromDeg
                return ann
            }
            map.addAnnotations(arrowAnnotations)
        }

        /// Same equality-guarded sync for the boundary-layer labels.
        func syncBL(_ points: [BLPoint], on map: MKMapView) {
            guard points != shownBL else { return }
            shownBL = points
            map.removeAnnotations(blAnnotations)
            blAnnotations = points.map { p in
                let ann = BLAnnotation()
                ann.coordinate = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
                ann.meters = p.meters
                return ann
            }
            map.addAnnotations(blAnnotations)
        }

        /// The fronts layer: one world-sized overlay whose renderer reads a state
        /// struct, so a morph tick is "swap state, redraw" — no overlay churn.
        /// Pressure centers are annotations, moved in place while animating.
        func syncFronts(_ state: FrontRenderState?, on map: MKMapView) {
            guard let state else {
                if let o = frontOverlay {
                    map.removeOverlay(o)
                    frontOverlay = nil
                    frontRenderer = nil
                }
                map.removeAnnotations(centerAnnotations)
                centerAnnotations = []
                lastFrontVersion = -1
                return
            }
            if frontOverlay == nil {
                let o = FrontFieldOverlay()
                frontOverlay = o
                map.addOverlay(o, level: .aboveLabels)
            }
            guard state.version != lastFrontVersion else { return }
            lastFrontVersion = state.version
            frontOverlay?.state = state
            frontRenderer?.setNeedsDisplay()

            if centerAnnotations.count == state.centers.count {
                for (ann, c) in zip(centerAnnotations, state.centers) {
                    ann.coordinate = CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)
                    ann.isHigh = c.isHigh
                    ann.pressure = c.pressure
                    ann.alpha = c.alpha
                    (map.view(for: ann) as? PressureCenterView)?.configure(ann)
                }
            } else {
                map.removeAnnotations(centerAnnotations)
                centerAnnotations = state.centers.map { c in
                    let ann = PressureCenterAnnotation()
                    ann.coordinate = CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)
                    ann.isHigh = c.isHigh
                    ann.pressure = c.pressure
                    ann.alpha = c.alpha
                    return ann
                }
                map.addAnnotations(centerAnnotations)
            }
        }

        /// Crossfade to a new frame (~0.3 s) instead of hard-cutting — most of the
        /// perceived Dark Sky smoothness for a fraction of frame interpolation.
        func setCurrent(_ time: Int) {
            guard time != currentTime else { return }
            let old = renderers[currentTime]
            currentTime = time
            displayLink?.invalidate()
            displayLink = nil
            // Park everything that isn't part of this transition.
            for (t, r) in renderers where t != time && r !== old {
                r.alpha = Self.idleAlpha
            }
            guard let new = renderers[time] else {
                old?.alpha = Self.idleAlpha
                return
            }
            fadeFrom = old
            fadeTo = new
            fadeStart = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(stepFade))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func stepFade() {
            let p = CGFloat(min(1, (CACurrentMediaTime() - fadeStart) / Self.fadeDuration))
            fadeTo?.alpha = Self.idleAlpha + (Self.visibleAlpha - Self.idleAlpha) * p
            fadeFrom?.alpha = Self.visibleAlpha - (Self.visibleAlpha - Self.idleAlpha) * p
            if p >= 1 {
                displayLink?.invalidate()
                displayLink = nil
                fadeFrom = nil
                fadeTo = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        // Dark Sky rule: mute everything that isn't rain.
        let cfg = MKStandardMapConfiguration(emphasisStyle: .muted)
        cfg.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = cfg
        map.showsCompass = false
        map.region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 3.2, longitudeDelta: 3.2))
        // Radar detail tops out at tile z7 (crop-upscaled beyond) — allow a closer
        // look than before, but stop before the upscale turns to meaningless mush.
        map.cameraZoomRange = MKMapView.CameraZoomRange(
            minCenterCoordinateDistance: 60_000)
        let pin = MKPointAnnotation()
        pin.coordinate = center
        map.addAnnotation(pin)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Lazily add an overlay per frame (RainViewer "Dark Sky" scheme = color 8;
        // options 1_1 = smoothed + snow shown distinctly). Past RainViewer's native
        // z7 the overlay itself crops + upscales ancestor tiles (see loadTile) —
        // do NOT set maximumZ, which would stop rendering entirely past z7.
        for f in frames where context.coordinator.overlays[f.time] == nil {
            let tile: RadarTileOverlay
            if let layer = f.iemLayer {
                // HRRR model frames: IEM TMS tiles, 256 px, native to ~z10.
                tile = RadarTileOverlay(urlTemplate:
                    "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/\(layer)/{z}/{x}/{y}.png")
                tile.maxNativeZ = 10
                tile.tileSize = CGSize(width: 256, height: 256)
            } else {
                tile = RadarTileOverlay(urlTemplate:
                    host + f.path + "/512/{z}/{x}/{y}/8/1_1.png")
                tile.tileSize = CGSize(width: 512, height: 512)
            }
            tile.frameTime = f.time
            tile.canReplaceMapContent = false
            tile.minimumZ = 1
            context.coordinator.overlays[f.time] = tile
            map.addOverlay(tile, level: .aboveRoads)
        }
        context.coordinator.onRegionChange = onRegionChange
        context.coordinator.onSelectStation = onSelectStation
        context.coordinator.syncArrows(showWind ? windArrows : [], on: map)
        context.coordinator.syncBL(showBL ? blPoints : [], on: map)
        context.coordinator.syncFronts(frontState, on: map)
        context.coordinator.syncFlow(windFlow, on: map)
        context.coordinator.syncStations(stations, style: stationStyle, on: map)

        guard frames.indices.contains(index) else { return }
        context.coordinator.setCurrent(frames[index].time)
    }
}

// MARK: - Screen

/// The radar as its own screen (pushed, with a real Back button): the map fills
/// the view and the controls float over it. The iPad dashboard embeds RadarPanel
/// directly in compact form and pushes this for the full experience.
struct RadarScreen: View {
    let lat: Double
    let lon: Double
    let stationName: String

    var body: some View {
        RadarPanel(lat: lat, lon: lon, stationName: stationName)
            .navigationTitle("Radar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

struct RadarPanel: View {
    let lat: Double
    let lon: Double
    let stationName: String
    /// When set, an expand button overlays the map (dashboard embeds use it to
    /// pop the radar to full screen).
    var onExpand: (() -> Void)? = nil
    /// Dashboard embeds run chrome-light: the toggles compress to one button
    /// row and the attribution paragraph stays in the full-screen view, so the
    /// MAP gets the panel's height instead of its own controls (in landscape
    /// the full chrome squeezed the map to a sliver).
    var embedded: Bool = false

    @StateObject private var model = RadarModel()
    @State private var dwellTicks = 0
    @AppStorage("radarWindArrows", store: AppConfig.sharedDefaults)
    private var showWindArrows: Bool = true
    @AppStorage("radarBoundaryLayer", store: AppConfig.sharedDefaults)
    private var showBoundaryLayer: Bool = false
    @AppStorage("radarFronts", store: AppConfig.sharedDefaults)
    private var showFronts: Bool = true
    /// "flow" (animated streaks, the default) or "arrows" (the static grid).
    @AppStorage("radarWindStyle", store: AppConfig.sharedDefaults)
    private var windStyle: String = "flow"
    /// Station layer: "off", "barbs" (METAR wind flags) or "speeds" (labels).
    @AppStorage("radarStations", store: AppConfig.sharedDefaults)
    private var stationStyleRaw: String = "off"
    @State private var showLayers = false
    @State private var selectedStation: StationObs?
    private let ticker = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()

    private var stationStyle: StationLayerStyle { StationLayerStyle(rawValue: stationStyleRaw) ?? .off }

    private var initialRegion: MKCoordinateRegion {
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                           span: MKCoordinateSpan(latitudeDelta: 3.2, longitudeDelta: 3.2))
    }

    var body: some View {
        Group {
            if model.failed {
                VStack(spacing: 10) {
                    Text("Couldn't load radar. Check your connection.")
                        .foregroundStyle(.secondary)
                    Button("Try again") { Task { await model.load() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.frames.isEmpty {
                ProgressView("Loading radar…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .task {
            await model.load()
            if showWindArrows || showBoundaryLayer {
                await model.fetchField(region: model.lastRegion ?? initialRegion)
            }
            if showFronts {
                await model.fetchFronts()
            }
            if stationStyle != .off {
                await model.fetchStations(center: initialRegion.center)
            }
        }
        .onReceive(ticker) { _ in
            guard model.playing, !model.frames.isEmpty else { return }
            // Dwell at the end of the loop (the freshest picture) before
            // restarting — the Dark Sky rhythm, and it reads far calmer.
            if dwellTicks > 0 {
                dwellTicks -= 1
                return
            }
            model.index = (model.index + 1) % model.frames.count
            if model.index == model.frames.count - 1 {
                dwellTicks = 3
            }
        }
    }

    @ViewBuilder private var content: some View {
        Group {
            if embedded {
                embeddedContent
            } else {
                fullScreenContent
            }
        }
        .sheet(item: $selectedStation) { st in
            StationDetailSheet(obs: st, now: Date())
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: stationStyleRaw) { _, raw in
            if raw != "off" {
                Task { await model.fetchStations(center: model.lastRegion?.center ?? initialRegion.center) }
            }
        }
        .onChange(of: showFronts) { _, on in
            if on, model.frontFrames.isEmpty {
                Task { await model.fetchFronts() }
            }
        }
        // Fetch triggers live on the container so the compact and full toggle
        // variants share them.
        .onChange(of: showWindArrows) { _, on in
            if on {
                Task { await model.fetchField(region: model.lastRegion ?? initialRegion) }
            }
        }
        .onChange(of: showBoundaryLayer) { _, on in
            if on {
                Task { await model.fetchField(region: model.lastRegion ?? initialRegion) }
            }
        }
    }

    /// The map itself, shared by both layouts.
    private var mapView: some View {
        RadarMapView(host: model.host,
                     frames: model.frames,
                     index: model.index,
                     center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                     windArrows: model.windArrows,
                     showWind: showWindArrows && windStyle == "arrows",
                     windFlow: (showWindArrows && windStyle == "flow") ? model.windField : nil,
                     blPoints: model.blPoints,
                     showBL: showBoundaryLayer,
                     frontState: showFronts ? model.frontState : nil,
                     stations: model.stationObs,
                     stationStyle: stationStyle,
                     onSelectStation: { selectedStation = $0 },
                     onRegionChange: { region in
                         model.scheduleFieldReload(for: region,
                                                   wind: showWindArrows,
                                                   boundaryLayer: showBoundaryLayer,
                                                   stations: stationStyle != .off)
                     })
    }

    /// Full screen: the map fills the view; the scrubber and front chips float
    /// in a card at the bottom, the layer toggles hide behind a Layers button.
    private var fullScreenContent: some View {
        GeometryReader { geo in
        ZStack(alignment: .bottom) {
            mapView
                .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Spacer()
                    // Leave room for the bottom card and the front key on
                    // short phones; the panel scrolls inside that.
                    layersColumn(maxPanelHeight: max(220, geo.size.height - 250))
                }
                .padding(12)

                Spacer(minLength: 0)

                if showFronts, !model.frontFrames.isEmpty {
                    HStack(alignment: .bottom) {
                        FrontKeyView(validText: frontValidText, compact: true)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }

                bottomCard
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        }
    }

    /// The Layers button and, when open, the panel beneath it.
    private func layersColumn(maxPanelHeight: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { showLayers.toggle() }
            } label: {
                Image(systemName: showLayers ? "xmark" : "square.3.layers.3d")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .padding(10)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showLayers ? "Hide layers" : "Layers")

            if showLayers {
                ScrollView(showsIndicators: false) {
                    layersPanel
                }
                .frame(width: 290)
                .frame(maxHeight: maxPanelHeight)
                .fixedSize(horizontal: false, vertical: true)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
            }
        }
    }

    private var layersPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $showWindArrows) {
                Label("Wind", systemImage: "wind")
            }
            if showWindArrows {
                Picker("Wind style", selection: $windStyle) {
                    Text("Flow").tag("flow")
                    Text("Arrows").tag("arrows")
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
            windCalmNote

            Toggle(isOn: $showBoundaryLayer) {
                Label("Boundary layer top", systemImage: "cloud.fog")
            }
            if showBoundaryLayer {
                Text("Model boundary layer top in feet above ground. Bumpy, hazy air mixes below it, smoother air above.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Toggle(isOn: $showFronts) {
                Label("Fronts", systemImage: "line.diagonal")
            }

            Label("Stations", systemImage: "mappin.and.ellipse")
            Picker("Stations", selection: $stationStyleRaw) {
                Text("Off").tag("off")
                Text("Barbs").tag("barbs")
                Text("Speeds").tag("speeds")
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            if stationStyle != .off {
                HStack(spacing: 10) {
                    ForEach(FlightCategory.order, id: \.self) { cat in
                        HStack(spacing: 3) {
                            Circle().fill(FlightCategory.color(cat)).frame(width: 7, height: 7)
                            Text(cat)
                        }
                    }
                    Spacer()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Divider()
            legend
        }
        .font(.subheadline)
        .padding(12)
    }

    /// The things you actually touch: radar scrubber, front chips, and the
    /// one-line attribution that must stay on screen.
    private var bottomCard: some View {
        VStack(spacing: 8) {
            controls
            if showFronts, model.frontFrames.count > 1 {
                frontTimeline
            }
            Text("Radar RainViewer · NOAA NEXRAD · Wind Open-Meteo · Fronts NWS WPC")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The iPad dashboard embed: map in a rounded card, compact controls below.
    private var embeddedContent: some View {
        VStack(spacing: 10) {
            mapView
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomLeading) {
                    if showFronts, !model.frontFrames.isEmpty {
                        FrontKeyView(validText: frontValidText, compact: true)
                            .padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let onExpand {
                        Button(action: onExpand) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 14, weight: .semibold))
                                .padding(9)
                                .background(.thinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .accessibilityLabel("Expand radar")
                    }
                }

            controls

            if showFronts, model.frontFrames.count > 1 {
                frontTimeline
            }

            // Two short rows — one row of buttons + swatches doesn't fit the
            // portrait column and SwiftUI "fixes" that by wrapping the button
            // titles mid-word.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    compactToggle("Wind", icon: "wind", isOn: $showWindArrows)
                    compactToggle("Layer top", icon: "cloud.fog", isOn: $showBoundaryLayer)
                    compactToggle("Fronts", icon: "line.diagonal", isOn: $showFronts)
                    compactToggle("Barbs", icon: "flag", isOn: Binding(
                        get: { stationStyleRaw == "barbs" },
                        set: { stationStyleRaw = $0 ? "barbs" : "off" }))
                    Spacer()
                }
                windCalmNote
                HStack(spacing: 14) {
                    swatch(Color(red: 0.55, green: 0.75, blue: 0.95), "Light")
                    swatch(Color(red: 0.13, green: 0.42, blue: 0.82), "Moderate")
                    swatch(Color(red: 0.94, green: 0.65, blue: 0.15), "Heavy")
                    Spacer()
                }
            }
        }
    }

    /// Now / +12h / +24h ... chips plus a play button. Tapping a chip glides the
    /// field there; play sweeps the whole timeline.
    private var frontTimeline: some View {
        HStack(spacing: 8) {
            Button { model.playFronts() } label: {
                Image(systemName: model.frontPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.frontPlaying ? "Stop front movement" : "Play front movement")

            ForEach(model.frontFrames) { frame in
                let selected = abs(model.frontHours - Double(frame.hours)) < 0.5
                Button(frame.hours == 0 ? "Now" : "+\(frame.hours)h") {
                    model.animateFronts(to: Double(frame.hours))
                }
                .font(.caption.weight(selected ? .semibold : .regular))
                .buttonStyle(.bordered)
                .tint(selected ? .accentColor : .secondary)
                .controlSize(.small)
            }
            Spacer()
            Text(frontChipTime)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// Local valid time of the frame nearest the current front position.
    private var frontChipTime: String {
        guard let f = model.frontFrames.min(by: {
            abs(Double($0.hours) - model.frontHours) < abs(Double($1.hours) - model.frontHours)
        }) else { return "" }
        return f.valid.formatted(.dateTime.weekday(.abbreviated).hour())
    }

    private var frontValidText: String {
        "WPC fronts, \(frontChipTime), to about 50 mi"
    }

    /// A toggled-on layer that draws nothing must say why, or it reads as broken.
    @ViewBuilder private var windCalmNote: some View {
        if showWindArrows, model.windSampled, model.windArrows.isEmpty {
            Text("Winds under 3 kt across the map right now, so there are no arrows to draw.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func compactToggle(_ title: String, icon: String,
                               isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: icon)
                .font(.caption)
                .lineLimit(1)
                .fixedSize()  // never wrap the title mid-word under compression
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                model.playing.toggle()
            } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(.plain)

            Slider(
                value: Binding(
                    get: { Double(model.index) },
                    set: { model.index = Int($0.rounded()); model.playing = false }
                ),
                in: 0...Double(max(1, model.frames.count - 1)),
                step: 1
            )

            Text(timeLabel)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(timeLabelColor)
                .frame(width: 84, alignment: .trailing)
        }
    }

    private var currentFrame: RadarFrame? {
        model.frames.indices.contains(model.index) ? model.frames[model.index] : nil
    }

    /// Purple = model reflectivity, orange = short nowcast, gray = observed —
    /// three sources, three colors, no ambiguity about what you're looking at.
    private var timeLabelColor: Color {
        guard let f = currentFrame else { return .secondary }
        if f.iemLayer != nil { return .purple }
        return f.nowcast ? .orange : .secondary
    }

    private var timeLabel: String {
        guard let f = currentFrame else { return "" }
        if f.iemLayer != nil {
            let hrs = max(1, Int(((Double(f.time) - Date().timeIntervalSince1970) / 3600).rounded()))
            return "+\(hrs)h model"
        }
        let mins = Int((Date().timeIntervalSince1970 - Double(f.time)) / 60)
        if f.nowcast { return "+\(max(0, -mins))m forecast" }
        return mins <= 1 ? "now" : "\(mins)m ago"
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                swatch(Color(red: 0.55, green: 0.75, blue: 0.95), "Light")
                swatch(Color(red: 0.13, green: 0.42, blue: 0.82), "Moderate")
                swatch(Color(red: 0.94, green: 0.65, blue: 0.15), "Heavy")
                Spacer()
            }
            Text(footerText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// The nowcast/model sentences track the model-frames flag so the footer
    /// never describes frames that can't appear.
    private var footerText: String {
        var text = "Wind streaks and arrows are the Open-Meteo model wind; stations are real METAR reports in knots. "
        if RadarModel.modelFramesEnabled {
            text += "Purple frames are HRRR model reflectivity via Iowa Environmental Mesonet, a guess, not a measurement. "
        }
        text += "Radar by RainViewer from NOAA NEXRAD. Fronts from the NWS Weather Prediction Center, positions good to about 50 miles."
        return text
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 14, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
