//  TafStrip.swift
//  Barry — Shared
//
//  The 24 h category strip, drawn by hand: one rounded segment per run of
//  hours, labeled when there is room; night washed behind; TEMPO and PROB
//  windows hatched in their own category's color; sunset, sunrise and now
//  marked, with the sun times under the bar. Swift Charts cannot hatch, so
//  this is a Canvas. `compact` drops the sun times and hour labels for a
//  lock screen row.

import SwiftUI

struct TafStrip: View {
    let timeline: TafTimeline
    var compact = false

    private var barTop: CGFloat { compact ? 4 : 22 }
    private var barHeight: CGFloat { compact ? 14 : 40 }
    private let sunLabelTop: CGFloat = 66
    private let axisTop: CGFloat = 86

    /// The height the strip wants at each size.
    static func height(compact: Bool) -> CGFloat { compact ? 22 : 112 }

    private func x(_ d: Date, _ w: CGFloat) -> CGFloat {
        let f = d.timeIntervalSince(timeline.start) / max(1, timeline.end.timeIntervalSince(timeline.start))
        return CGFloat(min(1, max(0, f))) * w
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for n in timeline.nights {
                        let r = CGRect(x: x(n.0, w), y: barTop - (compact ? 2 : 6),
                                       width: x(n.1, w) - x(n.0, w), height: barHeight + (compact ? 4 : 12))
                        ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(Color.primary.opacity(0.07)))
                    }
                    for run in timeline.runs {
                        if run.0 == nil, let ends = timeline.tafEnds, run.1 >= ends { continue }
                        let x0 = x(run.1, w), x1 = x(run.2, w)
                        let r = CGRect(x: x0 + 0.75, y: barTop, width: max(0, x1 - x0 - 1.5), height: barHeight)
                        let fill: Color = run.0.map { FlightCategory.color($0) } ?? Color.secondary.opacity(0.35)
                        ctx.fill(Path(roundedRect: r, cornerRadius: compact ? 3 : 5), with: .color(fill.opacity(0.9)))
                        if !compact, r.width >= 34 {
                            let label = Text(run.0 ?? "—").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                            ctx.draw(ctx.resolve(label), at: CGPoint(x: r.midX, y: r.midY))
                        }
                    }
                    for o in timeline.overlays {
                        let x0 = x(o.from, w), x1 = x(o.to, w)
                        let r = CGRect(x: x0, y: barTop, width: x1 - x0, height: barHeight)
                        var sub = ctx
                        sub.clip(to: Path(roundedRect: r, cornerRadius: compact ? 3 : 5))
                        sub.fill(Path(r), with: .color(FlightCategory.color(o.category).opacity(o.isProb ? 0.25 : 0.35)))
                        var stripes = Path()
                        var sx = r.minX - r.height
                        while sx < r.maxX {
                            stripes.move(to: CGPoint(x: sx, y: r.maxY))
                            stripes.addLine(to: CGPoint(x: sx + r.height, y: r.minY))
                            sx += compact ? 4 : 7
                        }
                        sub.stroke(stripes, with: .color(FlightCategory.color(o.category).opacity(o.isProb ? 0.6 : 0.95)),
                                   lineWidth: compact ? 1 : 1.5)
                        sub.stroke(Path(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), cornerRadius: compact ? 3 : 5),
                                   with: .color(FlightCategory.color(o.category)), lineWidth: 1)
                    }
                    if let ends = timeline.tafEnds {
                        let xe = x(ends, w)
                        var tick = Path(); tick.move(to: CGPoint(x: xe, y: barTop)); tick.addLine(to: CGPoint(x: xe, y: barTop + barHeight))
                        ctx.stroke(tick, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        if !compact, w - xe >= 52 {
                            let label = Text("TAF ends").font(.system(size: 9)).foregroundColor(.secondary)
                            ctx.draw(ctx.resolve(label), at: CGPoint(x: xe + 4, y: barTop + barHeight / 2), anchor: .leading)
                        }
                    }
                    for m in timeline.sunMarks {
                        var line = Path()
                        line.move(to: CGPoint(x: x(m.0, w), y: barTop - 4)); line.addLine(to: CGPoint(x: x(m.0, w), y: barTop + barHeight + 4))
                        ctx.stroke(line, with: .color(.orange.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                    var nowLine = Path()
                    nowLine.move(to: CGPoint(x: x(timeline.now, w), y: barTop - (compact ? 3 : 8)))
                    nowLine.addLine(to: CGPoint(x: x(timeline.now, w), y: barTop + barHeight + (compact ? 3 : 8)))
                    ctx.stroke(nowLine, with: .color(.primary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    guard !compact else { return }
                    for m in timeline.sunMarks {
                        let label = Text(m.0.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 9, weight: .semibold)).foregroundColor(.orange)
                        let cx = min(max(x(m.0, w), 22), w - 22)
                        ctx.draw(ctx.resolve(label), at: CGPoint(x: cx, y: sunLabelTop), anchor: .top)
                    }
                    let cal = Calendar.current
                    var t = cal.date(bySetting: .minute, value: 0, of: timeline.start) ?? timeline.start
                    while t <= timeline.end {
                        if cal.component(.hour, from: t) % 6 == 0 {
                            let label = Text(t.formatted(.dateTime.hour())).font(.system(size: 9)).foregroundColor(.secondary)
                            ctx.draw(ctx.resolve(label), at: CGPoint(x: x(t, w), y: axisTop + 6), anchor: .top)
                            var tick = Path()
                            tick.move(to: CGPoint(x: x(t, w), y: barTop + barHeight + 2))
                            tick.addLine(to: CGPoint(x: x(t, w), y: barTop + barHeight + 6))
                            ctx.stroke(tick, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                        }
                        t = t.addingTimeInterval(3600)
                    }
                }
                if !compact {
                    ForEach(timeline.sunMarks, id: \.0) { m in
                        Image(systemName: m.1 ? "sunset.fill" : "sunrise.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .position(x: x(m.0, w), y: 9)
                    }
                    Text("now")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .position(x: max(12, x(timeline.now, w)), y: 9)
                }
            }
        }
        .frame(height: Self.height(compact: compact))
    }
}
