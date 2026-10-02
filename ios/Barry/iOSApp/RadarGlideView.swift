//  RadarGlideView.swift
//  Barry — iOS
//
//  The radar loop drawn by the GPU, with the rain moving between frames
//  instead of fading in place.
//
//  MapKit's tile layers can only crossfade: for half a second a storm is two
//  ghosts, the old position fading out and the new fading in, then it jumps.
//  Here each pixel asks where its rain came from. The server has worked out
//  how the rain moved between the two frames either side of the moment (the
//  same block matching the nowcast is built on, /radar/motion); the earlier
//  frame is read that far forward along the motion, the later one that far
//  back, and the two are blended, leaning to the nearer. Where the motion is
//  right the two agree and one shape travels; where the rain also grew or
//  died, the blend fills it in or thins it out over the gap.
//
//  The pictures are the same tiles the map downloads (RadarTileOverlay's own
//  caches), read back to dBZ and laid side by side into one texture a
//  frame, so nothing more comes over the network. Barry's colours are a
//  lookup in the shader, so the tiles are never repainted for this.
//
//  A view on top of the map, as the wind's streaks are, following the
//  map's visible rectangle each frame. The tile layers go to zero while it
//  shows and come back when the loop stops.

import MapKit
import Metal
import UIKit

final class RadarGlideView: UIView {
    weak var mapView: MKMapView?
    /// The loop's clock, in seconds; nil when nothing is playing.
    var clock: (() -> Double?)?
    /// The loop's frames in order.
    var frames: [RadarFrame] = [] {
        didSet {
            guard frames.map(\.key) != oldValue.map(\.key) else { return }
            let keys = Set(frames.map(\.key))
            textures = textures.filter { keys.contains($0.key) }
            lastDrawn = []
        }
    }
    /// The rain's motion between the loop's frames, when it has arrived.
    var motion: (() -> RadarMotionField?)?
    /// How much ink the rain gets (the tile layers' own alpha).
    var rainAlpha: Float = 0.75 { didSet { if rainAlpha != oldValue { lastDrawn = [] } } }
    /// The tiles the view on screen needs (Coordinator.tiles), and one
    /// frame's codes for a tile, from the caches or the network.
    var tileSet: (() -> [MKTileOverlayPath])?
    var codes: ((Int, MKTileOverlayPath, @escaping (RadarGlide.TileCodes?) -> Void) -> Void)?
    /// Called once, after the first picture is on screen: the moment the
    /// tile layers can go.
    var onFirstDraw: (() -> Void)?

    private var drawn = false
    /// The moment to hold on when the clock stops.
    private var frozen: Double?
    private var link: CADisplayLink?
    private var lastDrawn: [Double] = []
    private var setVersion = 0

    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private var palette: MTLTexture?
    private var blank: MTLTexture?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        // Found by the UI test, which checks the loop is the GPU's. Only
        // then is it an element at all: for VoiceOver it would sit over the
        // map's own stations and pins.
        accessibilityIdentifier = "radar.glide"
        isAccessibilityElement = UITestSupport.active
        setUpMetal()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// Hold on one frame, exactly, until the clock runs again: what the
    /// tile layer shows once it is back.
    func freeze(at key: Int) {
        guard let f = frames.first(where: { $0.key == key }) else { return }
        frozen = Double(f.time)
        lastDrawn = []
    }

    /// The map settled somewhere else: the pictures are laid out again for
    /// what is on screen now. The old ones stay up meanwhile.
    func mapDidMove() {
        setVersion += 1
        lastDrawn = []
    }

    // MARK: Shaders

    private struct Uniforms {
        var wxAB: SIMD2<Float>        // world x = a * (x across the view, 0 to 1) + b
        var wyAB: SIMD2<Float>        // world y = a * (y down the view, 0 to 1) + b
        var originA: SIMD2<Float>     // where picture A starts in the world,
        var invSizeA: SIMD2<Float>    // and one over how much of it it covers
        var originB: SIMD2<Float>
        var invSizeB: SIMD2<Float>
        var sizeA: SIMD2<Float>       // texels
        var sizeB: SIMD2<Float>
        var lonAB: SIMD2<Float>       // motion u = a * longitude + b
        var latAB: SIMD2<Float>       // motion v = a * latitude + b
        var hoursA: Float             // since frame A
        var hoursB: Float             // to frame B
        var mixT: Float
        var alpha: Float
        var hasA: Int32
        var hasB: Int32
        var hasMotion: Int32
        var pad: Int32
    }

