//  PressureFieldOverlay.swift
//  Barry — iOS
//
//  The pressure map drawn from Barry's own station table: isobar lines with
//  labels, isallobar lines (falls warm, rises cool), and an optional shaded
//  gradient of either field. One world-sized overlay; the renderer culls to
//  the tile it's asked for.

import MapKit
import SwiftUI
import UIKit

enum PressureShade: String { case off, pressure, change }

struct PressureFieldState: Equatable {
    var field: PressureFieldResponse?
    var showIsobars = true
    var showIsallobars = false
    var shade: PressureShade = .off
    /// Lighter when the radar is under it.
    var shadeOpacity: Double = 0.38
    var version = 0
}

final class PressureFieldOverlay: NSObject, MKOverlay {
    var state = PressureFieldState()
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: 0, longitude: 0) }
    var boundingMapRect: MKMapRect { .world }
}

final class PressureFieldRenderer: MKOverlayRenderer {
    /// Shaded images are rebuilt only when the field or the shade choice changes.
    private var shadeImage: CGImage?
    private var shadeRect: MKMapRect = .null
    private var shadeKey = ""

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        guard let overlay = overlay as? PressureFieldOverlay, let field = overlay.state.field else { return }
        let st = overlay.state
        let scale = 1 / zoomScale
        let visible = mapRect.insetBy(dx: -60 * scale, dy: -60 * scale)

