//  FrontsOverlay.swift
//  Barry — iOS
//
//  The surface chart on the radar: WPC's fronts drawn the way every TV weather
//  map has drawn them for fifty years — blue triangles for cold, red half-discs
//  for warm, alternating for stationary, purple for occluded, a dashed line for
//  a trough — and the old Weather Channel glide between valid times.
//
//  Three pieces:
//    FrontGlyphs        one drawing routine for a front, shared by the map
//                       renderer and the key so the two can never disagree
//    FrontMorph         a chart as render state, and one chart crossfading to
//                       the next (no matching, no sliding: see crossfade)
//    FrontFieldOverlay  a single world-sized MKOverlay whose renderer draws the
//                       whole (morphed) field from a state struct, so animating
//                       is "update the struct, setNeedsDisplay" — no overlay churn

import MapKit
import SwiftUI

private extension Array {
    func chunked(_ n: Int) -> [[Element]] {
        stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) }
    }
}

// MARK: - Kinds and colors

enum FrontKind: String {
    case cold, warm, stnry, ocfnt, trof

    static let cold_ = UIColor(red: 0.13, green: 0.42, blue: 0.90, alpha: 1)
    static let warm_ = UIColor(red: 0.86, green: 0.18, blue: 0.16, alpha: 1)
    static let occl_ = UIColor(red: 0.55, green: 0.22, blue: 0.72, alpha: 1)
    static let trof_ = UIColor(red: 0.80, green: 0.48, blue: 0.10, alpha: 1)

    var lineColor: UIColor {
        switch self {
        case .cold: return Self.cold_
        case .warm: return Self.warm_
        case .stnry: return Self.cold_   // pips carry the alternation
        case .ocfnt: return Self.occl_
        case .trof: return Self.trof_
        }
    }

    var keyLabel: String {
        switch self {
        case .cold: return "Cold front"
        case .warm: return "Warm front"
        case .stnry: return "Stationary front"
        case .ocfnt: return "Occluded front"
        case .trof: return "Trough"
        }
    }
}

// MARK: - Geometry helpers

private extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    var length: CGFloat { hypot(x, y) }
    var unit: CGPoint { let l = max(length, 1e-9); return CGPoint(x: x / l, y: y / l) }
    /// Left-hand side of travel in a y-down coordinate space (east -> north).
    var leftNormal: CGPoint { CGPoint(x: y, y: -x) }
}

/// Catmull-Rom smoothing so whole-degree bulletin points don't read as
/// connect-the-dots. Returns a dense polyline.
private func smoothed(_ pts: [CGPoint], segments: Int = 8) -> [CGPoint] {
    guard pts.count >= 3 else { return pts }
    var out: [CGPoint] = [pts[0]]
    for i in 0..<(pts.count - 1) {
        let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
        for s in 1...segments {
            let t = CGFloat(s) / CGFloat(segments)
            let t2 = t * t, t3 = t2 * t
            let x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t
                           + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
                           + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
            let y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t
                           + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
                           + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
            out.append(CGPoint(x: x, y: y))
        }
    }
    return out
}

// MARK: - Glyphs (the one drawing routine)

