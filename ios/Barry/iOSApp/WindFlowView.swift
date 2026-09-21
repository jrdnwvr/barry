//  WindFlowView.swift
//  Barry — iOS
//
//  The wind as motion: translucent streaks that drift with the model wind,
//  faster and darker where it blows harder, nearly still where it's calm.
//  Windy's idea with the volume turned down — a couple hundred particles,
//  short trails — so the map stays a map.
//
//  Particles are anchored to the GROUND, not the screen: a trail is a list of
//  map points, converted to screen only when it's drawn. Panning and zooming
//  therefore carry the streaks along with the terrain instead of blanking the
//  layer and starting over, which is what a pan used to cost.
//
//  Speed drives tone as well as presence. The fastest streaks are drawn in the
//  foreground colour and slower ones wash out toward the map's own background
//  tone before fading away, so on a light map the quick air is near black and
//  on a dark one it's near white. The ramp is neutral grey on purpose: it has
//  to stay legible on top of the pressure and change shading without fighting
//  those palettes for hue.

import MapKit
import UIKit

final class WindFlowView: UIView {
    weak var mapView: MKMapView?

    /// True inside the dashboard card, where the thing being dragged is the
    /// page and not the map. The display link then runs in the default run
    /// loop mode, so it stands down while a scroll is tracking and the list
    /// gets the main thread to itself. The full screen map keeps common mode,
    /// because there a drag IS the map and the streaks have to keep up.
    var yieldsToScrolling = false {
        didSet { if yieldsToScrolling != oldValue, link != nil { stop(); start() } }
    }

    /// The wind grid — every sample, calm ones included.
    var samples: [WindArrow] = [] {
        didSet {
            rebuildField()
            // A fresh grid should bend the streaks that are already flying,
            // not restart them. Only seed when there is nothing on screen.
            if particles.isEmpty { reseed() }
        }
    }

    // Tunables: "less busy" lives here.
    /// Particles per unit of view area, so the dashboard's card does
    /// proportionally less work than the full screen.
    private var targetParticles: Int {
        max(70, min(240, Int(bounds.width * bounds.height / 1150)))
    }
    private let trailLength = 18               // points kept in the streak
    private let trailStride = 3                // frames between kept points
    private let pxPerKmh: CGFloat = 1.25       // 20 km/h -> 25 px/s on screen
    private let minLife = 90, maxLife = 180    // frames at 30 fps
    private let fps = 30
    /// The speed that reads as full strength on the ramp.
    private let fastKmh: CGFloat = 45

    private struct Particle {
        var trail: [MKMapPoint]   // on the ground, oldest first
        var head: MKMapPoint      // current position, moved every frame
        var age: Int
        var life: Int
        var speed: CGFloat        // km/h at the head, for tone and presence
        var sinceSample: Int
    }

    private struct Sample { let x: CGFloat; let y: CGFloat; let u: CGFloat; let v: CGFloat }
    private var field: [Sample] = []           // in local km around the field's center
    private var fieldCenter = CLLocationCoordinate2D()
    private var particles: [Particle] = []
    private var link: CADisplayLink?
    private var lastScale: Double = 0

