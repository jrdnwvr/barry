//  WindFlowView.swift
//  Barry — iOS
//
//  The wind as motion: translucent streaks that drift with the model wind,
//  faster and brighter where it blows harder, nearly still where it's calm.
//  Windy's idea with the volume turned down — a couple hundred particles,
//  short trails, opacity that follows speed — so the map stays a map.
//
//  Particles live in screen space and are advected through a wind field
//  interpolated (inverse-distance) from the same 7×5 Open-Meteo grid the arrows
//  use. Pans and zooms hide the layer and reseed it, which is what every flow
//  map does; nobody notices because the eye reads the motion, not the dots.

import MapKit
import UIKit

final class WindFlowView: UIView {
    weak var mapView: MKMapView?

    /// The wind grid — every sample, calm ones included.
    var samples: [WindArrow] = [] {
        didSet { rebuildField(); reseed() }
    }

    // Tunables: "less busy" lives here.
    private let particleCount = 220
    private let trailLength = 10
    private let pxPerKmh: CGFloat = 1.25       // 20 km/h -> 25 px/s
    private let minLife = 60, maxLife = 150    // frames at 30 fps
    private let fps = 30

    private struct Particle {
        var trail: [CGPoint]   // head last
        var age: Int
        var life: Int
        var speed: CGFloat     // km/h at the head, for opacity
    }

    private struct Sample { let x: CGFloat; let y: CGFloat; let u: CGFloat; let v: CGFloat }
    private var field: [Sample] = []           // in local km around the field's center
    private var fieldCenter = CLLocationCoordinate2D()
    private var particles: [Particle] = []
    private var link: CADisplayLink?

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
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// Hide while the map is moving under us, then rebuild.
    func mapWillMove() { alpha = 0 }

    func mapDidMove() {
        reseed()
        UIView.animate(withDuration: 0.35) { self.alpha = 1 }
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

    /// Wind (u east, v north, km/h) at a screen point: inverse-distance over
    /// the grid, which is smooth enough for eyes and cheap enough for 30 fps.
    private func wind(at p: CGPoint) -> (u: CGFloat, v: CGFloat) {
        guard let map = mapView, !field.isEmpty else { return (0, 0) }
        let rect = map.visibleMapRect
        let mp = MKMapPoint(x: rect.origin.x + Double(p.x / bounds.width) * rect.size.width,
                            y: rect.origin.y + Double(p.y / bounds.height) * rect.size.height)
        let c = mp.coordinate
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

    // MARK: Particles

    func reseed() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        particles = (0..<particleCount).map { _ in spawn() }
        // Stagger ages so the whole field doesn't blink out in sync.
        for i in particles.indices { particles[i].age = Int.random(in: 0..<particles[i].life) }
        setNeedsDisplay()
    }

    private func spawn() -> Particle {
        let p = CGPoint(x: CGFloat.random(in: -10...(bounds.width + 10)),
                        y: CGFloat.random(in: -10...(bounds.height + 10)))
        return Particle(trail: [p], age: 0, life: Int.random(in: minLife...maxLife), speed: 0)
    }

    @objc private func tick() {
        guard !field.isEmpty, alpha > 0 else { return }
        let dt: CGFloat = 1 / CGFloat(fps)
        let margin: CGFloat = 20
        for i in particles.indices {
            var pt = particles[i]
            let head = pt.trail.last!
            let (u, v) = wind(at: head)
            let next = CGPoint(x: head.x + u * pxPerKmh * dt, y: head.y - v * pxPerKmh * dt)
            pt.trail.append(next)
            if pt.trail.count > trailLength { pt.trail.removeFirst() }
            pt.speed = hypot(u, v)
            pt.age += 1
            let gone = next.x < -margin || next.x > bounds.width + margin
                || next.y < -margin || next.y > bounds.height + margin
            particles[i] = (pt.age >= pt.life || gone) ? spawn() : pt
        }
        setNeedsDisplay()
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let base = UIColor.label
        ctx.setLineCap(.round)
        ctx.setLineWidth(1.6)
        for pt in particles where pt.trail.count >= 2 {
            // Speed sets presence; the trail fades toward its tail so the streak
            // reads as motion rather than a scratch.
            let presence = 0.12 + 0.55 * min(1, pt.speed / 45)
            // Fade in/out over the particle's life so births and deaths are quiet.
            let lifeFade = min(1, CGFloat(pt.age) / 15, CGFloat(pt.life - pt.age) / 15)
            let n = pt.trail.count
            for k in 1..<n {
                let f = CGFloat(k) / CGFloat(n - 1)
                ctx.setStrokeColor(base.withAlphaComponent(presence * lifeFade * f).cgColor)
                ctx.beginPath()
                ctx.move(to: pt.trail[k - 1])
                ctx.addLine(to: pt.trail[k])
                ctx.strokePath()
            }
        }
    }
}