enum FrontGlyphs {
    /// Draw one front into `ctx`. `points` are already in the context's space;
    /// `scale` converts screen points to that space (1/zoomScale on the map, 1
    /// in the key). The pips sit on the left of travel = direction of motion.
    static func draw(kind: FrontKind, weak: Bool, points: [CGPoint],
                     scale: CGFloat, alpha: CGFloat, in ctx: CGContext,
                     lines: Bool = true, pips: Bool = true) {
        guard points.count >= 2, lines || pips else { return }
        let path = smoothed(points)
        let lineWidth = 2.6 * scale
        let pipSize = 8.0 * scale
        let spacing = 30.0 * scale

        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // The line
        if lines {
            ctx.setStrokeColor(kind.lineColor.cgColor)
            ctx.setLineWidth(lineWidth)
            if kind == .trof || weak {
                ctx.setLineDash(phase: 0, lengths: [6 * scale, 5 * scale])
            }
            ctx.beginPath()
            ctx.move(to: path[0])
            for p in path.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        guard kind != .trof, pips else { ctx.restoreGState(); return }

        // The pips, spaced by arc length along the smoothed line
        var carry = spacing * 0.5
        var index = 0
        for i in 0..<(path.count - 1) {
            let a = path[i], b = path[i + 1]
            let seg = b - a
            let len = seg.length
            guard len > 0 else { continue }
            let t = seg.unit
            var d = carry
            while d <= len {
                let p = a + t * d
                pip(kind: kind, index: index, at: p, tangent: t, size: pipSize, in: ctx)
                index += 1
                d += spacing
            }
            carry = d - len
        }
        ctx.restoreGState()
    }

    private static func pip(kind: FrontKind, index: Int, at p: CGPoint,
                            tangent t: CGPoint, size: CGFloat, in ctx: CGContext) {
        let n = t.leftNormal
        switch kind {
        case .cold:
            triangle(at: p, tangent: t, normal: n, size: size, color: FrontKind.cold_, in: ctx)
        case .warm:
            halfDisc(at: p, tangent: t, normal: n, size: size, color: FrontKind.warm_, in: ctx)
        case .ocfnt:
            if index % 2 == 0 {
                triangle(at: p, tangent: t, normal: n, size: size, color: FrontKind.occl_, in: ctx)
            } else {
                halfDisc(at: p, tangent: t, normal: n, size: size, color: FrontKind.occl_, in: ctx)
            }
        case .stnry:
            // Red half-discs one side, blue triangles the other, alternating —
            // the chart's way of saying "this one isn't going anywhere".
            if index % 2 == 0 {
                halfDisc(at: p, tangent: t, normal: n, size: size, color: FrontKind.warm_, in: ctx)
            } else {
                triangle(at: p, tangent: t, normal: n * -1, size: size, color: FrontKind.cold_, in: ctx)
            }
        case .trof:
            break
        }
    }

    private static func triangle(at p: CGPoint, tangent t: CGPoint, normal n: CGPoint,
                                 size: CGFloat, color: UIColor, in ctx: CGContext) {
        ctx.setFillColor(color.cgColor)
        ctx.beginPath()
        ctx.move(to: p - t * (size * 0.65))
        ctx.addLine(to: p + n * size)
        ctx.addLine(to: p + t * (size * 0.65))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func halfDisc(at p: CGPoint, tangent t: CGPoint, normal n: CGPoint,
                                 size: CGFloat, color: UIColor, in ctx: CGContext) {
        // Sampled explicitly so it's right regardless of the context's flip.
        let r = size * 0.62
        ctx.setFillColor(color.cgColor)
        ctx.beginPath()
        ctx.move(to: p - t * r)
        let steps = 12
        for k in 1..<steps {
            let a = CGFloat.pi * CGFloat(k) / CGFloat(steps)   // 0..π from -t through n to +t
            let q = p + (t * (-cos(a) * r)) + (n * (sin(a) * r))
            ctx.addLine(to: q)
        }
        ctx.addLine(to: p + t * r)
        ctx.closePath()
        ctx.fillPath()
    }
}

// MARK: - Render state (what the renderer draws right now)

struct RenderedFront {
    let kind: FrontKind
    let weak: Bool
    let coordinates: [CLLocationCoordinate2D]
    let alpha: CGFloat
}

struct RenderedCenter: Equatable {
    let isHigh: Bool
    let pressure: Int
    let lat: Double
    let lon: Double
    let alpha: CGFloat
}

/// What of the chart to draw. All on is the classic surface chart.
struct FrontStyle: Equatable {
    var lines = true      // the front line itself
    var pips = true       // the cold / warm / occluded symbols
    var troughs = true    // dashed trough lines
    var weak = true       // fronts WPC marks weak
    var centers = true    // the H and L
}

struct FrontRenderState {
    var fronts: [RenderedFront] = []
    var centers: [RenderedCenter] = []
    var style = FrontStyle()
    /// Bumped by the model on every change so the map redraws only when the
    /// field actually moved, not on every SwiftUI update tick.
    var version: Int = 0
    static let empty = FrontRenderState()
}

// MARK: - A chart as what the map draws

enum FrontMorph {
    static func state(for frame: FrontFrame, alpha: CGFloat = 1) -> FrontRenderState {
        FrontRenderState(
            fronts: frame.fronts.compactMap { line in
                guard let kind = FrontKind(rawValue: line.type) else { return nil }
                return RenderedFront(kind: kind, weak: line.isWeak,
                                     coordinates: coords(line), alpha: alpha)
            },
            centers: frame.highs.map { RenderedCenter(isHigh: true, pressure: $0.pressure, lat: $0.lat, lon: $0.lon, alpha: alpha) }
                   + frame.lows.map { RenderedCenter(isHigh: false, pressure: $0.pressure, lat: $0.lat, lon: $0.lon, alpha: alpha) }
        )
    }

    /// One chart giving way to the next: `a` fading out as `b` fades in,
    /// every line where its own chart drew it. Nothing is moved from one
    /// chart's position toward the other's.
    ///
    /// Until 2026-10-02 this matched each front to the nearest of its type
    /// on the other chart and slid it there. WPC does not draw the same
    /// front the same way twice: four consecutive analyses that day held
    /// 62, 80, 48 and 97 segments, and of the pairs the matching made, a
    /// third had an end travelling over 500 km and one 2,600. On screen:
    /// fronts breaking apart and flying across the map. The charts do not
    /// say where a front was between them, so the map does not either.
    static func crossfade(_ a: FrontFrame, _ b: FrontFrame, t: Double) -> FrontRenderState {
        let t = CGFloat(min(1, max(0, t)))
        let from = state(for: a, alpha: 1 - t), to = state(for: b, alpha: t)
        return FrontRenderState(fronts: from.fronts + to.fronts, centers: from.centers + to.centers)
    }

    // helpers
    static func coords(_ line: FrontLine) -> [CLLocationCoordinate2D] {
        line.points.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
    }
}

final class FrontFieldOverlay: NSObject, MKOverlay {
    /// Written on the main thread, read by the renderer on MapKit's.
    private let box = Locked(FrontRenderState.empty)
    var state: FrontRenderState {
        get { box.value }
        set { box.value = newValue }
    }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: 0, longitude: 0) }
    var boundingMapRect: MKMapRect { .world }
}