        if st.shade != .off, let grid = (st.shade == .pressure ? field.pressureGrid : field.tendencyGrid) {
            drawShade(grid, kind: st.shade, version: st.version, opacity: st.shadeOpacity, in: ctx)
        }
        if st.showIsobars {
            for line in field.isobars {
                // Indigo, not gray: gray reads as a road on Apple's map.
                drawLine(line, color: UIColor.systemIndigo.withAlphaComponent(0.85), width: 1.6 * scale,
                         dash: nil, label: String(Int(line.level)), scale: scale, visible: visible, in: ctx)
            }
        }
        if st.showIsallobars {
            // The NWS isallobar look: one color, solid for rises, dashed for
            // falls, every whole unit, value labels along each line, and H/L
            // marks with the value at the field's centers.
            let ink = Self.changeInk
            for line in field.isallobars {
                let falling = line.level < 0
                let mag = min(6, abs(line.level))
                drawLine(line, color: ink, width: (1.1 + 0.15 * mag) * scale,
                         dash: falling ? [7 * scale, 5 * scale] : nil,
                         label: String(format: "%.0f", line.level), scale: scale,
                         visible: visible, in: ctx)
            }
            for e in field.tendencyExtrema {
                let p = point(for: MKMapPoint(CLLocationCoordinate2D(latitude: e.lat, longitude: e.lon)))
                guard visible.contains(MKMapPoint(CLLocationCoordinate2D(latitude: e.lat, longitude: e.lon))) else { continue }
                drawExtremum(e, at: p, color: ink, scale: scale, in: ctx)
            }
        }
    }

    /// Amber on the light map, a warmer yellow on dark: readable over the
    /// pastel basemap without fighting the fronts' blue and red.
    private static var changeInk: UIColor {
        UIColor { tc in tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.98, green: 0.85, blue: 0.3, alpha: 0.95)
            : UIColor(red: 0.62, green: 0.42, blue: 0.02, alpha: 0.95) }
    }

    private func drawExtremum(_ e: FieldExtremum, at p: CGPoint, color: UIColor, scale: CGFloat, in ctx: CGContext) {
        let letterFont = UIFont.systemFont(ofSize: 15 * scale, weight: .black)
        let valueFont = UIFont.systemFont(ofSize: 9 * scale, weight: .bold)
        let letter = e.kind as NSString
        let value = String(format: "%.0f", abs(e.value)) as NSString
        let la: [NSAttributedString.Key: Any] = [.font: letterFont, .foregroundColor: color]
        let va: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: color]
        let ls = letter.size(withAttributes: la), vs = value.size(withAttributes: va)
        let box = CGRect(x: p.x - max(ls.width, vs.width) / 2 - 3 * scale, y: p.y - ls.height / 2 - 2 * scale,
                         width: max(ls.width, vs.width) + 6 * scale, height: ls.height + vs.height + 2 * scale)
        ctx.saveGState()
        ctx.setFillColor(UIColor.systemBackground.withAlphaComponent(0.7).cgColor)
        ctx.fill(box)
        UIGraphicsPushContext(ctx)
        letter.draw(at: CGPoint(x: p.x - ls.width / 2, y: p.y - ls.height / 2), withAttributes: la)
        value.draw(at: CGPoint(x: p.x - vs.width / 2, y: p.y + ls.height / 2 - 2 * scale), withAttributes: va)
        UIGraphicsPopContext()
        ctx.restoreGState()
    }

    private func drawLine(_ line: ContourLine, color: UIColor, width: CGFloat, dash: [CGFloat]?,
                          label: String, scale: CGFloat, visible: MKMapRect, in ctx: CGContext) {
        let pts = line.points.compactMap { p -> CGPoint? in
            guard p.count == 2 else { return nil }
            return point(for: MKMapPoint(CLLocationCoordinate2D(latitude: p[0], longitude: p[1])))
        }
        guard pts.count >= 2 else { return }
        let mapPts = line.points.map { MKMapPoint(CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1])) }
        guard mapPts.contains(where: { visible.contains($0) }) else { return }
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if let dash { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.beginPath()
        ctx.move(to: pts[0])
        for p in pts.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
        ctx.restoreGState()

        // Value labels along the line, every ~170 screen points, on small
        // knockouts so they stay legible over the radar (the chart style).
        let font = UIFont.systemFont(ofSize: 9 * scale, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (label as NSString).size(withAttributes: attrs)
        let every: CGFloat = 170 * scale
        var run: CGFloat = every * 0.5
        var spots: [CGPoint] = []
        for k in 1..<pts.count {
            let seg = hypot(pts[k].x - pts[k - 1].x, pts[k].y - pts[k - 1].y)
            run += seg
            if run >= every {
                spots.append(pts[k])
                run = 0
            }
        }
        if spots.isEmpty { spots = [pts[pts.count / 2]] }
        ctx.saveGState()
        UIGraphicsPushContext(ctx)
        for sp in spots {
            let box = CGRect(x: sp.x - size.width / 2 - 2 * scale, y: sp.y - size.height / 2,
                             width: size.width + 4 * scale, height: size.height)
            ctx.setFillColor(UIColor.systemBackground.withAlphaComponent(0.75).cgColor)
            ctx.fill(box)
            (label as NSString).draw(at: CGPoint(x: box.minX + 2 * scale, y: box.minY), withAttributes: attrs)
        }
        UIGraphicsPopContext()
        ctx.restoreGState()
    }

    /// The gridded field as a smooth translucent gradient. The image is one
    /// pixel per grid cell; Core Graphics interpolates it across the tile.
    private func drawShade(_ grid: GridOut, kind: PressureShade, version: Int, opacity: Double, in ctx: CGContext) {
        let key = "\(kind.rawValue)-\(version)"
        if shadeKey != key || shadeImage == nil {
            shadeImage = makeImage(grid, kind: kind)
            shadeKey = key
            let sw = MKMapPoint(CLLocationCoordinate2D(latitude: grid.lat0, longitude: grid.lon0))
            let ne = MKMapPoint(CLLocationCoordinate2D(
                latitude: grid.lat0 + Double(grid.ny - 1) * grid.dlat,
                longitude: grid.lon0 + Double(grid.nx - 1) * grid.dlon))
            shadeRect = MKMapRect(x: min(sw.x, ne.x), y: min(sw.y, ne.y),
                                  width: abs(ne.x - sw.x), height: abs(ne.y - sw.y))
        }
        guard let img = shadeImage else { return }
        let r = rect(for: shadeRect)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.setAlpha(CGFloat(opacity))
        // Row 0 of the grid is south; CGImage row 0 is top, so flip.
        ctx.translateBy(x: 0, y: r.maxY + r.minY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: r)
        ctx.restoreGState()
    }

    private func makeImage(_ grid: GridOut, kind: PressureShade) -> CGImage? {
        let w = grid.nx, h = grid.ny
        guard w > 1, h > 1 else { return nil }
        var vals: [Double] = []
        for row in grid.values { for v in row { if let v { vals.append(v) } } }
        guard let lo = vals.min(), let hi = vals.max() else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for j in 0..<h {
            for i in 0..<w {
                // Image row 0 = north = grid's last row.
                let v = grid.values[h - 1 - j][i]
                let o = (j * w + i) * 4
                guard let v else { continue }
                let (r, g, b, a) = PressureShadeColor.rgba(v, lo: lo, hi: hi, kind: kind)
                px[o] = r; px[o + 1] = g; px[o + 2] = b; px[o + 3] = a
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Color ramps. Pressure: purple (low) through blue, green, yellow to orange
/// (high), stretched over the region's own range so structure shows even on
/// a flat day. Change: diverging, red for falls, blue for rises, clear at 0.
enum PressureShadeColor {
    static func rgba(_ v: Double, lo: Double, hi: Double, kind: PressureShade) -> (UInt8, UInt8, UInt8, UInt8) {
        switch kind {
        case .pressure:
            let t = hi > lo ? (v - lo) / (hi - lo) : 0.5
            let stops: [(Double, Double, Double)] = [(0.45, 0.2, 0.7), (0.2, 0.45, 0.9), (0.2, 0.7, 0.5),
                                                     (0.85, 0.8, 0.2), (0.95, 0.5, 0.15)]
            let x = t * Double(stops.count - 1)
            let i = min(stops.count - 2, Int(x)), f = x - Double(i)
            let a = stops[i], b = stops[i + 1]
            return (UInt8((a.0 + (b.0 - a.0) * f) * 255), UInt8((a.1 + (b.1 - a.1) * f) * 255),
                    UInt8((a.2 + (b.2 - a.2) * f) * 255), 255)
        case .change:
            let m = max(1.0, max(abs(lo), abs(hi)))
            let t = max(-1, min(1, v / m))                 // -1 falling .. +1 rising
            let alpha = UInt8(min(255, 40 + 215 * abs(t)))
            return t < 0 ? (230, UInt8(90 + 60 * (1 + t)), 40, alpha)
                         : (40, UInt8(110 + 60 * (1 - t)), 230, alpha)
        case .off:
            return (0, 0, 0, 0)
        }
    }
}
