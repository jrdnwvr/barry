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

/// MKMapView with one tile overlay per radar frame; scrubbing just flips renderer
/// alphas, so already-loaded frames replay instantly.
struct RadarMapView: UIViewRepresentable {
    let host: String
    let frames: [RadarFrame]
    let index: Int
    /// False when another base layer (pressure, change) replaces the radar:
    /// the tiles stay loaded but draw at zero alpha.
    var radarVisible: Bool = true
    let center: CLLocationCoordinate2D
    var windArrows: [WindArrow] = []
    var showWind: Bool = false
    /// nil = flow layer off; otherwise the full wind grid to animate.
    var windFlow: [WindArrow]? = nil
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

        override func loadTile(at path: MKTileOverlayPath,
                               result: @escaping (Data?, Error?) -> Void) {
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
        private func fetchCached(_ url: URL, completion: @escaping (Data?) -> Void) {
            let key = url.absoluteString as NSString
            if let hit = Self.parentCache.object(forKey: key) {
                completion(hit as Data)
                return
            }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                if let data { Self.parentCache.setObject(data as NSData, forKey: key, cost: data.count) }
                completion(data)
            }.resume()
        }

        // ---- 4. prefetch ---------------------------------------------------

        /// Warm both caches for a tile without handing anything to MapKit, so
        /// the next small pan finds its edge already there. Past the native
        /// zoom this resolves to the ancestor tile, which is what loadTile
        /// would crop from anyway.
        func prefetch(_ path: MKTileOverlayPath) {
            let z = min(path.z, maxNativeZ)
            let scale = 1 << max(0, path.z - z)
            let src = MKTileOverlayPath(x: path.x / scale, y: path.y / scale, z: z,
                                        contentScaleFactor: path.contentScaleFactor)
            let u = url(forTilePath: src)
            fetchCached(u) { [weak self] data in
                guard let self, let data, self.recolor else { return }
                _ = self.painted(data, key: u.absoluteString)
            }
        }
    }

    final class WindArrowAnnotation: MKPointAnnotation {
        var speedKmh: Double = 0
        var fromDeg: Double = 0
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var overlays: [Int: RadarTileOverlay] = [:]
        var renderers: [Int: MKTileOverlayRenderer] = [:]

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
            if let st = view.annotation as? StationAnnotation {
                mapView.deselectAnnotation(st, animated: false)
                onSelectStation?(st.obs)
            } else if let lt = view.annotation as? LightningAnnotation {
                mapView.deselectAnnotation(lt, animated: false)
                onSelectStation?(lt.obs)
            }
        }
        var shownArrows: [WindArrow] = []
        var arrowAnnotations: [WindArrowAnnotation] = []
        var stormAnnotations: [LightningAnnotation] = []
        var shownStorms: [StationObs] = []
        var frontOverlay: FrontFieldOverlay?
        var pressureOverlay: PressureFieldOverlay?
        var shownPressure: PressureFieldState?

        func syncPressure(_ state: PressureFieldState?, on map: MKMapView) {
            guard state != shownPressure else { return }
            shownPressure = state
            guard let state, state.field != nil,
                  state.showIsobars || state.showIsallobars || state.shade != .off else {
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
        func syncFlow(_ field: [WindArrow]?, on map: MKMapView, embedded: Bool, animating: Bool) {
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
            if flowView?.samples != field {
                flowView?.samples = field
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
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
            if let tile = overlay as? RadarTileOverlay {
                let r = MKTileOverlayRenderer(tileOverlay: tile)
                r.alpha = radarHidden ? 0
                    : (tile.frameTime == currentTime ? visibleAlpha : (panning ? 0 : Self.idleAlpha))
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
                // Back to a hair above zero, so the other frames warm up again.
                for (t, r) in renderers where t != currentTime && r !== fadeFrom && r !== fadeTo {
                    r.alpha = Self.idleAlpha
                }
            }
            onRegionChange?(mapView.region)
            applyDeclutter(on: mapView)
            flowView?.mapDidMove()
            prefetchRing(on: mapView)
        }

        /// One ring of tiles around the visible ones, for the current frame,
        /// once the map has settled. MapKit only asks for a tile the moment it
        /// is on screen; this asks a little earlier.
        private func prefetchRing(on map: MKMapView) {
            guard !radarHidden, let overlay = overlays[currentTime], map.bounds.width > 0 else { return }
            let rect = map.visibleMapRect
            let world = MKMapSize.world.width
            // The zoom MapKit will pick for a 512 px tile at this scale.
            let pixelsPerMapPoint = Double(map.bounds.width) * Double(map.traitCollection.displayScale) / rect.size.width
            let z = max(1, min(20, Int((log2(pixelsPerMapPoint * world / Double(overlay.tileSize.width))).rounded())))
            let span = world / Double(1 << z)
            let n = 1 << z
            let x0 = Int(floor(rect.minX / span)), x1 = Int(floor(rect.maxX / span))
            let y0 = Int(floor(rect.minY / span)), y1 = Int(floor(rect.maxY / span))
            var count = 0
            for x in (x0 - 1)...(x1 + 1) {
                for y in (y0 - 1)...(y1 + 1) {
                    let inside = x >= x0 && x <= x1 && y >= y0 && y <= y1
                    guard !inside, x >= 0, y >= 0, x < n, y < n, count < 48 else { continue }
                    overlay.prefetch(MKTileOverlayPath(x: x, y: y, z: z,
                                                       contentScaleFactor: map.traitCollection.displayScale))
                    count += 1
                }
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
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
            guard !radarHidden else { return }
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
            fadeTo?.alpha = Self.idleAlpha + (visibleAlpha - Self.idleAlpha) * p
            fadeFrom?.alpha = visibleAlpha - (visibleAlpha - Self.idleAlpha) * p
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
                    host + f.path + "/512/{z}/{x}/{y}/2/0_1.png")
                tile.tileSize = CGSize(width: 512, height: 512)
                tile.recolor = true
            }
            tile.frameTime = f.time
            tile.canReplaceMapContent = false
            tile.minimumZ = 1
            context.coordinator.overlays[f.time] = tile
            map.addOverlay(tile, level: .aboveRoads)
        }
        if recenterToken != context.coordinator.lastRecenterToken {
            context.coordinator.lastRecenterToken = recenterToken
            map.setRegion(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 3.2, longitudeDelta: 3.2)), animated: true)
        }
        context.coordinator.onRegionChange = onRegionChange
        context.coordinator.onSelectStation = onSelectStation
        context.coordinator.syncHome(home, center: center, on: map)
        context.coordinator.syncArrows(showWind ? windArrows : [], on: map)
        context.coordinator.syncFronts(frontState, on: map)
        context.coordinator.syncPressure(pressureState, on: map)
        context.coordinator.syncFlow(windFlow, on: map, embedded: embedded, animating: animating)
        context.coordinator.syncStations(stations, style: stationStyle, on: map)
        context.coordinator.syncStorms(stations, show: showStorms, stationsOn: stationStyle != .off, on: map)
        context.coordinator.syncLightning(showStorms ? lightning : nil, on: map)
        context.coordinator.setRadarDimmed(showStorms)
        context.coordinator.setRadarHidden(!radarVisible)

        guard frames.indices.contains(index) else { return }
        context.coordinator.setCurrent(frames[index].time)
    }
}
