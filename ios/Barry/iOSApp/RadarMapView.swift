//  RadarMapView.swift
//  Barry — iOS
//
//  The MapKit bridge: tile overlays for radar frames, the front-field
//  overlay, the pressure field, wind arrows, station barbs/speeds, storm
//  bolts, and the particle flow subview. The coordinator owns the diffing so
//  SwiftUI updates only add or remove what changed.

import SwiftUI
import MapKit

// MARK: - Map (UIKit bridge)

/// What the map draws the fronts and the isobars from while a loop plays:
/// the loop's clock (nil when it is not running) and each layer at a moment
/// on it (nil when that layer is off or has nothing for the moment). The map
/// asks thirty times a second, so the lines glide between the charts and
/// the hours instead of stepping once a radar frame.
struct RadarLineSource {
    let clock: () -> Double?
    let fronts: (Double) -> FrontRenderState?
    let pressure: (Double) -> PressureFieldResponse?
    /// False when `pressure` gives the field's shape, not its values.
    var labelIsobars = true
    /// Set when the isobars are the field's shape and the GPU is drawing
    /// them (IsolineView): `pressure` then carries no lines, only the grid
    /// for the shading when that is on.
    var shape: PressureTimeline? = nil
}

/// A loop waiting to play: the frames it needs and what to call when they
/// are loaded for the view on screen (or the wait has run out). `id` names
/// the request; the map acts on each id once.
struct RadarBufferRequest {
    let id: Int
    let keys: Set<Int>
    let ready: (Int) -> Void
}

/// MKMapView with one tile overlay per radar frame; scrubbing just flips renderer
/// alphas, so already-loaded frames replay instantly.
struct RadarMapView: UIViewRepresentable {
    let host: String
    let frames: [RadarFrame]
    /// The frames the loop plays, in order.
    var loopKeys: [Int] = []
    /// Set while a loop plays and fronts or isobars are showing.
    var lines: RadarLineSource? = nil
    /// Set while a loop is waiting for its frames to load.
    var buffer: RadarBufferRequest? = nil
    let index: Int
    /// False when another base layer (pressure, change) replaces the radar:
    /// the tiles stay loaded but draw at zero alpha.
    var radarVisible: Bool = true
    let center: CLLocationCoordinate2D
    var windArrows: [WindArrow] = []
    var showWind: Bool = false
    /// nil = flow layer off; otherwise the full wind grid to animate.
    var windFlow: [WindArrow]? = nil
    /// Full strength on the streak ramp: higher for winds aloft.
    var windRampKmh: Double = 35
    /// The dashboard card scrolls with the page; the full screen map does not.
    var embedded: Bool = false
    /// False when the card is scrolled off screen: stop animating for nobody.
    var animating: Bool = true
    /// nil = fronts layer off; otherwise the field to draw (morphs included).
    var frontState: FrontRenderState? = nil
    var stations: [StationObs] = []
    var stationStyle: StationLayerStyle = .off
    /// Bolts at stations reporting lightning. With the station layer on the
    /// barbs carry the bolt themselves; this adds standalone markers otherwise.
    /// Also dims the radar a notch so the strike dots read over the rain.
    var showStorms: Bool = false
    /// GLM flash cells for the Storms overlay; nil draws nothing.
    var lightning: LightningState? = nil
    /// Tiles of the chance of lightning in the next hour, under the flashes.
    var lightningNextTemplate: String? = nil
    var advisories: AdvisoriesResponse? = nil
    var onSelectAdvisory: ((AdvisoryDetailSheet.Item) -> Void)? = nil
    var onSelectStation: ((StationObs) -> Void)? = nil
    /// nil: the red pin marks the station and the map shows the user's own
    /// blue dot. Otherwise the home station is drawn as itself (see HomeMarker).
    var home: HomeMarker? = nil
    /// nil hides the pressure layer entirely.
    var pressureState: PressureFieldState? = nil
    /// Bumped by the recenter button: glide back to the home station at
    /// the opening zoom.
    var recenterToken: Int = 0
    var onRegionChange: ((MKCoordinateRegion) -> Void)? = nil

    final class RadarTileOverlay: MKTileOverlay {
        var frameTime = 0
        /// RainViewer tiles are read back to dBZ and repainted in Barry's
        /// palette (RadarPalette); model tiles from IEM are shown as served.
        var recolor = false
        /// Sized in bytes, not tiles: seven frames of one screen is well over a
        /// hundred tiles, and a count limit that small meant a pan evicted and
        /// repainted what a pan back was about to need.
        private static let recoloredCache: NSCache<NSString, NSData> = {
            let c = NSCache<NSString, NSData>()
            c.totalCostLimit = 48 << 20
            return c
        }()

        /// Deepest native zoom of the tile source: RainViewer serves to z7,
        /// IEM's HRRR tiles hold up to ~z10. Beyond it we fetch the ancestor
        /// tile, crop the requested quadrant, and upscale — MapKit's maximumZ
        /// would simply stop rendering (the "radar disappears when I zoom" bug),
        /// and progressively softer rain suits the Dark Sky look anyway.
        var maxNativeZ = 7
        private static let parentCache: NSCache<NSString, NSData> = {
            let c = NSCache<NSString, NSData>()
            c.totalCostLimit = 24 << 20
            return c
        }()

        /// Host and frame path, for `url(forTilePath:)`.
        var base: String?
        /// Zoomed out past the source's native zoom, a tile is asked for at
        /// half size and drawn over the same ground: a quarter of the
        /// pixels to download, repaint (6 ms a tile down to 2) and hold on
        /// the GPU, for a frame that at that zoom is many storms to the
        /// inch. The server draws either size from the copy of the frame
        /// that keeps the strongest echo in each block, so nothing drops out.
        static let wideTilePx = 256

        override func url(forTilePath path: MKTileOverlayPath) -> URL {
            guard let base, path.z < maxNativeZ,
                  let u = URL(string: "\(base)/\(Self.wideTilePx)/\(path.z)/\(path.x)/\(path.y)/2/0_1.png")
            else { return super.url(forTilePath: path) }
            return u
        }

        /// Tile loads MapKit has asked this frame for and not had back yet.
        private let loads = Locked(0)
        var loadsInFlight: Int { loads.value }

