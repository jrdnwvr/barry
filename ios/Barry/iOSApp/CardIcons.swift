//  CardIcons.swift
//  Barry — iOS
//
//  Two small hand-drawn glyphs where no SF Symbol says the right thing: a
//  runway seen from above (edge lines, dashed centerline, threshold bars)
//  and "bumpy air below, smooth air above" for density altitude.

import SwiftUI

/// A runway from above: two edge lines, a dashed centerline, threshold bars.
struct RunwayIcon: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let lw = max(1.4, w * 0.11)
            var edges = Path()
            edges.move(to: CGPoint(x: w * 0.22, y: 0)); edges.addLine(to: CGPoint(x: w * 0.22, y: h))
            edges.move(to: CGPoint(x: w * 0.78, y: 0)); edges.addLine(to: CGPoint(x: w * 0.78, y: h))
            ctx.stroke(edges, with: .foreground, lineWidth: lw)

            var center = Path()
            center.move(to: CGPoint(x: w / 2, y: h * 0.18)); center.addLine(to: CGPoint(x: w / 2, y: h * 0.82))
            ctx.stroke(center, with: .foreground,
                       style: StrokeStyle(lineWidth: lw, lineCap: .round, dash: [h * 0.14, h * 0.13]))

            // Threshold bars at both ends, inside the edges.
            var bars = Path()
            for x in [w * 0.36, w * 0.64] {
                bars.move(to: CGPoint(x: x, y: 0)); bars.addLine(to: CGPoint(x: x, y: h * 0.14))
                bars.move(to: CGPoint(x: x, y: h * 0.86)); bars.addLine(to: CGPoint(x: x, y: h))
            }
            ctx.stroke(bars, with: .foreground, lineWidth: lw)
        }
        .aspectRatio(0.9, contentMode: .fit)
    }
}

/// Bumpy air below a smooth layer: a wavy line under a flat one.
struct AirLayersIcon: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let lw = max(1.4, h * 0.11)
            var flat = Path()
            flat.move(to: CGPoint(x: 0, y: h * 0.22)); flat.addLine(to: CGPoint(x: w, y: h * 0.22))
            ctx.stroke(flat, with: .foreground, style: StrokeStyle(lineWidth: lw, lineCap: .round))

            var wave = Path()
            let steps = 24
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let y = h * 0.68 + sin(t * .pi * 4) * h * 0.18
                let p = CGPoint(x: t * w, y: y)
                if i == 0 { wave.move(to: p) } else { wave.addLine(to: p) }
            }
            ctx.stroke(wave, with: .foreground,
                       style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1.25, contentMode: .fit)
    }
}
