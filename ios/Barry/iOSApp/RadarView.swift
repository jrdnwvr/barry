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
    @Published var blPoints: [BLPoint] = []

    /// Last region the map reported — used when a toggle flips on.
    var lastRegion: MKCoordinateRegion?
    private var windTask: Task<Void, Never>?
    private var blTask: Task<Void, Never>?

    /// Arrows only render where the wind is worth drawing (~8 kt) — the Dark Sky
    /// rule: calm areas stay clean.
    static let minArrowKmh = 15.0

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
    func scheduleFieldReload(for region: MKCoordinateRegion, wind: Bool, boundaryLayer: Bool) {
        lastRegion = region
        if wind {
            windTask?.cancel()
            windTask = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await fetchWind(region: region)
            }
        }
        if boundaryLayer {
            blTask?.cancel()
            blTask = Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                await fetchBoundaryLayer(region: region)
            }
        }
    }

    /// The shared 7×5 sample grid across a region (comma-joined for Open-Meteo's
    /// multi-point API).
    private func gridQuery(for region: MKCoordinateRegion) -> (lat: String, lon: String) {
        let cols = 7, rows = 5
        let inset = 0.12
        var lats: [Double] = [], lons: [Double] = []
        let latSpan = region.span.latitudeDelta * (1 - 2 * inset)
        let lonSpan = region.span.longitudeDelta * (1 - 2 * inset)
        let lat0 = region.center.latitude - latSpan / 2
        let lon0 = region.center.longitude - lonSpan / 2
        for r in 0..<rows {
            for c in 0..<cols {
                lats.append(lat0 + latSpan * Double(r) / Double(rows - 1))
                lons.append(lon0 + lonSpan * Double(c) / Double(cols - 1))
            }
        }
        return (lats.map { String(format: "%.3f", $0) }.joined(separator: ","),
                lons.map { String(format: "%.3f", $0) }.joined(separator: ","))
    }

    /// One multi-point Open-Meteo call for the wind grid.
    func fetchWind(region: MKCoordinateRegion) async {
        let grid = gridQuery(for: region)
        guard let url = URL(string:
            "https://api.open-meteo.com/v1/forecast?latitude=\(grid.lat)&longitude=\(grid.lon)&current_weather=true")
        else { return }

        struct Point: Decodable {
            struct CW: Decodable { let windspeed: Double; let winddirection: Double }
            let latitude: Double
            let longitude: Double
            let current_weather: CW
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let points = try JSONDecoder().decode([Point].self, from: data)
            windArrows = points
                .filter { $0.current_weather.windspeed >= Self.minArrowKmh }
                .map { WindArrow(lat: $0.latitude, lon: $0.longitude,
                                 speedKmh: $0.current_weather.windspeed,
                                 fromDeg: $0.current_weather.winddirection) }
        } catch {
            // Wind layer is enrichment; fail quietly and keep whatever we had.
        }
    }

    /// Boundary layer top for the same grid — Open-Meteo hourly, current hour.
    func fetchBoundaryLayer(region: MKCoordinateRegion) async {
        let grid = gridQuery(for: region)
        guard let url = URL(string:
            "https://api.open-meteo.com/v1/forecast?latitude=\(grid.lat)&longitude=\(grid.lon)&hourly=boundary_layer_height&forecast_days=1&timezone=UTC")
        else { return }

        struct Point: Decodable {
            struct Hourly: Decodable {
                let time: [String]
                let boundary_layer_height: [Double?]
            }
            let latitude: Double
            let longitude: Double
            let hourly: Hourly
        }
        // Match the current UTC hour against the hourly time axis.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let hourPrefix = fmt.string(from: Date())

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let points = try JSONDecoder().decode([Point].self, from: data)
            blPoints = points.compactMap { p in
                guard let idx = p.hourly.time.firstIndex(where: { $0.hasPrefix(hourPrefix) }),
                      idx < p.hourly.boundary_layer_height.count,
                      let m = p.hourly.boundary_layer_height[idx]
                else { return nil }
                return BLPoint(lat: p.latitude, lon: p.longitude, meters: m)
            }
        } catch {
            // Enrichment; fail quietly.
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
    var blPoints: [BLPoint] = []
    var showBL: Bool = false
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
        var shownArrows: [WindArrow] = []
        var arrowAnnotations: [WindArrowAnnotation] = []
        var shownBL: [BLPoint] = []
        var blAnnotations: [BLAnnotation] = []

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
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
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let bl = annotation as? BLAnnotation {
                let id = "blLabel"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? BLLabelView)
                    ?? BLLabelView(annotation: bl, reuseIdentifier: id)
                view.annotation = bl
                view.set(feet: bl.meters * 3.281)
                return view
            }
            guard let wind = annotation as? WindArrowAnnotation else { return nil }
            let id = "windArrow"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKAnnotationView(annotation: wind, reuseIdentifier: id)
            view.annotation = wind
            let cfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            view.image = UIImage(systemName: "arrow.up", withConfiguration: cfg)?
                .withTintColor(.label, renderingMode: .alwaysOriginal)
            // Wind FROM fromDeg blows TOWARD fromDeg+180 — point the arrow with the flow.
            view.transform = CGAffineTransform(
                rotationAngle: CGFloat((wind.fromDeg + 180) * .pi / 180))
            // Stronger wind, more present arrow.
            view.alpha = 0.45 + min(0.35, CGFloat(wind.speedKmh) / 80)
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
        context.coordinator.syncArrows(showWind ? windArrows : [], on: map)
        context.coordinator.syncBL(showBL ? blPoints : [], on: map)

        guard frames.indices.contains(index) else { return }
        context.coordinator.setCurrent(frames[index].time)
    }
}

