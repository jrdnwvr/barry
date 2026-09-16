//  RunwayWindDial.swift
//  Barry — iOS
//
//  The wind-component picture pilots already read: a compass rose (degrees
//  true, matching both the METAR and the runway headings), the field's
//  runways drawn to their real orientation in the middle, and the wind as a
//  barb sitting on the ring at the direction it comes from, staff outward,
//  speed flags on it. Nothing here needs data the card doesn't already have.

import SwiftUI

struct RunwayWindDial: View {
    let runways: [Runway]
    let bestIdent: String
    let windDirDeg: Double?
    let windKt: Double
    let gustKt: Double?

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 30          // ring radius, room for the barb + its label
            drawRose(ctx, c, r)
            drawRunways(ctx, c, r)
            if let d = windDirDeg, windKt >= 1 {
                drawBarb(ctx, c, r, dirDeg: d, kt: windKt)
            } else {
                // Calm: the open circle at the center, no bug.
                let calm = Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
                ctx.stroke(calm, with: .color(.secondary), lineWidth: 1.2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let d = windDirDeg, windKt >= 1 else { return "Wind calm. Runway \(bestIdent)." }
        return "Wind from \(Int(d)) degrees at \(Int(windKt)) knots\(gustKt.map { ", gusting \(Int($0))" } ?? ""). Best runway \(bestIdent)."
    }

    // MARK: - Pieces

    private func point(_ c: CGPoint, _ radius: CGFloat, deg: Double) -> CGPoint {
        let a = (deg - 90) * .pi / 180
        return CGPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a))
    }

    private func drawRose(_ ctx: GraphicsContext, _ c: CGPoint, _ r: CGFloat) {
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                   with: .color(.secondary.opacity(0.6)), lineWidth: 1)
        for deg in stride(from: 0, to: 360, by: 10) {
            let major = deg % 30 == 0
            var tick = Path()
            tick.move(to: point(c, r, deg: Double(deg)))
            tick.addLine(to: point(c, r - (major ? 7 : 3.5), deg: Double(deg)))
            ctx.stroke(tick, with: .color(.secondary.opacity(major ? 0.8 : 0.45)), lineWidth: major ? 1.2 : 0.8)
            if deg % 30 == 0 {
                let label = deg == 0 ? "N" : (deg == 90 ? "E" : (deg == 180 ? "S" : (deg == 270 ? "W" : "\(deg)")))
                let p = point(c, r + 11, deg: Double(deg))
                ctx.draw(Text(label).font(.system(size: deg % 90 == 0 ? 9 : 7.5, weight: deg % 90 == 0 ? .bold : .regular))
                            .foregroundStyle(.secondary),
                         at: p)
            }
        }
    }

    private func drawRunways(_ ctx: GraphicsContext, _ c: CGPoint, _ r: CGFloat) {
        // Only the selected runway: the one the sentence is about, drawn to
        // its true heading with both end numbers, the chosen end in blue.
        guard let rw = runways.first(where: { $0.le == bestIdent || $0.he == bestIdent }) else { return }
        let half = r * 0.62
        let a = point(c, half, deg: rw.leHeading + 180)   // the "le" end sits opposite its heading
        let b = point(c, half, deg: rw.leHeading)
        var body = Path()
        body.move(to: a); body.addLine(to: b)
        ctx.stroke(body, with: .color(Color(.label)), style: StrokeStyle(lineWidth: 13, lineCap: .butt))
        var center = Path()
        center.move(to: a); center.addLine(to: b)
        ctx.stroke(center, with: .color(Color(.systemBackground)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
        for (ident, deg) in [(rw.le, rw.leHeading + 180), (rw.he, rw.leHeading)] {
            let p = point(c, half + 11, deg: deg)
            let chosen = ident == bestIdent
            ctx.draw(Text(ident).font(.system(size: chosen ? 11 : 9, weight: chosen ? .heavy : .semibold))
                        .foregroundStyle(chosen ? Color.blue : Color.primary),
                     at: p)
        }
    }

    /// The wind bug: a METAR barb on the ring at the direction the wind
    /// comes from, staff pointing outward (into the wind), flags on the
    /// right of the staff, seen from the center looking out.
    private func drawBarb(_ ctx: GraphicsContext, _ c: CGPoint, _ r: CGFloat, dirDeg: Double, kt: Double) {
        let base = point(c, r, deg: dirDeg)
        let out = CGPoint(x: (base.x - c.x) / r, y: (base.y - c.y) / r)        // unit, outward
        let perp = CGPoint(x: -out.y, y: out.x)                                  // right side, looking out
        let staff: CGFloat = 20
        let tip = CGPoint(x: base.x + out.x * staff, y: base.y + out.y * staff)
        let ink = Color.blue
        ctx.fill(Path(ellipseIn: CGRect(x: base.x - 3.5, y: base.y - 3.5, width: 7, height: 7)), with: .color(ink))
        var line = Path(); line.move(to: base); line.addLine(to: tip)
        ctx.stroke(line, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))

        var remaining = Int((kt / 5).rounded()) * 5
        let pennants = remaining / 50; remaining -= pennants * 50
        let fulls = remaining / 10;    remaining -= fulls * 10
        let half = remaining >= 5
        var along = staff
        func at(_ s: CGFloat) -> CGPoint { CGPoint(x: base.x + out.x * s, y: base.y + out.y * s) }
        func flag(_ p: CGPoint, _ len: CGFloat) -> CGPoint {
            CGPoint(x: p.x + perp.x * len + out.x * len * 0.35, y: p.y + perp.y * len + out.y * len * 0.35)
        }
        for _ in 0..<pennants {
            var p = Path(); p.move(to: at(along)); p.addLine(to: flag(at(along - 5), 8)); p.addLine(to: at(along - 5)); p.closeSubpath()
            ctx.fill(p, with: .color(ink)); along -= 6
        }
        for _ in 0..<fulls {
            var p = Path(); p.move(to: at(along)); p.addLine(to: flag(at(along), 8))
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round)); along -= 4.5
        }
        if half {
            if pennants == 0 && fulls == 0 { along -= 4.5 }
            var p = Path(); p.move(to: at(along)); p.addLine(to: flag(at(along), 4.5))
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        // Speed (and gust) beside the bug, kept off the ring.
        var label = "\(Int(kt.rounded())) kt"
        if let g = gustKt { label += " G\(Int(g.rounded()))" }
        let lp = CGPoint(x: base.x + out.x * (staff + 9), y: base.y + out.y * (staff + 9))
        ctx.draw(Text(label).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(ink), at: lp)
    }
}