    // Compiled on the device, as the wind's are (see WindFlowView).
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 wxAB;
        float2 wyAB;
        float2 originA;
        float2 invSizeA;
        float2 originB;
        float2 invSizeB;
        float2 sizeA;
        float2 sizeB;
        float2 lonAB;
        float2 latAB;
        float hoursA;
        float hoursB;
        float mixT;
        float alpha;
        int hasA;
        int hasB;
        int hasMotion;
        int pad;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 s;
    };

    vertex VertexOut glide_vertex(uint vid [[vertex_id]]) {
        // One triangle that covers the view.
        float2 p = float2((vid << 1) & 2, vid & 2);
        VertexOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.s = float2(p.x, 1.0 - p.y);
        return out;
    }

    // A picture read at a point: the four pixels around it weighed by
    // nearness, as (the sum of their codes where there is rain, how much
    // of the point is rain). Read together, the edge of the rain fades
    // out instead of dropping toward the lightest colour, and a pixel
    // that is rain in one frame and not the other fades between them.
    static float2 rain(texture2d<float> t, float2 uv, float2 size) {
        if (any(uv < 0.0) || any(uv > 1.0)) { return float2(0.0); }
        float2 p = uv * size - 0.5;
        float2 i = floor(p);
        float2 f = p - i;
        float2 lo = clamp(i, float2(0.0), size - 1.0);
        float2 hi = clamp(i + 1.0, float2(0.0), size - 1.0);
        float4 c = float4(t.read(uint2(lo.x, lo.y)).r, t.read(uint2(hi.x, lo.y)).r,
                          t.read(uint2(lo.x, hi.y)).r, t.read(uint2(hi.x, hi.y)).r);
        float4 w = float4((1.0 - f.x) * (1.0 - f.y), f.x * (1.0 - f.y), (1.0 - f.x) * f.y, f.x * f.y);
        float4 has = step(0.001, c);
        return float2(dot(w, c * has), dot(w, has));
    }

    fragment float4 glide_fragment(VertexOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(0)]],
                                   texture2d<float> a [[texture(0)]],
                                   texture2d<float> b [[texture(1)]],
                                   texture2d<float> motion [[texture(2)]],
                                   texture2d<float> palette [[texture(3)]],
                                   sampler smp [[sampler(0)]]) {
        float2 w = float2(u.wxAB.x * in.s.x + u.wxAB.y, u.wyAB.x * in.s.y + u.wyAB.y);
        float2 m = float2(0.0);
        if (u.hasMotion) {
            float lon = w.x * 360.0 - 180.0;
            float lat = atan(sinh(3.14159265 * (1.0 - 2.0 * w.y))) * 57.29577951;
            float2 muv = float2(u.lonAB.x * lon + u.lonAB.y, u.latAB.x * lat + u.latAB.y);
            if (all(muv >= 0.0) && all(muv <= 1.0)) { m = motion.sample(smp, muv).rg; }
        }
        // Frame A pushed forward to the moment, frame B pulled back to it.
        float2 sa = u.hasA ? rain(a, (w - m * u.hoursA - u.originA) * u.invSizeA, u.sizeA) : float2(0.0);
        float2 sb = u.hasB ? rain(b, (w + m * u.hoursB - u.originB) * u.invSizeB, u.sizeB) : float2(0.0);
        float2 s = (u.hasA && u.hasB) ? mix(sa, sb, u.mixT) : (u.hasA ? sa : sb);
        if (s.y < 0.01) { discard_fragment(); }
        uint idx = uint(round(clamp(s.x / s.y, 0.0, 1.0) * 255.0));
        float4 c = palette.read(uint2(idx, 0));
        float alpha = c.a * s.y * u.alpha;
        return float4(c.rgb * alpha, alpha);
    }
    """

    private static var compiled: MTLLibrary?

    private static func library(for device: MTLDevice) -> MTLLibrary? {
        if let lib = compiled { return lib }
        do {
            let lib = try device.makeLibrary(source: shaderSource, options: nil)
            compiled = lib
            return lib
        } catch {
            NSLog("RadarGlideView: the shaders did not compile: %@", "\(error)")
            return nil
        }
    }

    /// False when the device has no Metal or the shaders did not compile:
    /// the loop then plays on the tile layers, crossfading, as before.
    static let isAvailable: Bool = {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return library(for: device) != nil
    }()

    private func setUpMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        self.device = device
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        queue = device.makeCommandQueue()

        guard let library = Self.library(for: device),
              let vertexFn = library.makeFunction(name: "glide_vertex"),
              let fragmentFn = library.makeFunction(name: "glide_fragment") else { return }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
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

        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: s)

        // Barry's colour for each code (dBZ plus 32), straight, not
        // premultiplied; the shader does that after the blend.
        let pd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 1, mipmapped: false)
        pd.usage = .shaderRead
        var texels = [UInt8](repeating: 0, count: 256 * 4)
        for i in 1..<256 {
            let c = RadarPalette.color(dBZ: i - 32)
            texels[i * 4] = UInt8((c.r * 255).rounded())
            texels[i * 4 + 1] = UInt8((c.g * 255).rounded())
            texels[i * 4 + 2] = UInt8((c.b * 255).rounded())
            texels[i * 4 + 3] = UInt8((c.a * 255).rounded())
        }
        palette = device.makeTexture(descriptor: pd)
        texels.withUnsafeBytes { raw in
            palette?.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: 256 * 4)
        }
        // Stands in for a picture or a motion field that is not there.
        let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: 1, height: 1, mipmapped: false)
        bd.usage = .shaderRead
        blank = device.makeTexture(descriptor: bd)
        var zero: (Float16, Float16) = (0, 0)
        withUnsafeBytes(of: &zero) { raw in
            blank?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: 4)
        }
    }

    // MARK: The pictures

    /// One frame's tiles as one texture, and where it sits in the world.
    private struct Picture {
        let key: Int
        let set: RadarGlide.TileSet
        let texture: MTLTexture
    }

    private var textures: [Int: Picture] = [:]
    private var building: Set<String> = []
    private static let buildQueue = DispatchQueue(label: "me.wvr.barry.radar-glide", qos: .userInitiated)

    /// Have a frame's picture for the tile set, building it if the one
    /// held is for another set or there is none.
    private func ensure(_ key: Int, set: RadarGlide.TileSet) {
        if textures[key]?.set == set { return }
        let id = "\(key)@\(set.z)/\(set.x0)-\(set.x1)/\(set.y0)-\(set.y1)"
        guard !building.contains(id), let codes, let device else { return }
        building.insert(id)
        let paths = set.paths
        let got = Locked<[(x: Int, y: Int, codes: RadarGlide.TileCodes?)]>([])
        let left = Locked(paths.count)
        for path in paths {
            codes(key, path) { [weak self] tile in
                got.withLock { $0.append((path.x, path.y, tile)) }
                guard left.withLock({ $0 -= 1; return $0 }) == 0 else { return }
                Self.buildQueue.async {
                    let tiles = got.value
                    let side = tiles.compactMap { $0.codes?.side }.max() ?? 0
                    var picture: Picture?
                    if let bytes = RadarGlide.stitch(set, tiles: tiles, side: side) {
                        let w = set.columns * side, h = set.rows * side
                        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
                        d.usage = .shaderRead
                        if let tex = device.makeTexture(descriptor: d) {
                            bytes.withUnsafeBytes { raw in
                                tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: w)
                            }
                            picture = Picture(key: key, set: set, texture: tex)
                        }
                    }
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.building.remove(id)
                        if let picture, self.frames.contains(where: { $0.key == key }) {
                            self.textures[key] = picture
                            self.lastDrawn = []
                        }
                    }
                }
            }
        }
    }

    // MARK: The motion

    private var motionTexture: (field: UUID, pair: RadarMotionField.Pair, texture: MTLTexture, lonAB: SIMD2<Float>, latAB: SIMD2<Float>)?

    private func motionTexture(for field: RadarMotionField, start: Int, end: Int) -> MTLTexture? {
        let pair = RadarMotionField.Pair(start: start, end: end)
        if let held = motionTexture, held.field == field.id, held.pair == pair { return held.texture }
        guard let device, let p = field.pair(from: start, to: end) else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: field.nx, height: field.ny, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        let texels = field.texels(for: p).map { Float16($0) }
        texels.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, field.nx, field.ny), mipmapLevel: 0, withBytes: raw.baseAddress!,
                        bytesPerRow: field.nx * 2 * MemoryLayout<Float16>.size)
        }
        // u = (lon - lon0) / (dlon * nx) + half a block: the lattice is of
        // block centres.
        let ax = 1 / (field.dlon * Double(field.nx)), ay = -1 / (field.dlat * Double(field.ny))
        let lonAB = SIMD2(Float(ax), Float(0.5 / Double(field.nx) - field.lon0 * ax))
        let latAB = SIMD2(Float(ay), Float(0.5 / Double(field.ny) - field.lat0 * ay))
        motionTexture = (field.id, pair, tex, lonAB, latAB)
        return tex
    }

    // MARK: Lifecycle

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = max(1, traitCollection.displayScale)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        lastDrawn = []
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window != nil ? start() : stop()
    }

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    // MARK: Drawing

    @objc private func tick() {
        guard let map = mapView, !frames.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        let t: Double
        if let running = clock?() {
            t = running
            frozen = nil
        } else if let held = frozen {
            t = held
        } else {
            return
        }
        let rect = map.visibleMapRect
        guard rect.size.width > 0 else { return }
        let times = frames.map(\.time)
        let at = RadarGlide.bracket(at: t, times: times)
        // The pictures for this moment and the next two frames, for what
        // is on screen; the rest are let go.
        if let paths = tileSet?(), let set = RadarGlide.TileSet(paths) {
            let wanted = RadarGlide.wanted(a: at.a, b: at.b, count: frames.count)
            let keys = Set(wanted.map { frames[$0].key })
            textures = textures.filter { keys.contains($0.key) }
            for i in wanted { ensure(frames[i].key, set: set) }
        }
        let a = textures[frames[at.a].key], b = textures[frames[at.b].key]
        guard a != nil || b != nil else { return }
        let field = motion?()
        let now = [t, rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
                   Double(a.map { ObjectIdentifier($0.texture).hashValue } ?? 0),
                   Double(b.map { ObjectIdentifier($0.texture).hashValue } ?? 0), Double(setVersion),
                   Double(field?.id.hashValue ?? 0)]
        guard now != lastDrawn else { return }
        lastDrawn = now
        render(a: a, b: b, at: at, times: times, field: field, rect: rect)
    }

    private func render(a: Picture?, b: Picture?, at: (a: Int, b: Int, f: Double), times: [Int],
                        field: RadarMotionField?, rect: MKMapRect) {
        guard let queue, let pipeline, let sampler, let palette, let blank,
              let drawable = metalLayer.nextDrawable() else { return }
        let world = MKMapSize.world.width
        var motionTex: MTLTexture? = nil
        if let field, at.a != at.b {
            motionTex = motionTexture(for: field, start: times[at.a], end: times[at.b])
        }
        let held = motionTexture
        let hoursA = Float(max(0, t(at, times) - Double(times[at.a])) / 3600)
        let hoursB = Float(max(0, Double(times[at.b]) - t(at, times)) / 3600)
        var u = Uniforms(
            wxAB: SIMD2(Float(rect.size.width / world), Float(rect.origin.x / world)),
            wyAB: SIMD2(Float(rect.size.height / world), Float(rect.origin.y / world)),
            originA: a.map { SIMD2(Float($0.set.origin.x), Float($0.set.origin.y)) } ?? .zero,
            invSizeA: a.map { SIMD2(Float(1 / $0.set.size.x), Float(1 / $0.set.size.y)) } ?? .zero,
            originB: b.map { SIMD2(Float($0.set.origin.x), Float($0.set.origin.y)) } ?? .zero,
            invSizeB: b.map { SIMD2(Float(1 / $0.set.size.x), Float(1 / $0.set.size.y)) } ?? .zero,
            sizeA: a.map { SIMD2(Float($0.texture.width), Float($0.texture.height)) } ?? .zero,
            sizeB: b.map { SIMD2(Float($0.texture.width), Float($0.texture.height)) } ?? .zero,
            lonAB: held?.lonAB ?? .zero,
            latAB: held?.latAB ?? .zero,
            hoursA: hoursA,
            hoursB: hoursB,
            mixT: Float(at.f),
            alpha: rainAlpha,
            hasA: a == nil ? 0 : 1,
            hasB: b == nil ? 0 : 1,
            hasMotion: motionTex == nil ? 0 : 1,
            pad: 0)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(a?.texture ?? blank, index: 0)
        encoder.setFragmentTexture(b?.texture ?? blank, index: 1)
        encoder.setFragmentTexture(motionTex ?? blank, index: 2)
        encoder.setFragmentTexture(palette, index: 3)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if !drawn {
            drawn = true
            buffer.addCompletedHandler { [weak self] _ in
                DispatchQueue.main.async { self?.onFirstDraw?() }
            }
        }
        buffer.present(drawable)
        buffer.commit()
    }

    /// The moment the bracket was made for.
    private func t(_ at: (a: Int, b: Int, f: Double), _ times: [Int]) -> Double {
        Double(times[at.a]) + at.f * Double(times[at.b] - times[at.a])
    }
}