        override func loadTile(at path: MKTileOverlayPath,
                               result finish: @escaping (Data?, Error?) -> Void) {
            loads.withLock { $0 += 1 }
            let result: (Data?, Error?) -> Void = { [loads] data, error in
                loads.withLock { $0 -= 1 }
                finish(data, error)
            }
            guard path.z > maxNativeZ else {
                if recolor {
                    fetchCached(url(forTilePath: path)) { data in
                        guard let data else { result(nil, nil); return }
                        result(self.painted(data, key: self.url(forTilePath: path).absoluteString), nil)
                    }
                } else {
                    super.loadTile(at: path, result: result)
                }
                return
            }
            let factor = path.z - maxNativeZ
            let scale = 1 << factor
            let parentPath = MKTileOverlayPath(x: path.x / scale, y: path.y / scale,
                                               z: maxNativeZ,
                                               contentScaleFactor: path.contentScaleFactor)
            let subX = path.x % scale
            let subY = path.y % scale
            let parentURL = url(forTilePath: parentPath)
            fetchCached(parentURL) { raw in
                let data = raw.map { self.recolor ? self.painted($0, key: parentURL.absoluteString) : $0 }
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

        /// Repainted bytes for a source tile, cached so the crop-and-upscale
        /// path and neighbouring zooms never repaint the same tile twice.
        private func painted(_ data: Data, key: String) -> Data {
            let k = ("painted:" + key) as NSString
            if let hit = Self.recoloredCache.object(forKey: k) { return hit as Data }
            let out = RadarPalette.recolor(data)
            Self.recoloredCache.setObject(out as NSData, forKey: k, cost: out.count)
            return out
        }

        /// Parent-tile fetch with a small in-memory cache — 4^n child tiles share
        /// one ancestor, so this collapses the request count while zoomed in.
        /// Requests in flight, keyed by URL, with everyone waiting on each.
        /// MapKit asks for four children of one ancestor at once past the
        /// native zoom, and a prefetch ring resolves to a handful of ancestors,
        /// so without this the same bytes were fetched many times over.
        private static let inflightLock = NSLock()
        private static var inflight: [NSString: [(Data?) -> Void]] = [:]

        /// Only a PNG is a tile. Cloudflare answers a burst over the zone's
        /// rate rule with a 429 and a text body, and on 2026-09-25 the radar
        /// drew blank after a zoom out because every tile of every frame
        /// was one of those, cached here as if it were a picture and handed
        /// to MapKit, which could not decode it. Anything that is not a PNG
        /// is a miss and is never cached; a 429 or 503 pauses every fetch
        /// for the Retry-After (ten seconds at Cloudflare) so the burst does
        /// not extend the block, and the map reloads its tiles once it lifts.
        private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])
        private static var blockedUntil = Date.distantPast
        private static let blockLock = NSLock()
        /// Told the wait, once per block, so the renderers can reload after it.
        static var onBlocked: ((TimeInterval) -> Void)?

        private static func isBlocked() -> Bool {
            blockLock.lock(); defer { blockLock.unlock() }
            return blockedUntil > Date()
        }

        private static func block(for seconds: TimeInterval) {
            blockLock.lock()
            let fresh = blockedUntil <= Date()
            blockedUntil = max(blockedUntil, Date().addingTimeInterval(seconds))
            blockLock.unlock()
            if fresh { onBlocked?(seconds) }
        }

        private func fetchCached(_ url: URL, completion: @escaping (Data?) -> Void) {
            let key = url.absoluteString as NSString
            if let hit = Self.parentCache.object(forKey: key) {
                completion(hit as Data)
                return
            }
            if Self.isBlocked() {
                completion(nil)
                return
            }
            Self.inflightLock.lock()
            if Self.inflight[key] != nil {
                Self.inflight[key]!.append(completion)
                Self.inflightLock.unlock()
                return
            }
            Self.inflight[key] = [completion]
            Self.inflightLock.unlock()
            URLSession.shared.dataTask(with: url) { data, response, _ in
                let http = response as? HTTPURLResponse
                var tile: Data? = nil
                if http?.statusCode == 200, let data, data.starts(with: Self.pngSignature) {
                    tile = data
                    Self.parentCache.setObject(data as NSData, forKey: key, cost: data.count)
                } else if let status = http?.statusCode, status == 429 || status == 503 {
                    let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 10
                    Self.block(for: min(max(retry, 2), 60))
                }
                Self.inflightLock.lock()
                let waiters = Self.inflight.removeValue(forKey: key) ?? []
                Self.inflightLock.unlock()
                for w in waiters { w(tile) }
            }.resume()
        }

        // ---- 4. prefetch ---------------------------------------------------

        /// Warm both caches for a tile without handing anything to MapKit, so
        /// the next small pan finds its edge already there. Past the native
        /// zoom this resolves to the ancestor tile, which is what loadTile
        /// would crop from anyway.
        /// `done` is called once the tile is in the caches or has failed,
        /// on whatever thread that happens on: what the loop's buffering
        /// counts down (Coordinator.syncBuffer).
        func prefetch(_ path: MKTileOverlayPath, done: (() -> Void)? = nil) {
            let z = min(path.z, maxNativeZ)
            let scale = 1 << max(0, path.z - z)
            let src = MKTileOverlayPath(x: path.x / scale, y: path.y / scale, z: z,
                                        contentScaleFactor: path.contentScaleFactor)
            let u = url(forTilePath: src)
            let key = u.absoluteString
            // Already repainted: nothing to warm.
            if recolor, Self.recoloredCache.object(forKey: ("painted:" + key) as NSString) != nil {
                done?()
                return
            }
            fetchCached(u) { [weak self] data in
                guard let self, let data, self.recolor else { done?(); return }
                // A cache hit calls back synchronously on the caller's thread,
                // which for a prefetch is main. Repainting is a quarter of a
                // million pixels; keep it off the main thread regardless.
                DispatchQueue.global(qos: .utility).async {
                    _ = self.painted(data, key: key)
                    done?()
                }
            }
        }
    }

    final class WindArrowAnnotation: MKPointAnnotation {
        var speedKmh: Double = 0
        var fromDeg: Double = 0
    }

    /// One arrow of the Arrows wind style with its speed under it, in the
    /// wind unit from Settings ("20 kts"). The arrow turns with the wind;
    /// the number stays upright. Light air is small and faint, a real wind
    /// full size and dark, so the field reads at a glance.
    final class WindArrowView: MKAnnotationView {
        private let arrow = UIImageView()
        private let speed = UILabel()
        private static let arrowCentreY: CGFloat = 12