final class FrontFieldRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        guard let overlay = overlay as? FrontFieldOverlay else { return }
        let scale = 1 / zoomScale
        // Only fronts that come anywhere near this tile (generous padding for pips).
        let pad = 40 * scale
        let visible = mapRect.insetBy(dx: -pad, dy: -pad)
        // One read: the main thread may replace the state mid-draw.
        let state = overlay.state
        let style = state.style
        for f in state.fronts {
            if f.kind == .trof, !style.troughs { continue }
            if f.weak, !style.weak { continue }
            let mapPts = f.coordinates.map { MKMapPoint($0) }
            let touches = mapPts.contains { visible.contains($0) }
                || zip(mapPts, mapPts.dropFirst()).contains { a, b in
                    MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y),
                              width: abs(a.x - b.x), height: abs(a.y - b.y)).intersects(visible)
                }
            guard touches else { continue }
            let pts = mapPts.map { point(for: $0) }
            // A trough is only a line, and its own chip decided it is wanted
            // (the filter above), so the Fronts chip's line toggle does not
            // apply to it. Without this the Troughs chip drew nothing on its own.
            FrontGlyphs.draw(kind: f.kind, weak: f.weak, points: pts,
                             scale: scale, alpha: f.alpha, in: ctx,
                             lines: f.kind == .trof || style.lines, pips: style.pips)
        }
    }
}

