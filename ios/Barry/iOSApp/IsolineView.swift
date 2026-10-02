//  IsolineView.swift
//  Barry — iOS
//
//  The six-hour loop's isobars, drawn by the GPU straight from the pressure
//  grids instead of as lines worked out on the CPU.
//
//  The lines used to be contoured from each moment's grid (marching squares)
//  and drawn by an MKOverlayRenderer. Two things were wrong with that when
//  the lines move. MapKit redraws such an overlay a tile at a time, each on
//  its own schedule, so a moving line was at two different moments either
//  side of a tile's edge and broke there. And a contour on a coarse grid is
//  straight between grid squares, joining and parting abruptly as the field
//  passes through a saddle.
//
//  Here every pixel asks what the pressure is under it: the two grids either
//  side of the moment, each read through a cubic filter (so the field, and
//  with it every line, is smooth), slid together, less the area's own rise
//  (PressureTimeline.pattern). Where that value crosses a multiple of the
//  spacing, the pixel is on a line, as wide as the screen derivative of the
//  value says a point and a half is. One quad, one draw call, the whole
//  screen at one moment.
//
//  It is a view on top of the map, as the wind's streaks are, and follows
//  the map's visible rectangle each frame.

import MapKit
import Metal
import UIKit

final class IsolineView: UIView {
    weak var mapView: MKMapView?
    /// The loop's clock, in seconds; nil when nothing is playing.
    var clock: (() -> Double?)?

    private var timeline: PressureTimeline?
    private var textures: [MTLTexture] = []
    private var link: CADisplayLink?
    private var lastDrawn: [Double] = []

    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        setUpMetal()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    /// The series to draw. The same one again costs nothing.
    func show(_ line: PressureTimeline) {
        guard line.id != timeline?.id else { return }
        timeline = line
        lastDrawn = []
        upload(line)
    }

    // MARK: Shaders

    private struct Uniforms {
        var lonAB: SIMD2<Float>       // grid u = a * (x across the view, 0 to 1) + b
        var mercAB: SIMD2<Float>      // Mercator n = a * (y down the view, 0 to 1) + b
        var latAB: SIMD2<Float>       // grid v = a * latitude in degrees + b
        var size: SIMD2<Float>        // grid points across and up
        var mix: Float                // how far from the first grid to the second
        var bias: Float               // added to the value before it is counted in steps
        var invStep: Float
        var halfWidth: Float          // of the line, in pixels
        var color: SIMD4<Float>
    }

