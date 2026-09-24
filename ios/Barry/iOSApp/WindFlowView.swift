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
//  Drawing is Metal. The simulation stays on the CPU, because a couple of
//  hundred particles is nothing, but each frame's segments are expanded into
//  quads and handed over as ONE buffer for ONE draw call. The Core Graphics
//  path this replaced re-rasterized the whole view on the main thread thirty
//  times a second, which is what the dashboard was paying for.
//
//  Speed drives tone as well as presence. The fastest streaks are drawn in the
//  foreground colour and slower ones wash out toward the map's own background
//  tone before fading away, so on a light map the quick air is near black and
//  on a dark one it's near white. The ramp is neutral grey on purpose: it has
//  to stay legible on top of the pressure and change shading without fighting
//  those palettes for hue.

import MapKit
import Metal
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

    /// False once the card has scrolled out of sight. Nothing is watching, so
    /// there is nothing to animate for.
    var isActive = true {
        didSet { if isActive != oldValue { syncLink() } }
    }

    /// The wind grid — every sample, calm ones included.
    var samples: [WindArrow] = [] {
        didSet {
            rebuildField()
            if field.isEmpty { clear(); return }
            // A fresh grid should bend the streaks that are already flying,
            // not restart them. Only seed when there is nothing on screen.
            if particles.isEmpty { reseed() }
        }
    }

    // Tunables: "less busy" lives here.
    /// Particles per unit of view area, so the dashboard's card does
    /// proportionally less work than the full screen.
    private var targetParticles: Int {
        max(70, min(Self.maxParticles, Int(bounds.width * bounds.height / 1150)))
    }
    private static let maxParticles = 240
    private let trailLength = WindFlowView.maxTrailLength   // points kept in the streak
    private let trailStride = 3                // frames between kept points
    /// 20 km/h -> 38 px/s on screen. Trail length is speed times the trail's
    /// duration, so this is also what stops a 3 kt breeze from drawing a
    /// twelve pixel smudge nobody can see.
    /// Screen speed per km/h. Eased down as the ramp rises for winds aloft,
    /// so a 130 km/h jet reads as fast without tearing across the map.
    private var pxPerKmh: CGFloat { 1.9 * sqrt(35 / max(35, rampKmh)) }
    private let minLife = 90, maxLife = 180    // frames at 30 fps
    private let fps = 30
    private let lineWidth: CGFloat = 1.6
    /// The speed that reads as full strength on the ramp. 35 km/h is about
    /// 19 kt: a brisk day, not a gale. The old 45 put an ordinary 5 to 10 kt
    /// breeze so far down the ramp that it drew in the map's own background
    /// tone at barely any opacity, which read as the layer being broken.
    var rampKmh: CGFloat = 35
    private var fastKmh: CGFloat { rampKmh }

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

    /// Greyscale ramp from the map's background tone to its foreground, as raw
    /// bytes because that is what goes into the vertex buffer.
    private var toneRGB: [(UInt8, UInt8, UInt8)] = []
    private var rampStyle: UIUserInterfaceStyle = .unspecified
    private static let rampSteps = 16
    /// taper[n][k] = (k/n)^1.8, the fade along a trail of n points.
    private var taper: [[CGFloat]] = []

    // MARK: Metal

    /// One quad per segment, six vertices each, every trail full.
    private static let maxVertices = maxParticles * maxTrailLength * 6
    private static let maxTrailLength = 18

    private struct FlowVertex {
        var x: Float
        var y: Float
        var r: UInt8
        var g: UInt8
        var b: UInt8
        var a: UInt8
    }

    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    /// Three vertex buffers in rotation, fenced by a semaphore, so the CPU
    /// never rewrites a buffer the GPU is still reading. One shared buffer
    /// tore a frame whenever the GPU fell behind a tick.
    private var vertexBuffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private let inflight = DispatchSemaphore(value: 3)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        setUpMetal()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    private func setUpMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        queue = device.makeCommandQueue()

        guard let library = device.makeDefaultLibrary(),
              let vertexFn = library.makeFunction(name: "wind_vertex"),
              let fragmentFn = library.makeFunction(name: "wind_fragment") else { return }

        let layout = MTLVertexDescriptor()
        layout.attributes[0].format = .float2
        layout.attributes[0].offset = 0
        layout.attributes[0].bufferIndex = 0
        layout.attributes[1].format = .uchar4Normalized
        layout.attributes[1].offset = MemoryLayout<Float>.size * 2
        layout.attributes[1].bufferIndex = 0
        layout.layouts[0].stride = MemoryLayout<FlowVertex>.stride

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.vertexDescriptor = layout
        if let colour = desc.colorAttachments[0] {
            colour.pixelFormat = .bgra8Unorm
            colour.isBlendingEnabled = true
            colour.rgbBlendOperation = .add
            colour.alphaBlendOperation = .add
            // The fragment shader premultiplies, so the source factors are one.
            colour.sourceRGBBlendFactor = .one
            colour.sourceAlphaBlendFactor = .one
            colour.destinationRGBBlendFactor = .oneMinusSourceAlpha
            colour.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        pipeline = try? device.makeRenderPipelineState(descriptor: desc)
        vertexBuffers = (0..<3).compactMap { _ in
            device.makeBuffer(length: Self.maxVertices * MemoryLayout<FlowVertex>.stride,
                              options: .storageModeShared)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = max(1, traitCollection.displayScale)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if particles.isEmpty { reseed() }
    }

    // MARK: Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncLink()
    }

    private func syncLink() {
        (window != nil && isActive) ? start() : stop()
    }

    func start() {
        guard link == nil, isActive else { return }
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
    }

    private func spawn(rect: MKMapRect, scale: Double) -> Particle {
        let p = CGPoint(x: CGFloat.random(in: -10...(bounds.width + 10)),
                        y: CGFloat.random(in: -10...(bounds.height + 10)))
        let m = Self.ground(p, rect: rect, scale: scale)
        return Particle(trail: [m], head: m, age: 0,
                        life: Int.random(in: minLife...maxLife), speed: 0, sinceSample: 0)
    }

    @objc private func tick() {
        guard !field.isEmpty, bounds.width > 0, let map = mapView else { return }
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
            // the streak reaches further back without costing more vertices.
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
        render(mapRect: rect, scale: scale)
    }

    // MARK: Colour

    /// Background tone to foreground tone in even steps. Neutral by
    /// construction, so it sits on the coloured field overlays without
    /// competing with them.
    private func rebuildRamp() {
        let traits = traitCollection
        let slow = UIColor.systemBackground.resolvedColor(with: traits)
        let fast = UIColor.label.resolvedColor(with: traits)
        toneRGB = (0...Self.rampSteps).map { i in
            // Reach most of the tone before top speed, so an ordinary breeze
            // still reads rather than sitting washed out at the pale end.
            let c = Self.blend(slow, fast, pow(CGFloat(i) / CGFloat(Self.rampSteps), 0.4))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return (Self.byte(r), Self.byte(g), Self.byte(b))
        }
        rampStyle = traits.userInterfaceStyle
    }

    private static func byte(_ v: CGFloat) -> UInt8 {
        UInt8(max(0, min(255, (v * 255).rounded())))
    }

    private static func blend(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(red: ar + (br - ar) * t, green: ag + (bg - ag) * t,
                       blue: ab + (bb - ab) * t, alpha: 1)
    }

    private func buildTaper() {
        taper = (0...trailLength).map { n in
            (0...max(1, n)).map { k in n <= 1 ? 1 : pow(CGFloat(k) / CGFloat(n), 1.8) }
        }
    }

    // MARK: Rendering

    private func render(mapRect: MKMapRect, scale: Double) {
        guard let queue, let pipeline, vertexBuffers.count == 3,
              bounds.width > 0, bounds.height > 0 else { return }
        if toneRGB.isEmpty || rampStyle != traitCollection.userInterfaceStyle { rebuildRamp() }
        if taper.isEmpty { buildTaper() }

        // Wait for a buffer the GPU has finished with. Every early return
        // after this point must give the slot back.
        inflight.wait()
        let vertexBuffer = vertexBuffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % 3
        let count = fillVertices(into: vertexBuffer, mapRect: mapRect, scale: scale)

        guard let drawable = metalLayer.nextDrawable() else { inflight.signal(); return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { inflight.signal(); return }
        if count > 0 {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            var viewport = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
        }
        encoder.endEncoding()
        let fence = inflight
        buffer.addCompletedHandler { _ in fence.signal() }
        buffer.present(drawable)
        buffer.commit()
    }

    /// Present one empty frame. Used when the wind grid goes away, so the
    /// last streaks do not sit frozen on the map.
    private func clear() {
        guard let queue, let drawable = metalLayer.nextDrawable() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// Expand every visible trail segment into a quad. Returns the vertex count.
    private func fillVertices(into buffer: MTLBuffer, mapRect: MKMapRect, scale: Double) -> Int {
        let out = buffer.contents().bindMemory(to: FlowVertex.self, capacity: Self.maxVertices)
        let half = Float(lineWidth / 2)
        var n = 0
        for pt in particles where !pt.trail.isEmpty {
            // Speed sets tone and presence together: quick air is dark and
            // solid, calm air washes to the map's own tone and disappears.
            let t = min(1, pt.speed / fastKmh)
            let rgb = toneRGB[min(Self.rampSteps, Int(t * CGFloat(Self.rampSteps)))]
            // Floor it: calm air should be a whisper, not nothing at all.
            let presence = 0.26 + 0.45 * t
            // Fade in/out over the particle's life so births and deaths are quiet.
            let lifeFade = min(1, CGFloat(pt.age) / 15, CGFloat(pt.life - pt.age) / 15)
            let strength = presence * lifeFade
            guard strength > 0.015 else { continue }
            let cnt = pt.trail.count
            let row = taper[min(cnt, trailLength)]
            var prev = Self.screen(pt.trail[0], rect: mapRect, scale: scale)
            for k in 1..<cnt {
                let cur = Self.screen(pt.trail[k], rect: mapRect, scale: scale)
                // Taper hard toward the tail: a long streak stays light on the
                // map, and the bright end shows which way the wind is going.
                let alpha = Self.byte(strength * row[min(k, row.count - 1)])
                if alpha > 3, n + 6 <= Self.maxVertices {
                    n += Self.emit(out + n, prev, cur, rgb, alpha, half)
                }
                prev = cur
            }
            // The live segment from the last sample to the head, at full presence.
            let alpha = Self.byte(strength)
            if alpha > 3, n + 6 <= Self.maxVertices {
                let head = Self.screen(pt.head, rect: mapRect, scale: scale)
                n += Self.emit(out + n, prev, head, rgb, alpha, half)
            }
        }
        return n
    }

    @inline(__always)
    private static func emit(_ out: UnsafeMutablePointer<FlowVertex>,
                             _ a: CGPoint, _ b: CGPoint,
                             _ rgb: (UInt8, UInt8, UInt8), _ alpha: UInt8,
                             _ half: Float) -> Int {
        let ax = Float(a.x), ay = Float(a.y)
        let bx = Float(b.x), by = Float(b.y)
        let dx = bx - ax, dy = by - ay
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.001 else { return 0 }
        // Perpendicular, half a line width out on each side.
        let nx = -dy / len * half, ny = dx / len * half
        func v(_ x: Float, _ y: Float) -> FlowVertex {
            FlowVertex(x: x, y: y, r: rgb.0, g: rgb.1, b: rgb.2, a: alpha)
        }
        out[0] = v(ax + nx, ay + ny)
        out[1] = v(ax - nx, ay - ny)
        out[2] = v(bx + nx, by + ny)
        out[3] = v(bx + nx, by + ny)
        out[4] = v(ax - nx, ay - ny)
        out[5] = v(bx - nx, by - ny)
        return 6
    }
}