        override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
            super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
            bounds = CGRect(x: 0, y: 0, width: 48, height: 36)
            centerOffset = CGPoint(x: 0, y: bounds.height / 2 - Self.arrowCentreY)
            arrow.contentMode = .center
            arrow.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
            arrow.center = CGPoint(x: bounds.midX, y: Self.arrowCentreY)
            speed.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
            speed.textColor = .label
            speed.textAlignment = .center
            speed.frame = CGRect(x: 0, y: 23, width: bounds.width, height: 12)
            // A faint halo so the number reads over roads and water.
            speed.layer.shadowColor = UIColor.systemBackground.cgColor
            speed.layer.shadowOpacity = 0.9
            speed.layer.shadowRadius = 1.5
            speed.layer.shadowOffset = .zero
            addSubview(arrow)
            addSubview(speed)
            isEnabled = false
            displayPriority = .defaultLow
        }

        required init?(coder: NSCoder) { fatalError("unused") }

        func configure(speedKmh: Double, fromDeg: Double, unit: WindUnit) {
            let t = CGFloat(min(1.0, max(0.0,
                (speedKmh - RadarModel.minArrowKmh) / (RadarModel.fullArrowKmh - RadarModel.minArrowKmh))))
            let cfg = UIImage.SymbolConfiguration(pointSize: 9 + 7 * t, weight: .bold)
            arrow.image = UIImage(systemName: "arrow.up", withConfiguration: cfg)?
                .withTintColor(.label, renderingMode: .alwaysOriginal)
            // Wind FROM fromDeg blows TOWARD fromDeg+180: point the arrow with the flow.
            arrow.transform = CGAffineTransform(rotationAngle: CGFloat((fromDeg + 180) * .pi / 180))
            speed.text = "\(unit.format(speedKmh)) \(unit.label)"
            alpha = 0.3 + 0.55 * t
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var overlays: [Int: RadarTileOverlay] = [:]
        var renderers: [Int: MKTileOverlayRenderer] = [:]

        /// Every live map, so a rate-limit block lifting reloads all of
        /// them (the iPad dashboard and the full screen can both be up).
        private static let live = NSHashTable<Coordinator>.weakObjects()

        override init() {
            super.init()
            Self.live.add(self)
            RadarTileOverlay.onBlocked = { wait in
                DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.5) {
                    for c in Self.live.allObjects { c.reloadTiles() }
                }
            }
        }

        /// Ask MapKit for the tiles again, after a block on fetching them.
        func reloadTiles() {
            for r in renderers.values { r.reloadData() }
        }

        /// Hidden frames sit at a hair above zero instead of zero — MapKit still
        /// draws them, so every frame's tiles load and cache up front. Kills the
        /// blank pop-in on the first loop.
        static let idleAlpha: CGFloat = 0.02
        static let fullAlpha: CGFloat = 0.75
        /// A notch lower while the lightning layer is on: the strike dots
        /// need contrast more than the rain needs its last 20% of ink.
        static let dimmedAlpha: CGFloat = 0.55
        private(set) var visibleAlpha: CGFloat = 0.75
        private static let fadeDuration: CFTimeInterval = 0.3

        func setRadarDimmed(_ dimmed: Bool) {
            let target = dimmed ? Self.dimmedAlpha : Self.fullAlpha
            guard target != visibleAlpha else { return }
            visibleAlpha = target
            if !radarHidden, displayLink == nil, let r = renderers[currentTime] { r.alpha = target }
        }

        /// The span's frames in timeline order, and the loop's. Only the
        /// frames about to be shown sit a hair above zero (`near`); the rest
        /// are at true zero, where MapKit neither fetches nor draws them.
        ///
        /// Until 2026-10-02 every frame of the span sat at 0.02 so its
        /// tiles stayed loaded. That was ten layers when the timeline was
        /// an hour; with the six-hour span it was thirty, each blended over
        /// the whole screen on every refresh, and Xcode showed 14 fps. The
        /// tiles are kept warm in the app's own caches instead
        /// (`syncBuffer`, `prefetchFrames`), so a frame coming up reads
        /// them back in a blink.
        private var order: [Int] = []
        private var loopOrder: [Int] = []
        private var near: Set<Int> = []

        /// The alpha a frame that is not on screen rests at.
        private func idle(_ key: Int) -> CGFloat {
            !panning && near.contains(key) ? Self.idleAlpha : 0
        }

        /// The next two frames the loop will show after `key` (going round
        /// from its end to its start), and the frame either side of it on
        /// the slider for a scrub.
        static func framesNear(_ key: Int, order: [Int], loop: [Int]) -> Set<Int> {
            var out: Set<Int> = []
            if let i = loop.firstIndex(of: key), loop.count > 1 {
                out.insert(loop[(i + 1) % loop.count])
                out.insert(loop[(i + 2) % loop.count])
            }
            if let i = order.firstIndex(of: key) {
                if i > 0 { out.insert(order[i - 1]) }
                if i + 1 < order.count { out.insert(order[i + 1]) }
            }
            out.remove(key)
            return out
        }

        /// Set the span's frames and its loop's, both in timeline order.
        func setFrames(_ keys: [Int], loop: [Int]) {
            guard keys != order || loop != loopOrder else { return }
            order = keys
            loopOrder = loop
            refreshNear()
        }

        private func refreshNear() {
            near = Self.framesNear(currentTime, order: order, loop: loopOrder)
            guard !radarHidden else { return }
            for (t, r) in renderers where t != currentTime && r !== fadeFrom && r !== fadeTo {
                r.alpha = idle(t)
            }
        }

        private(set) var currentTime: Int = -1
        private var displayLink: CADisplayLink?
        private var fadeFrom: MKTileOverlayRenderer?
        private var fadeTo: MKTileOverlayRenderer?
        private var fadeStart: CFTimeInterval = 0
        /// Where the frame fading out comes to rest: a hair above zero in
        /// the span, zero once its span has left the timeline.
        private var fadeRest: CGFloat = Coordinator.idleAlpha

        var onRegionChange: ((MKCoordinateRegion) -> Void)?
        var onSelectStation: ((StationObs) -> Void)?