    /// Greyscale ramp from the map's background tone to its foreground, built
    /// once per appearance rather than per particle per frame.
    private var ramp: [UIColor] = []
    private var rampStyle: UIUserInterfaceStyle = .unspecified
    private static let rampSteps = 16
    /// Every colour the layer can stroke, [tone][alpha], resolved once. Making
    /// these per segment meant allocating a CGColor tens of thousands of times
    /// a second, which the dashboard paid for in dropped scroll frames.
    private var inks: [[CGColor]] = []
    private static let alphaSteps = 10
    /// taper[n][k] = (k/n)^1.8, the fade along a trail of n points.
    private var taper: [[CGFloat]] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    // MARK: Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stop() : start()
    }

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: Float(fps), preferred: Float(fps))
        l.add(to: .main, forMode: yieldsToScrolling ? .default : .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// The map moved. Streaks ride the ground, so a pan needs nothing at all.
    /// A zoom leaves fresh territory empty, so top it up: respawn whatever has
    /// gone off screen, plus a slice of the rest when the scale really changed.
    func mapDidMove() {
        guard bounds.width > 0, let map = mapView else { return }
        let rect = map.visibleMapRect
        let scale = rect.size.width / Double(bounds.width)
        let zoomed = lastScale > 0 && abs(log2(scale / lastScale)) > 0.3
        lastScale = scale
        guard !particles.isEmpty else { return }
        for i in particles.indices {
            let s = Self.screen(particles[i].head, rect: rect, scale: scale)
            let off = s.x < 0 || s.x > bounds.width || s.y < 0 || s.y > bounds.height
            if off || (zoomed && Bool.random()) {
                particles[i] = spawn(rect: rect, scale: scale)
            }
        }
        setNeedsDisplay()
    }

    // MARK: Field

    private func rebuildField() {
        guard !samples.isEmpty else { field = []; return }
        let lat0 = samples.reduce(0) { $0 + $1.lat } / Double(samples.count)
        let lon0 = samples.reduce(0) { $0 + $1.lon } / Double(samples.count)
        fieldCenter = CLLocationCoordinate2D(latitude: lat0, longitude: lon0)
        field = samples.map { s in
            let (x, y) = Self.localKm(lat: s.lat, lon: s.lon, around: fieldCenter)
            // Meteorological direction is where the wind comes FROM.
            let rad = s.fromDeg * .pi / 180
            return Sample(x: x, y: y,
                          u: CGFloat(-s.speedKmh * sin(rad)),
                          v: CGFloat(-s.speedKmh * cos(rad)))
        }
    }

    private static func localKm(lat: Double, lon: Double, around c: CLLocationCoordinate2D) -> (CGFloat, CGFloat) {
        let kmPerDeg = 111.32
        return (CGFloat((lon - c.longitude) * kmPerDeg * cos(c.latitude * .pi / 180)),
                CGFloat((lat - c.latitude) * kmPerDeg))
    }

    /// Wind (u east, v north, km/h) on the ground at a map point:
    /// inverse-distance over the grid, smooth enough for eyes and cheap
    /// enough for 30 fps.
    private func wind(at p: MKMapPoint) -> (u: CGFloat, v: CGFloat) {
        guard !field.isEmpty else { return (0, 0) }
        let c = p.coordinate
        let (x, y) = Self.localKm(lat: c.latitude, lon: c.longitude, around: fieldCenter)
        var wu: CGFloat = 0, wv: CGFloat = 0, wsum: CGFloat = 0
        for s in field {
            let d2 = (s.x - x) * (s.x - x) + (s.y - y) * (s.y - y)
            if d2 < 1 { return (s.u, s.v) }
            let w = 1 / d2
            wu += s.u * w; wv += s.v * w; wsum += w
        }
        return wsum > 0 ? (wu / wsum, wv / wsum) : (0, 0)
    }

    // MARK: Map <-> screen

    private static func screen(_ p: MKMapPoint, rect: MKMapRect, scale: Double) -> CGPoint {
        CGPoint(x: CGFloat((p.x - rect.origin.x) / scale),
                y: CGFloat((p.y - rect.origin.y) / scale))
    }

    private static func ground(_ p: CGPoint, rect: MKMapRect, scale: Double) -> MKMapPoint {
        MKMapPoint(x: rect.origin.x + Double(p.x) * scale,
                   y: rect.origin.y + Double(p.y) * scale)
    }

    // MARK: Particles

    func reseed() {
        guard bounds.width > 0, bounds.height > 0, let map = mapView else { return }
        let rect = map.visibleMapRect
        let scale = rect.size.width / Double(bounds.width)
        lastScale = scale
        particles = (0..<targetParticles).map { _ in spawn(rect: rect, scale: scale) }
        // Stagger ages so the whole field doesn't blink out in sync.
        for i in particles.indices { particles[i].age = Int.random(in: 0..<particles[i].life) }
        setNeedsDisplay()
    }

    private func spawn(rect: MKMapRect, scale: Double) -> Particle {
        let p = CGPoint(x: CGFloat.random(in: -10...(bounds.width + 10)),
                        y: CGFloat.random(in: -10...(bounds.height + 10)))
        let m = Self.ground(p, rect: rect, scale: scale)
        return Particle(trail: [m], head: m, age: 0,
                        life: Int.random(in: minLife...maxLife), speed: 0, sinceSample: 0)
    }

    @objc private func tick() {
        guard !field.isEmpty, alpha > 0, bounds.width > 0, let map = mapView else { return }
        if particles.isEmpty { reseed(); return }
        let rect = map.visibleMapRect
        let scale = rect.size.width / Double(bounds.width)
        let dt: CGFloat = 1 / CGFloat(fps)
        let margin: CGFloat = 20
        for i in particles.indices {
            var pt = particles[i]
            let (u, v) = wind(at: pt.head)
            // The step is sized in screen points so the motion reads the same
            // at every zoom, then converted to map points so it lands on the
            // ground and stays there.
            let next = MKMapPoint(x: pt.head.x + Double(u * pxPerKmh * dt) * scale,
                                  y: pt.head.y - Double(v * pxPerKmh * dt) * scale)
            pt.head = next
            // The head moves every frame; the trail only records every few, so
            // the streak reaches further back without costing more strokes.
            pt.sinceSample += 1
            if pt.sinceSample >= trailStride {
                pt.sinceSample = 0
                pt.trail.append(next)
                if pt.trail.count > trailLength { pt.trail.removeFirst() }
            }
            pt.speed = hypot(u, v)
            pt.age += 1
            let s = Self.screen(next, rect: rect, scale: scale)
            let gone = s.x < -margin || s.x > bounds.width + margin
                || s.y < -margin || s.y > bounds.height + margin
            particles[i] = (pt.age >= pt.life || gone) ? spawn(rect: rect, scale: scale) : pt
        }
        setNeedsDisplay()
    }

    // MARK: Drawing

    /// Background tone to foreground tone in even steps. Neutral by
    /// construction, so it sits on the coloured field overlays without
    /// competing with them.
    private func rebuildRamp() {
        let traits = traitCollection
        let slow = UIColor.systemBackground.resolvedColor(with: traits)
        let fast = UIColor.label.resolvedColor(with: traits)
        ramp = (0...Self.rampSteps).map { i in
            // Reach most of the tone before top speed, so an ordinary breeze
            // still reads rather than sitting washed out at the pale end.
            Self.blend(slow, fast, pow(CGFloat(i) / CGFloat(Self.rampSteps), 0.7))
        }
        inks = ramp.map { c in
            (0...Self.alphaSteps).map {
                c.withAlphaComponent(CGFloat($0) / CGFloat(Self.alphaSteps)).cgColor
            }
        }
        rampStyle = traits.userInterfaceStyle
    }

    private func buildTaper() {
        taper = (0...trailLength).map { n in
            (0...max(1, n)).map { k in n <= 1 ? 1 : pow(CGFloat(k) / CGFloat(n), 1.8) }
        }
    }

    private static func blend(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(red: ar + (br - ar) * t, green: ag + (bg - ag) * t,
                       blue: ab + (bb - ab) * t, alpha: 1)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let map = mapView, bounds.width > 0 else { return }
        if inks.isEmpty || rampStyle != traitCollection.userInterfaceStyle { rebuildRamp() }
        if taper.isEmpty { buildTaper() }
        let mrect = map.visibleMapRect
        let scale = mrect.size.width / Double(bounds.width)

        // Collect every segment into one path per (tone, alpha) pair, then
        // stroke each pair once. Same picture as stroking segment by segment,
        // for a tiny fraction of the Core Graphics calls.
        let alphas = Self.alphaSteps + 1
        var paths = [CGMutablePath?](repeating: nil, count: (Self.rampSteps + 1) * alphas)

        @inline(__always) func add(_ idx: Int, _ from: CGPoint, _ to: CGPoint) {
            let path: CGMutablePath
            if let existing = paths[idx] { path = existing } else {
                path = CGMutablePath()
                paths[idx] = path
            }
            path.move(to: from)
            path.addLine(to: to)
        }

        for pt in particles where !pt.trail.isEmpty {
            // Speed sets tone and presence together: quick air is dark and
            // solid, calm air washes to the map's own tone and disappears.
            let t = min(1, pt.speed / fastKmh)
            let tone = min(Self.rampSteps, Int(t * CGFloat(Self.rampSteps)))
            let presence = 0.10 + 0.55 * t
            // Fade in/out over the particle's life so births and deaths are quiet.
            let lifeFade = min(1, CGFloat(pt.age) / 15, CGFloat(pt.life - pt.age) / 15)
            let strength = presence * lifeFade
            guard strength > 0.015 else { continue }
            let n = pt.trail.count
            let row = taper[min(n, trailLength)]
            let base = tone * alphas
            var prev = Self.screen(pt.trail[0], rect: mrect, scale: scale)
            for k in 1..<n {
                let cur = Self.screen(pt.trail[k], rect: mrect, scale: scale)
                // Taper hard toward the tail: a long streak stays light on the
                // map, and the bright end shows which way the wind is going.
                let step = Int(strength * row[min(k, row.count - 1)] * CGFloat(Self.alphaSteps) + 0.5)
                if step > 0 { add(base + step, prev, cur) }
                prev = cur
            }
            // The live segment from the last sample to the head, at full presence.
            let step = Int(strength * CGFloat(Self.alphaSteps) + 0.5)
            if step > 0 {
                add(base + step, prev, Self.screen(pt.head, rect: mrect, scale: scale))
            }
        }

        ctx.setLineCap(.round)
        ctx.setLineWidth(1.6)
        for idx in paths.indices {
            guard let path = paths[idx] else { continue }
            ctx.setStrokeColor(inks[idx / alphas][idx % alphas])
            ctx.addPath(path)
            ctx.strokePath()
        }
    }
}