// MARK: - Pressure centers (annotations)

final class PressureCenterAnnotation: MKPointAnnotation {
    var isHigh = true
    var pressure = 1013
    var alpha: CGFloat = 1
}

final class PressureCenterView: MKAnnotationView {
    private let letter = UILabel()
    private let value = UILabel()

    private let disc = UIView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        // The centers are the pressure story on the chart; they read at a
        // glance: a big letter on a pale disc, the value underneath.
        disc.frame = CGRect(x: 4, y: 0, width: 36, height: 36)
        disc.layer.cornerRadius = 18
        disc.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        disc.layer.borderWidth = 2
        letter.font = .systemFont(ofSize: 26, weight: .black)
        letter.textAlignment = .center
        value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        value.textColor = .label
        value.textAlignment = .center
        addSubview(disc)
        addSubview(letter)
        addSubview(value)
        isEnabled = false
        displayPriority = .required
        collisionMode = .circle
        bounds = CGRect(x: 0, y: 0, width: 44, height: 50)
        letter.frame = CGRect(x: 4, y: 0, width: 36, height: 36)
        value.frame = CGRect(x: -8, y: 37, width: 60, height: 12)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(_ c: PressureCenterAnnotation) {
        letter.text = c.isHigh ? "H" : "L"
        let tint = c.isHigh ? FrontKind.cold_ : FrontKind.warm_
        letter.textColor = tint
        disc.layer.borderColor = tint.withAlphaComponent(0.8).cgColor
        // WPC gives whole hPa; show it in the unit the rest of the app uses.
        let unit = PressureUnit(rawValue: AppConfig.sharedDefaults.string(forKey: "pressureUnit") ?? "") ?? .inHg
        value.text = unit == .hPa ? "\(c.pressure) hPa"
                                  : String(format: "%.2f inHg", unit.convert(Double(c.pressure)))
        alpha = c.alpha
    }
}

// MARK: - Key

/// The corner key. Samples are drawn by FrontGlyphs itself, so they can't
/// drift from what the map shows.
struct FrontKeyView: View {
    var validText: String
    var compact: Bool = false

    private let kinds: [FrontKind] = [.cold, .warm, .stnry, .ocfnt, .trof]

    var body: some View {
        // Kept deliberately small: it's a key, not a panel. Two columns of
        // glyph + label, then the H/L and validity line.
        let rows = kinds.chunked(2)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 10) {
                    ForEach(pair, id: \.self) { kind in
                        HStack(spacing: 4) {
                            Canvas { gc, size in
                                gc.withCGContext { cg in
                                    let y = size.height / 2
                                    FrontGlyphs.draw(kind: kind, weak: false,
                                                     points: [CGPoint(x: 1, y: y), CGPoint(x: size.width * 0.5, y: y),
                                                              CGPoint(x: size.width - 1, y: y)],
                                                     scale: 0.6, alpha: 1, in: cg)
                                }
                            }
                            .frame(width: 30, height: 11)
                            Text(kind.keyLabel.replacingOccurrences(of: " front", with: ""))
                                .font(.system(size: compact ? 8 : 9))
                        }
                    }
                }
            }
            HStack(spacing: 5) {
                Text("H").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color(FrontKind.cold_))
                Text(compact ? "high" : "high: fair, stable").font(.system(size: compact ? 8 : 9))
                Text("L").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color(FrontKind.warm_))
                Text(compact ? "low" : "low: pressure falls toward it, weather with it").font(.system(size: compact ? 8 : 9))
                Text("·").font(.system(size: 8)).foregroundStyle(.secondary)
                Text(validText)
                    .font(.system(size: 7.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
    }
}