    // Compiled on the device, as the wind's are (see WindFlowView).
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 lonAB;
        float2 mercAB;
        float2 latAB;
        float2 size;
        float mixT;
        float bias;
        float invStep;
        float halfWidth;
        float4 color;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 s;
    };

    vertex VertexOut isoline_vertex(uint vid [[vertex_id]]) {
        // One triangle that covers the view.
        float2 p = float2((vid << 1) & 2, vid & 2);
        VertexOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.s = float2(p.x, 1.0 - p.y);
        return out;
    }

    // The grid through a cubic B-spline, as four bilinear reads.
    static float2 cubic(texture2d<float> t, sampler smp, float2 uv, float2 size) {
        float2 x = uv * (size - 1.0);
        float2 i = floor(x);
        float2 f = x - i;
        float2 f2 = f * f, f3 = f2 * f;
        float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
        float2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
        float2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
        float2 w3 = f3 / 6.0;
        float2 g0 = w0 + w1, g1 = w2 + w3;
        float2 p0 = (i - 1.0 + w1 / g0 + 0.5) / size;
        float2 p1 = (i + 1.0 + w3 / g1 + 0.5) / size;
        return g0.y * (g0.x * t.sample(smp, float2(p0.x, p0.y)).rg + g1.x * t.sample(smp, float2(p1.x, p0.y)).rg)
             + g1.y * (g0.x * t.sample(smp, float2(p0.x, p1.y)).rg + g1.x * t.sample(smp, float2(p1.x, p1.y)).rg);
    }

    fragment float4 isoline_fragment(VertexOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     texture2d<float> a [[texture(0)]],
                                     texture2d<float> b [[texture(1)]],
                                     sampler smp [[sampler(0)]]) {
        float gu = u.lonAB.x * in.s.x + u.lonAB.y;
        float lat = atan(sinh(u.mercAB.x * in.s.y + u.mercAB.y)) * 57.29577951;
        float gv = u.latAB.x * lat + u.latAB.y;
        if (gu < 0.0 || gu > 1.0 || gv < 0.0 || gv > 1.0) { discard_fragment(); }
        float2 uv = float2(gu, gv);
        // Red is the value where there is one (else nothing), green whether
        // there is: read together, a cell with no data fades the line out
        // instead of dragging it toward zero.
        float2 s = mix(cubic(a, smp, uv, u.size), cubic(b, smp, uv, u.size), u.mixT);
        if (s.y < 0.5) { discard_fragment(); }
        float level = (s.x / s.y + u.bias) * u.invStep;
        float d = abs(fract(level - 0.5) - 0.5);
        float w = max(fwidth(level), 1e-6);
        float line = clamp(u.halfWidth + 0.5 - d / w, 0.0, 1.0);
        float alpha = line * u.color.a * smoothstep(0.5, 0.95, s.y);
        return float4(u.color.rgb * alpha, alpha);
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
            NSLog("IsolineView: the shaders did not compile: %@", "\(error)")
            return nil
        }
    }

    /// False when the device has no Metal or the shaders did not compile:
    /// the map then keeps drawing the lines the old way.
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
              let vertexFn = library.makeFunction(name: "isoline_vertex"),
              let fragmentFn = library.makeFunction(name: "isoline_fragment") else { return }
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
    }

    /// One texture a frame: the value less the series' base where there is
    /// one, and whether there is. Half floats, which every iPhone's GPU can
    /// filter (it cannot be relied on for full ones).
    private func upload(_ line: PressureTimeline) {
        textures = []
        guard let device else { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: line.nx,
                                                            height: line.ny, mipmapped: false)
        desc.usage = .shaderRead
        for i in 0..<line.frameCount {
            guard let tex = device.makeTexture(descriptor: desc) else { textures = []; return }
            var texels = [Float16](repeating: 0, count: line.nx * line.ny * 2)
            for (k, v) in line.offsets(i).enumerated() where v.isFinite {
                texels[k * 2] = Float16(v)
                texels[k * 2 + 1] = 1
            }
            texels.withUnsafeBytes { raw in
                tex.replace(region: MTLRegionMake2D(0, 0, line.nx, line.ny), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: line.nx * 2 * MemoryLayout<Float16>.size)
            }
            textures.append(tex)
        }
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
        // The map pans at the display's own rate; the lines have to stay on it.
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
        guard let line = timeline, let map = mapView, let t = clock?(),
              textures.count == line.frameCount, bounds.width > 0, bounds.height > 0 else { return }
        let rect = map.visibleMapRect
        guard rect.size.width > 0 else { return }
        // Nothing moved since the last frame: nothing to draw.
        let now = [t, rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
                   Double(traitCollection.userInterfaceStyle.rawValue)]
        guard now != lastDrawn else { return }
        lastDrawn = now
        render(line, at: t, rect: rect)
    }

    private func render(_ line: PressureTimeline, at t: Double, rect: MKMapRect) {
        guard let queue, let pipeline, let sampler, let drawable = metalLayer.nextDrawable() else { return }
        let world = MKMapSize.world.width
        let spanLon = line.dlon * Double(line.nx - 1), spanLat = line.dlat * Double(line.ny - 1)
        let at = line.bracket(at: t)
        let scale = Float(max(1, traitCollection.displayScale))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor.systemIndigo.resolvedColor(with: traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        var u = Uniforms(
            lonAB: SIMD2(Float(rect.size.width / world * 360 / spanLon),
                         Float((rect.origin.x / world * 360 - 180 - line.lon0) / spanLon)),
            mercAB: SIMD2(Float(-2 * Double.pi * rect.size.height / world),
                          Float(Double.pi * (1 - 2 * rect.origin.y / world))),
            latAB: SIMD2(Float(1 / spanLat), Float(-line.lat0 / spanLat)),
            size: SIMD2(Float(line.nx), Float(line.ny)),
            mix: Float(at.f),
            // The textures hold the value less the base; the shape is the
            // value less the area's rise since then.
            bias: Float(line.base - at.shift),
            invStep: Float(1 / line.stepHPa),
            halfWidth: 0.8 * scale,
            color: SIMD4(Float(r), Float(g), Float(b), 0.85))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(textures[at.a], index: 0)
        encoder.setFragmentTexture(textures[at.b], index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
