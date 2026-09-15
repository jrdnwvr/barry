//  RadarMapView.swift
//  Barry — iOS
//
//  The MapKit bridge: tile overlays for radar frames, the front-field
//  overlay, wind arrows, boundary-layer labels, station barbs/speeds, and the
//  particle flow subview. The coordinator owns the diffing so SwiftUI updates
//  only add or remove what changed.

import SwiftUI
import MapKit

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
    /// nil: the red pin marks the station and the map shows the user's own
    /// blue dot. Otherwise the home station is drawn as itself (see HomeMarker).
    var home: HomeMarker? = nil
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
        var homePin: MKPointAnnotation?
        var homeBarb: StationAnnotation?
        var shownHome: HomeMarker?
        var centeredOn: CLLocationCoordinate2D?
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
                if shownStationStyle == .speeds && !(st.isHome && shownStations.isEmpty) {
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
        context.coordinator.syncHome(home, center: center, on: map)
        context.coordinator.syncArrows(showWind ? windArrows : [], on: map)
        context.coordinator.syncBL(showBL ? blPoints : [], on: map)
        context.coordinator.syncFronts(frontState, on: map)
        context.coordinator.syncFlow(windFlow, on: map)
        context.coordinator.syncStations(stations, style: stationStyle, on: map)

        guard frames.indices.contains(index) else { return }
        context.coordinator.setCurrent(frames[index].time)
    }
}