        /// A station tap opens its detail sheet; the annotation is deselected
        /// right away so the same station can be tapped again after dismissal.
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let st = view.annotation as? StationAnnotation {
                mapView.deselectAnnotation(st, animated: false)
                onSelectStation?(st.obs)
            } else if let lt = view.annotation as? LightningAnnotation {
                mapView.deselectAnnotation(lt, animated: false)
                onSelectStation?(lt.obs)
            } else if let a = view.annotation as? AdvisoryLabelAnnotation {
                mapView.deselectAnnotation(a, animated: false)
                onSelectAdvisory?(.area(a.area))
            } else if let p = view.annotation as? PirepAnnotation {
                mapView.deselectAnnotation(p, animated: false)
                onSelectAdvisory?(.pirep(p.pirep))
            }
        }
        var shownArrows: [WindArrow] = []
        var arrowAnnotations: [WindArrowAnnotation] = []
        var stormAnnotations: [LightningAnnotation] = []
        var shownStorms: [StationObs] = []
        var frontOverlay: FrontFieldOverlay?
        var pressureOverlay: PressureFieldOverlay?
        var shownPressure: PressureFieldState?

        // MARK: The line clock

        private var lineSource: RadarLineSource?
        private var lineLink: CADisplayLink?
        private weak var lineMap: MKMapView?
        private var lastLineClock = -Double.infinity
        private var lineVersion = 0

        /// Start or stop drawing the fronts and the isobars from the loop's
        /// clock. While it runs, what SwiftUI hands `syncFronts` and
        /// `syncPressure` still sets which layers exist and how they are
        /// styled, but not where the lines are.
        func syncLines(_ source: RadarLineSource?, on map: MKMapView) {
            let was = lineSource != nil
            lineSource = source
            lineMap = map
            syncIsolines(source, on: map)
            guard source != nil else {
                lineLink?.invalidate()
                lineLink = nil
                if was {
                    // Whatever comes next from SwiftUI is drawn, even if it
                    // equals what was shown before the loop started.
                    shownPressure = nil
                    lastFrontVersion = -1
                    lastLineClock = -.infinity
                }
                return
            }
            if lineLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(stepLines))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 20)
                link.add(to: .main, forMode: .common)
                lineLink = link
            }
        }

        @objc private func stepLines() {
            guard let source = lineSource, let map = lineMap, let t = source.clock(), t != lastLineClock else { return }
            lastLineClock = t
            if frontOverlay != nil, let state = source.fronts(t) {
                applyFronts(state, on: map)
            }
            guard var state = shownPressure, let overlay = pressureOverlay else { return }
            let gpuLines = isolineView != nil
            let field = source.pressure(t)
            // With the GPU drawing the lines, this overlay keeps only its
            // shading: its own lines are taken off once, and it is redrawn
            // after that only when there is a grid to shade.
            guard field != nil || (gpuLines && !linesHandedOver) else { return }
            linesHandedOver = gpuLines
            lineVersion -= 1
            if let field { state.field = field }
            if gpuLines { state.showIsobars = false }
            state.isobarLabels = source.labelIsobars
            state.version = lineVersion
            overlay.state = state
            map.renderer(for: overlay)?.setNeedsDisplay()
        }

        // MARK: The isobars' shape, on the GPU

        private var isolineView: IsolineView?
        private var linesHandedOver = false

        private func syncIsolines(_ source: RadarLineSource?, on map: MKMapView) {
            guard let source, let line = source.shape else {
                isolineView?.stop()
                isolineView?.removeFromSuperview()
                isolineView = nil
                linesHandedOver = false
                return
            }
            if isolineView == nil {
                let v = IsolineView(frame: map.bounds)
                v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                v.mapView = map
                // Under the wind's streaks, over everything the map draws.
                if let flow = flowView { map.insertSubview(v, belowSubview: flow) } else { map.addSubview(v) }
                isolineView = v
            }
            isolineView?.clock = source.clock
            isolineView?.show(line)
        }

        func syncPressure(_ state: PressureFieldState?, on map: MKMapView) {
            guard state != shownPressure else { return }
            shownPressure = state
            guard let state, state.drawsAnything else {
                if let o = pressureOverlay { map.removeOverlay(o); pressureOverlay = nil }
                return
            }
            if pressureOverlay == nil {
                let o = PressureFieldOverlay()
                pressureOverlay = o
                // Below the fronts (labels) and above the radar tiles.
                map.addOverlay(o, level: .aboveRoads)
            }
            pressureOverlay?.state = state
            if let o = pressureOverlay, let r = map.renderer(for: o) { r.setNeedsDisplay() }
        }
        var lightningOverlay: LightningOverlay?
        var shownLightning: LightningState?
        private var pulseLink: CADisplayLink?
        private var pulseUntil: CFTimeInterval = 0
        private weak var pulseMap: MKMapView?

        var lightningNextOverlay: MKTileOverlay?

        /// One tile layer for the chance of lightning, swapped when a newer
        /// grid's template arrives, removed when Lightning goes off. It sits
        /// with the roads, under the flashes.
        func syncLightningNext(_ template: String?, on map: MKMapView) {
            guard template != lightningNextOverlay?.urlTemplate else { return }
            if let o = lightningNextOverlay { map.removeOverlay(o); lightningNextOverlay = nil }
            guard let template else { return }
            let o = MKTileOverlay(urlTemplate: template)
            o.tileSize = CGSize(width: 512, height: 512)
            o.canReplaceMapContent = false
            o.minimumZ = 1
            o.maximumZ = 12
            lightningNextOverlay = o
            map.addOverlay(o, level: .aboveRoads)
        }

        func syncLightning(_ state: LightningState?, on map: MKMapView) {
            guard state != shownLightning else { return }
            shownLightning = state
            guard let state, state.response != nil else {
                if let o = lightningOverlay { map.removeOverlay(o); lightningOverlay = nil }
                return
            }
            if lightningOverlay == nil {
                let o = LightningOverlay()
                lightningOverlay = o
                map.addOverlay(o, level: .aboveLabels)   // strikes over everything
            }
            lightningOverlay?.state = state
            if let o = lightningOverlay, let r = map.renderer(for: o) { r.setNeedsDisplay() }
            // Run the arrival pulse for about a second after a new slice.
            pulseMap = map
            pulseUntil = CACurrentMediaTime() + LightningRenderer.pulseDuration + 0.1
            if pulseLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(stepPulse))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
                link.add(to: .main, forMode: .common)
                pulseLink = link
            }
        }

        @objc private func stepPulse() {
            if let o = lightningOverlay, let map = pulseMap, let r = map.renderer(for: o) {
                r.setNeedsDisplay()
            }
            if CACurrentMediaTime() > pulseUntil {
                pulseLink?.invalidate()
                pulseLink = nil
            }
        }
        var frontRenderer: FrontFieldRenderer?
        var lastFrontVersion = -1
        var centerAnnotations: [PressureCenterAnnotation] = []
        var homePin: MKPointAnnotation?
        var homeBarb: StationAnnotation?
        var shownHome: HomeMarker?
        var centeredOn: CLLocationCoordinate2D?
        var lastRecenterToken = 0
        var flowView: WindFlowView?
        var stationAnnotations: [StationAnnotation] = []
        var shownStations: [StationObs] = []
        var shownStationStyle: StationLayerStyle = .off

        /// Barb or speed annotations per station; rebuilt only when the set or
        /// the style changes (the style is baked into the reuse identifier).
        /// Pin or barb for the home station, and the user's blue dot only
        /// when the pin is what marks the station.
        func syncHome(_ home: HomeMarker?, center: CLLocationCoordinate2D, on map: MKMapView) {
            guard home != shownHome else { return }
            shownHome = home
            if let h = home, h.asBarb {
                if let pin = homePin { map.removeAnnotation(pin) }
                map.showsUserLocation = false
                let a = homeBarb ?? StationAnnotation()
                a.coordinate = center
                a.obs = h.obs
                a.isHome = true
                if homeBarb == nil { map.addAnnotation(a); homeBarb = a }
                else if let v = map.view(for: a) as? WindBarbView { v.configure(a) }
                else if let v = map.view(for: a) as? SpeedLabelView { v.configure(a) }
            } else {
                if let b = homeBarb { map.removeAnnotation(b); homeBarb = nil }
                if let pin = homePin, map.view(for: pin) == nil, !map.annotations.contains(where: { $0 === pin }) {
                    map.addAnnotation(pin)
                }
                map.showsUserLocation = true
            }
        }

        func syncStations(_ obs: [StationObs], style: StationLayerStyle, on map: MKMapView) {
            // The slice's copy of the home station is fuller (raw METAR); use
            // it for the home marker and keep it out of the layer.
            if let b = homeBarb, let full = obs.first(where: { $0.id == b.obs.id }), full != b.obs {
                b.obs = full
                if let v = map.view(for: b) as? WindBarbView { v.configure(b) }
                else if let v = map.view(for: b) as? SpeedLabelView { v.configure(b) }
            }
            let homeID = homeBarb?.obs.id
            let want = style == .off ? [] : obs.filter { $0.id != homeID }
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
            applyDeclutter(on: map)
        }

        /// Standalone bolts for stations reporting lightning, only while the
        /// station layer is off (the barbs badge themselves otherwise). The
        /// home barb badges itself too, so it is left out as well.
        func syncStorms(_ obs: [StationObs], show: Bool, stationsOn: Bool, on map: MKMapView) {
            let homeID = homeBarb?.obs.id
            let want = (show && !stationsOn) ? obs.filter { $0.lightning != nil && $0.id != homeID } : []
            guard want != shownStorms else { return }
            shownStorms = want
            map.removeAnnotations(stormAnnotations)
            stormAnnotations = want.map { o in
                let a = LightningAnnotation()
                a.coordinate = CLLocationCoordinate2D(latitude: o.lat, longitude: o.lon)
                a.obs = o
                return a
            }
            map.addAnnotations(stormAnnotations)
        }

        // MARK: Declutter

        /// Station ids only once the map is zoomed in past this span; the
        /// home station always keeps its name (see the annotation views).
        static let idLabelMaxSpan: CLLocationDegrees = 2.2
        private var showsIDs = true

        func applyDeclutter(on map: MKMapView) {
            let show = map.region.span.latitudeDelta < Self.idLabelMaxSpan
            guard show != showsIDs else { return }
            showsIDs = show
            for a in stationAnnotations + [homeBarb].compactMap({ $0 }) {
                if let v = map.view(for: a) as? WindBarbView { v.showsID = show }
                else if let v = map.view(for: a) as? SpeedLabelView { v.showsID = show }
            }
        }

        /// Radar tiles hidden while another base layer is showing. Frames
        /// keep loading in the background so switching back is instant.
        private var radarHidden = false

        func setRadarHidden(_ hidden: Bool) {
            guard hidden != radarHidden else { return }
            radarHidden = hidden
            if hidden {
                displayLink?.invalidate()
                displayLink = nil
                fadeFrom = nil
                fadeTo = nil
                for r in renderers.values { r.alpha = 0 }
            } else {
                let t = currentTime
                currentTime = -1
                setCurrent(t)
            }
        }

        /// The particle layer rides on top of the map as a subview; its
        /// streaks are anchored to the ground, so the map only has to tell it
        /// when it moved, and only so fresh territory gets topped up.
        func syncFlow(_ field: [WindArrow]?, on map: MKMapView, embedded: Bool, animating: Bool, ramp: Double = 35) {
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
            flowView?.yieldsToScrolling = embedded
            flowView?.isActive = animating
            flowView?.rampKmh = CGFloat(ramp)
            if flowView?.samples != field {
                flowView?.samples = field
            }
        }

        // MARK: Advisories

        var onSelectAdvisory: ((AdvisoryDetailSheet.Item) -> Void)?
        private var shownAdvisories: AdvisoriesResponse?
        private var advisoryPolygons: [AdvisoryPolygon] = []
        private var advisoryAnnotations: [MKAnnotation] = []

        /// Rebuild only when the set changed; updateUIView runs every tick.
        func syncAdvisories(_ resp: AdvisoriesResponse?, on map: MKMapView) {
            guard resp != shownAdvisories else { return }
            shownAdvisories = resp
            map.removeOverlays(advisoryPolygons)
            map.removeAnnotations(advisoryAnnotations)
            advisoryPolygons = []
            advisoryAnnotations = []
            guard let resp else { return }
            for a in resp.areas where a.points.count >= 3 {
                let poly = AdvisoryPolygon.make(a)
                advisoryPolygons.append(poly)
                let label = AdvisoryLabelAnnotation()
                label.area = a
                label.coordinate = poly.coordinate
                advisoryAnnotations.append(label)
            }
            for p in resp.pireps {
                let ann = PirepAnnotation()
                ann.pirep = p
                ann.coordinate = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
                advisoryAnnotations.append(ann)
            }
            map.addOverlays(advisoryPolygons, level: .aboveRoads)
            map.addAnnotations(advisoryAnnotations)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let a = overlay as? AdvisoryPolygon {
                return AdvisoryRenderers.renderer(a)
            }
            if let p = overlay as? PressureFieldOverlay {
                return PressureFieldRenderer(overlay: p)
            }
            if let l = overlay as? LightningOverlay {
                return LightningRenderer(overlay: l)
            }
            if let field = overlay as? FrontFieldOverlay {
                let r = FrontFieldRenderer(overlay: field)
                frontRenderer = r
                return r
            }
            if let tile = overlay as? MKTileOverlay, !(tile is RadarTileOverlay) {
                let r = MKTileOverlayRenderer(tileOverlay: tile)
                r.alpha = 1
                return r
            }
            if let tile = overlay as? RadarTileOverlay {
                let r = MKTileOverlayRenderer(tileOverlay: tile)
                r.alpha = radarHidden ? 0
                    : (tile.frameTime == currentTime ? visibleAlpha : idle(tile.frameTime))
                renderers[tile.frameTime] = r
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        /// True between a gesture starting and the map settling.
        private var panning = false

        /// While the map moves, only the frame on screen asks MapKit for
        /// tiles. The others drop to true zero, where MapKit stops fetching
        /// for them, so the visible frame's tiles are not queued behind six
        /// nobody is looking at. A frame mid-crossfade is left alone.
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            panning = true
            guard !radarHidden else { return }
            for (t, r) in renderers where t != currentTime && r !== fadeFrom && r !== fadeTo {
                r.alpha = 0
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            panning = false
            if !radarHidden {
                // Back to a hair above zero, so the span's other frames warm up again.
                for (t, r) in renderers where t != currentTime && r !== fadeFrom && r !== fadeTo {
                    r.alpha = idle(t)
                }
            }
            onRegionChange?(mapView.region)
            applyDeclutter(on: mapView)
            flowView?.mapDidMove()
            prefetchRing(on: mapView)
            prefetchFrames(loopOrder, on: mapView)
            // A zoom changes how many of the grid's arrows fit.
            syncArrows(allArrows, on: mapView)
        }

        /// One ring of tiles around the visible ones, for the current frame,
        /// once the map has settled. MapKit only asks for a tile the moment it
        /// is on screen; this asks a little earlier.
        private func prefetchRing(on map: MKMapView) {
            guard !radarHidden, let overlay = overlays[currentTime] else { return }
            for path in tiles(on: map, for: overlay, ring: true).prefix(48) {
                overlay.prefetch(path)
            }
        }

        /// The source tiles a frame needs for what is on screen, or (`ring`)
        /// the one ring of tiles around those.
        private func tiles(on map: MKMapView, for overlay: RadarTileOverlay, ring: Bool) -> [MKTileOverlayPath] {
            guard map.bounds.width > 0, map.visibleMapRect.size.width > 0 else { return [] }
            let rect = map.visibleMapRect
            let world = MKMapSize.world.width
            let displayScale = Double(max(1, map.traitCollection.displayScale))
            // The zoom MapKit will pick for a 512 px tile at this scale, then
            // clamped to the source's native zoom: past it every child maps to
            // the same few ancestors, so the tiles are computed there directly.
            let pixelsPerMapPoint = Double(map.bounds.width) * displayScale / rect.size.width
            let raw = log2(pixelsPerMapPoint * world / Double(overlay.tileSize.width))
            guard raw.isFinite else { return [] }
            let z = max(1, min(overlay.maxNativeZ, Int(raw.rounded())))
            let span = world / Double(1 << z)
            let n = 1 << z
            let fx0 = floor(rect.minX / span), fx1 = floor(rect.maxX / span)
            let fy0 = floor(rect.minY / span), fy1 = floor(rect.maxY / span)
            guard fx0.isFinite, fx1.isFinite, fy0.isFinite, fy1.isFinite else { return [] }
            let x0 = Int(fx0), x1 = Int(fx1), y0 = Int(fy0), y1 = Int(fy1)
            var out: [MKTileOverlayPath] = []
            for x in (x0 - 1)...(x1 + 1) {
                for y in (y0 - 1)...(y1 + 1) {
                    let inside = x >= x0 && x <= x1 && y >= y0 && y <= y1
                    guard inside != ring, x >= 0, y >= 0, x < n, y < n else { continue }
                    out.append(MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: CGFloat(displayScale)))
                }
            }
            return out
        }

        /// Fetch and repaint, into the app's own caches, the tiles some
        /// frames need for the view on screen, without showing them: when
        /// one comes up, MapKit's own load of it is a cache read.
        private func prefetchFrames(_ keys: [Int], on map: MKMapView) {
            guard !radarHidden else { return }
            for key in keys {
                guard let frame = overlays[key] else { continue }
                for path in tiles(on: map, for: frame, ring: false) { frame.prefetch(path) }
            }
        }

        // MARK: Buffering a loop

        private var bufferID = -1
        /// The longest a loop waits for its frames: on a slow connection it
        /// starts anyway and fills in as it plays, as it did before.
        private static let bufferTimeout: TimeInterval = 10

        /// Load a loop's frames for the view on screen before it plays, the
        /// way a video buffers: every tile each frame needs is fetched and
        /// repainted into the caches, MapKit's own loads of them are waited
        /// out, and then `ready` is called, once. Until then the map holds
        /// on the frame it is showing. A request with the id of the last one
        /// is the same request; nil cancels.
        func syncBuffer(_ request: RadarBufferRequest?, on map: MKMapView) {
            guard let request else { bufferID = -1; return }
            guard request.id != bufferID else { return }
            bufferID = request.id
            let id = request.id
            var finished = false
            let finish = { [weak self, weak map] in
                guard let self, !finished, self.bufferID == id else { return }
                finished = true
                request.ready(id)
                // The loop is on its way; now the frames a scrub could reach.
                if let map { self.prefetchFrames(self.order.filter { !request.keys.contains($0) }, on: map) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.bufferTimeout, execute: finish)
            startBuffer(request, on: map, attempt: 0, finish: finish)
        }

        private func startBuffer(_ request: RadarBufferRequest, on map: MKMapView, attempt: Int,
                                 finish: @escaping () -> Void) {
            guard bufferID == request.id else { return }
            let frames = request.keys.compactMap { overlays[$0] }
            // The map has no size for a moment after it is made; ask again.
            guard let first = frames.first, !tiles(on: map, for: first, ring: false).isEmpty else {
                guard attempt < 20 else { finish(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak map] in
                    guard let self, let map else { return }
                    self.startBuffer(request, on: map, attempt: attempt + 1, finish: finish)
                }
                return
            }
            let left = Locked(0)
            let settle = { [weak self] in
                DispatchQueue.main.async { self?.settleBuffer(frames, tries: 0, finish: finish) }
            }
            var wanted: [(RadarTileOverlay, MKTileOverlayPath)] = []
            for frame in frames {
                for path in tiles(on: map, for: frame, ring: false) { wanted.append((frame, path)) }
            }
            left.value = wanted.count
            for (frame, path) in wanted {
                frame.prefetch(path) {
                    if left.withLock({ $0 -= 1; return $0 }) == 0 { settle() }
                }
            }
        }

        /// The tiles are in the caches; give MapKit a moment to finish
        /// reading them into the frames (two seconds at most).
        private func settleBuffer(_ frames: [RadarTileOverlay], tries: Int, finish: @escaping () -> Void) {
            if tries >= 20 || frames.allSatisfy({ $0.loadsInFlight == 0 }) {
                finish()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.settleBuffer(frames, tries: tries + 1, finish: finish)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let a = annotation as? AdvisoryLabelAnnotation {
                let id = "advisoryLabel"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? AdvisoryLabelView)
                    ?? AdvisoryLabelView(annotation: a, reuseIdentifier: id)
                view.annotation = a
                view.configure(a)
                return view
            }
            if let p = annotation as? PirepAnnotation {
                let id = "pirep"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? PirepView)
                    ?? PirepView(annotation: p, reuseIdentifier: id)
                view.annotation = p
                view.configure(p)
                return view
            }
            if let st = annotation as? StationAnnotation {
                if shownStationStyle == .speeds && !(st.isHome && shownStations.isEmpty) {
                    let id = "stationSpeed"
                    let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? SpeedLabelView)
                        ?? SpeedLabelView(annotation: st, reuseIdentifier: id)
                    view.annotation = st
                    view.showsID = showsIDs
                    view.configure(st)
                    return view
                }
                let id = "stationBarb"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? WindBarbView)
                    ?? WindBarbView(annotation: st, reuseIdentifier: id)
                view.annotation = st
                view.showsID = showsIDs
                view.configure(st)
                return view
            }
            if let lt = annotation as? LightningAnnotation {
                let id = "lightning"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? LightningMarkerView)
                    ?? LightningMarkerView(annotation: lt, reuseIdentifier: id)
                view.annotation = lt
                view.configure(lt)
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
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? WindArrowView)
                ?? WindArrowView(annotation: wind, reuseIdentifier: id)
            view.annotation = wind
            let unit = WindUnit(rawValue: AppConfig.sharedDefaults.string(forKey: "windUnit") ?? "") ?? .mph
            view.configure(speedKmh: wind.speedKmh, fromDeg: wind.fromDeg, unit: unit)
            return view
        }

        /// The whole grid the layer was given; what is drawn is a thinned
        /// lattice of it (below).
        private var allArrows: [WindArrow] = []
        /// Arrows closer than this on screen, in points, are thinned to every
        /// second, third... column or row of the grid, so a wider grid at a
        /// level, or a zoom out, never turns into a wall of arrows and numbers.
        static let arrowSpacingPt: CGFloat = 76
        static let arrowRowSpacingPt: CGFloat = 60

        /// The arrows to draw at this zoom: the grid's columns and rows kept
        /// every k-th, k from the grid's spacing on screen. Which ones are
        /// kept is counted from the equator and the prime meridian, not from
        /// the grid's own corner, so a new grid for a panned view keeps the
        /// same arrows where the two overlap instead of shifting the lattice
        /// by a column.
        private func thinned(_ arrows: [WindArrow], on map: MKMapView) -> [WindArrow] {
            guard arrows.count > 4 else { return arrows }
            func distinct(_ values: [Double]) -> [Double] {
                var out: [Double] = []
                for v in values.sorted() where out.last.map({ abs($0 - v) > 1e-6 }) ?? true { out.append(v) }
                return out
            }
            let lats = distinct(arrows.map(\.lat)), lons = distinct(arrows.map(\.lon))
            guard lats.count > 1, lons.count > 1 else { return arrows }
            let stepLat = (lats[lats.count - 1] - lats[0]) / Double(lats.count - 1)
            let stepLon = (lons[lons.count - 1] - lons[0]) / Double(lons.count - 1)
            // Measured at the middle of the view, where the grid is drawn.
            let c = map.centerCoordinate
            let p0 = map.convert(c, toPointTo: map)
            let px = map.convert(CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude + stepLon), toPointTo: map)
            let py = map.convert(CLLocationCoordinate2D(latitude: c.latitude + stepLat, longitude: c.longitude), toPointTo: map)
            let dx = abs(px.x - p0.x), dy = abs(py.y - p0.y)
            guard dx.isFinite, dy.isFinite, dx > 0, dy > 0 else { return arrows }
            let sx = max(1, Int(ceil(Self.arrowSpacingPt / dx)))
            let sy = max(1, Int(ceil(Self.arrowRowSpacingPt / dy)))
            if sx == 1 && sy == 1 { return arrows }
            func kept(_ v: Double, step: Double, every n: Int) -> Bool {
                let i = Int((v / step).rounded())
                return ((i % n) + n) % n == 0
            }
            return arrows.filter { kept($0.lon, step: stepLon, every: sx) && kept($0.lat, step: stepLat, every: sy) }
        }

        private static func arrowKey(_ lat: Double, _ lon: Double) -> Int {
            Int((lat * 10_000).rounded()) &* 4_000_000 &+ Int((lon * 10_000).rounded())
        }

        /// Sync arrow annotations only when the drawn set actually changed:
        /// updateUIView runs every animation tick and must not churn
        /// annotations, and a zoom re-thins the same grid. An arrow that is
        /// in both the old set and the new stays on the map and takes its
        /// new speed and direction in place; only the ones that are really
        /// new are added (they fade in, `didAdd`), and only the ones that are
        /// gone are removed. Swapping the whole set made every arrow blink
        /// each time a pan fetched the next grid.
        func syncArrows(_ given: [WindArrow], on map: MKMapView) {
            allArrows = given
            let arrows = thinned(given, on: map)
            guard arrows != shownArrows else { return }
            shownArrows = arrows
            var old: [Int: WindArrowAnnotation] = [:]
            for a in arrowAnnotations { old[Self.arrowKey(a.coordinate.latitude, a.coordinate.longitude)] = a }
            let unit = WindUnit(rawValue: AppConfig.sharedDefaults.string(forKey: "windUnit") ?? "") ?? .mph
            var next: [WindArrowAnnotation] = [], added: [WindArrowAnnotation] = []
            for a in arrows {
                let key = Self.arrowKey(a.lat, a.lon)
                if let ann = old.removeValue(forKey: key) {
                    if ann.speedKmh != a.speedKmh || ann.fromDeg != a.fromDeg {
                        ann.speedKmh = a.speedKmh
                        ann.fromDeg = a.fromDeg
                        (map.view(for: ann) as? WindArrowView)?.configure(speedKmh: a.speedKmh, fromDeg: a.fromDeg, unit: unit)
                    }
                    next.append(ann)
                } else {
                    let ann = WindArrowAnnotation()
                    ann.coordinate = CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon)
                    ann.speedKmh = a.speedKmh
                    ann.fromDeg = a.fromDeg
                    next.append(ann)
                    added.append(ann)
                }
            }
            if !old.isEmpty { map.removeAnnotations(Array(old.values)) }
            arrowAnnotations = next
            if !added.isEmpty { map.addAnnotations(added) }
        }

        /// A wind arrow that joins the map comes up over a quarter second
        /// instead of appearing.
        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            for case let v as WindArrowView in views {
                let target = v.alpha
                v.alpha = 0
                UIView.animate(withDuration: 0.25) { v.alpha = target }
            }
        }

        /// The map is going away: stop everything that would touch it later.
        /// The crossfade's display link holds this coordinator, and fired
        /// into a renderer whose map was already torn down when the radar
        /// was closed in the middle of a fade (a crash on iOS 17, found
        /// 2026-10-02).
        func teardown() {
            displayLink?.invalidate()
            displayLink = nil
            fadeFrom = nil
            fadeTo = nil
            flowView?.stop()
            lineLink?.invalidate()
            lineLink = nil
            lineSource = nil
            isolineView?.stop()
            bufferID = -1
            pulseLink?.invalidate()
            pulseLink = nil
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
            // While the loop's clock is drawing the fronts, it has the say.
            guard lineSource == nil, state.version != lastFrontVersion else { return }
            applyFronts(state, on: map)
        }

        private func applyFronts(_ state: FrontRenderState, on map: MKMapView) {
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
            let oldKey = currentTime
            currentTime = time
            near = Self.framesNear(time, order: order, loop: loopOrder)
            guard !radarHidden else { return }
            displayLink?.invalidate()
            displayLink = nil
            // Park everything that isn't part of this transition.
            // Mid-pan the parked frames stay at zero; the loop stepping must
            // not quietly un-park them (review finding: it did, within one
            // tick, which made the parking cosmetic while playing).
            for (t, r) in renderers where t != time && r !== old {
                r.alpha = idle(t)
            }
            guard let new = renderers[time] else {
                old?.alpha = idle(oldKey)
                return
            }
            fadeRest = idle(oldKey)
            fadeFrom = old
            fadeTo = new
            fadeStart = CACurrentMediaTime()
            let link = CADisplayLink(target: self, selector: #selector(stepFade))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func stepFade() {
            let p = CGFloat(min(1, (CACurrentMediaTime() - fadeStart) / Self.fadeDuration))
            fadeTo?.alpha = Self.idleAlpha + (visibleAlpha - Self.idleAlpha) * p
            fadeFrom?.alpha = visibleAlpha - (visibleAlpha - fadeRest) * p
            if p >= 1 {
                if panning { fadeFrom?.alpha = 0 }
                displayLink?.invalidate()
                displayLink = nil
                fadeFrom = nil
                fadeTo = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.accessibilityIdentifier = "radar.map"
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
        context.coordinator.homePin = pin
        context.coordinator.centeredOn = center
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // A station switch (the iPad dashboard resolving location after first
        // paint, or a saved place) moves the home pin and glides the map
        // there; the region change then refetches the location-bound layers.
        // Cheaper than rebuilding the whole panel and its model.
        if let was = context.coordinator.centeredOn,
           was.latitude != center.latitude || was.longitude != center.longitude {
            context.coordinator.centeredOn = center
            context.coordinator.homePin?.coordinate = center
            context.coordinator.homeBarb?.coordinate = center
            map.setRegion(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 3.2, longitudeDelta: 3.2)), animated: true)
        }
        // Lazily add an overlay per frame. RainViewer serves only its Universal
        // Blue palette now (color 2), fetched UNSMOOTHED (options 0_1: sharp,
        // snow in its own colors) so each pixel reads back to an exact dBZ and
        // RadarPalette repaints it. Past RainViewer's native z7 the overlay
        // crops + upscales ancestor tiles (see loadTile) — do NOT set maximumZ,
        // which would stop rendering entirely past z7.
        for f in frames where context.coordinator.overlays[f.key] == nil {
            // Observed, nowcast and model frames all come in the one shape.
            let tile = RadarTileOverlay(urlTemplate: host + f.path + "/512/{z}/{x}/{y}/2/0_1.png")
            tile.base = host + f.path
            tile.tileSize = CGSize(width: 512, height: 512)
            tile.recolor = true
            tile.frameTime = f.key
            tile.canReplaceMapContent = false
            tile.minimumZ = 1
            context.coordinator.overlays[f.key] = tile
            map.addOverlay(tile, level: .aboveRoads)
        }
        context.coordinator.setFrames(frames.map(\.key), loop: loopKeys)
        context.coordinator.syncBuffer(buffer, on: map)
        if recenterToken != context.coordinator.lastRecenterToken {
            context.coordinator.lastRecenterToken = recenterToken
            map.setRegion(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 3.2, longitudeDelta: 3.2)), animated: true)
        }
        context.coordinator.onRegionChange = onRegionChange
        context.coordinator.onSelectStation = onSelectStation
        context.coordinator.onSelectAdvisory = onSelectAdvisory
        context.coordinator.syncAdvisories(advisories, on: map)
        context.coordinator.syncHome(home, center: center, on: map)
        context.coordinator.syncArrows(showWind ? windArrows : [], on: map)
        context.coordinator.syncLines(lines, on: map)
        context.coordinator.syncFronts(frontState, on: map)
        context.coordinator.syncPressure(pressureState, on: map)
        context.coordinator.syncFlow(windFlow, on: map, embedded: embedded, animating: animating, ramp: windRampKmh)
        context.coordinator.syncStations(stations, style: stationStyle, on: map)
        context.coordinator.syncStorms(stations, show: showStorms, stationsOn: stationStyle != .off, on: map)
        context.coordinator.syncLightning(showStorms ? lightning : nil, on: map)
        context.coordinator.syncLightningNext(showStorms ? lightningNextTemplate : nil, on: map)
        context.coordinator.setRadarDimmed(showStorms)
        context.coordinator.setRadarHidden(!radarVisible)

        guard frames.indices.contains(index) else { return }
        context.coordinator.setCurrent(frames[index].key)
    }
}