// MARK: - Sheet

/// Sheet wrapper around RadarPanel (the compact-width presentation). On iPad the
/// dashboard embeds RadarPanel directly, no navigation chrome.
struct RadarView: View {
    let lat: Double
    let lon: Double
    let stationName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            RadarPanel(lat: lat, lon: lon, stationName: stationName)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .navigationTitle("Radar")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
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
    private let ticker = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()

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
            if showWindArrows {
                await model.fetchWind(region: model.lastRegion ?? initialRegion)
            }
            if showBoundaryLayer {
                await model.fetchBoundaryLayer(region: model.lastRegion ?? initialRegion)
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

    private var content: some View {
        VStack(spacing: 10) {
            RadarMapView(host: model.host,
                         frames: model.frames,
                         index: model.index,
                         center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                         windArrows: model.windArrows,
                         showWind: showWindArrows,
                         blPoints: model.blPoints,
                         showBL: showBoundaryLayer,
                         onRegionChange: { region in
                             model.scheduleFieldReload(for: region,
                                                       wind: showWindArrows,
                                                       boundaryLayer: showBoundaryLayer)
                         })
                .clipShape(RoundedRectangle(cornerRadius: 12))
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

            if embedded {
                // Two short rows — one row of buttons + swatches doesn't fit
                // the portrait column and SwiftUI "fixes" that by wrapping the
                // button titles mid-word.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        compactToggle("Wind", icon: "wind", isOn: $showWindArrows)
                        compactToggle("Layer top", icon: "cloud.fog", isOn: $showBoundaryLayer)
                        Spacer()
                    }
                    HStack(spacing: 14) {
                        swatch(Color(red: 0.55, green: 0.75, blue: 0.95), "Light")
                        swatch(Color(red: 0.13, green: 0.42, blue: 0.82), "Moderate")
                        swatch(Color(red: 0.94, green: 0.65, blue: 0.15), "Heavy")
                        Spacer()
                    }
                }
            } else {
                Toggle(isOn: $showWindArrows) {
                    Label("Wind arrows", systemImage: "wind")
                        .font(.subheadline)
                }

                Toggle(isOn: $showBoundaryLayer) {
                    Label("Boundary layer top", systemImage: "cloud.fog")
                        .font(.subheadline)
                }
                if showBoundaryLayer {
                    Text("Model boundary layer top in feet above ground. Bumpy, hazy air mixes below it, smoother air above. Thermals top out near it.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                legend
            }
        }
        // Fetch triggers live on the container so the compact and full toggle
        // variants share them.
        .onChange(of: showWindArrows) { _, on in
            if on {
                Task { await model.fetchWind(region: model.lastRegion ?? initialRegion) }
            }
        }
        .onChange(of: showBoundaryLayer) { _, on in
            if on {
                Task { await model.fetchBoundaryLayer(region: model.lastRegion ?? initialRegion) }
            }
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
        var text = "\(stationName) marked. Arrows point with the wind and show above ~8 kts. "
        text += RadarModel.modelFramesEnabled
            ? "Orange frames are a short nowcast; purple frames are HRRR model reflectivity via Iowa Environmental Mesonet, a model guess about where rain will be, not a measurement. "
            : "Forecast frames show in orange on the timeline. "
        text += "Radar tiles by RainViewer, data from NOAA NEXRAD. Wind and boundary layer by Open-Meteo."
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
