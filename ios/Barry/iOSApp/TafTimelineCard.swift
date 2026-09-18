//  TafTimelineCard.swift
//  Barry — iOS
//
//  The forecaster's own product as a timeline: flight category by the hour
//  for the next 24 hours, drawn like the rain and wind rows, with the night
//  shaded and sunset and sunrise marked. One sentence above it answers the
//  question the strip exists for: what category, until when.
//
//  Base periods (the TAF's own line, FM and BECMG groups) fill the bar.
//  TEMPO and PROB groups sit on top as a shorter, lighter bar: a risk over
//  the base condition, not a certainty.

import Charts
import SwiftUI

struct TafTimelineCard: View {
    let combined: CombinedResponse
    let now: Date

    /// One hour of the timeline.
    struct HourLike: Identifiable {
        let t: Date
        let base: String?
        let tempo: String?
        var id: Date { t }
    }
    private typealias Hour = HourLike

    private var taf: TafOut? { combined.taf }

    private var span: (start: Date, end: Date) {
        let cal = Calendar.current
        let start = cal.date(bySetting: .minute, value: 0, of: now).map { cal.date(bySetting: .second, value: 0, of: $0) ?? $0 } ?? now
        return (start, start.addingTimeInterval(24 * 3600))
    }

    /// Category per hour: the newest base period that has begun, and any
    /// TEMPO or PROB group covering the hour.
    private var hours: [Hour] {
        guard let taf else { return [] }
        let (start, end) = span
        let base = taf.periods.filter { $0.change == nil || $0.change == "FM" || $0.change == "BECMG" }
        let overlays = taf.periods.filter { $0.change == "TEMPO" || ($0.change ?? "").hasPrefix("PROB") }
        var out: [Hour] = []
        var t = start
        while t < end {
            let past = taf.validTo.map { t >= $0 } ?? false
            let b = past ? nil : base.last { $0.timeFrom <= t }?.fltCat
            let o = past ? nil : overlays.first { $0.timeFrom <= t && t < $0.timeTo }?.fltCat
            out.append(Hour(t: t, base: b, tempo: o != b ? o : nil))
            t = t.addingTimeInterval(3600)
        }
        return out
    }

    /// Sunset and sunrise inside the span, and the night blocks between them.
    private var sunMarks: [(Date, Bool)] {   // (time, isSunset)
        let (start, end) = span
        let sun = combined.forecast?.sun
        let sets = (sun?.sunset ?? []).filter { $0 >= start && $0 <= end }.map { ($0, true) }
        let rises = (sun?.sunrise ?? []).filter { $0 >= start && $0 <= end }.map { ($0, false) }
        return (sets + rises).sorted { $0.0 < $1.0 }
    }

    private var nights: [(Date, Date)] {
        let (start, end) = span
        let sun = combined.forecast?.sun
        let sets = (sun?.sunset ?? []).sorted()
        let rises = (sun?.sunrise ?? []).sorted()
        var out: [(Date, Date)] = []
        // Night already under way at the start of the span.
        if let lastSet = sets.last(where: { $0 <= start }),
           let nextRise = rises.first(where: { $0 > lastSet }), nextRise > start {
            out.append((start, min(nextRise, end)))
        }
        for s in sets where s >= start && s < end {
            let r = rises.first { $0 > s } ?? end
            out.append((s, min(r, end)))
        }
        return out
    }

    // MARK: Sentence

    /// "VFR until 2 AM, then MVFR, LIFR by 4 AM, VFR again by 9 AM."
    /// Every change in the window, in order, so the worst hour is never
    /// hidden behind the first change.
    private var sentence: String {
        let hs = hours
        guard let first = hs.first?.base else { return "No category in the TAF." }
        let clock: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
        let (start, end) = span
        // The distinct run of base categories with the hour each begins.
        var runs: [(String, Date)] = [(first, hs[0].t)]
        for h in hs { if let b = h.base, b != runs.last!.0 { runs.append((b, h.t)) } }
        var s: String
        if runs.count == 1 {
            s = end.timeIntervalSince(start) >= 20 * 3600 ? "\(first) all day" : "\(first) through \(clock(end))"
        } else {
            let (second, at) = runs[1]
            let improving = FlightCategory.rank(second) > FlightCategory.rank(first)
            s = improving ? "\(first), \(second == "VFR" ? "lifting to VFR" : "improving to \(second)") around \(clock(at))"
                          : "\(first) until \(clock(at)), then \(second)"
            for (cat, at) in runs.dropFirst(2).prefix(3) {
                s += cat == first ? ", \(cat) again by \(clock(at))" : ", \(cat) by \(clock(at))"
            }
        }
        if let tempo = hs.first(where: { $0.tempo != nil }), let cat = tempo.tempo {
            let last = hs.last { $0.tempo == cat }?.t ?? tempo.t
            s += ". Chance of \(cat) \(clock(tempo.t)) to \(clock(last.addingTimeInterval(3600)))"
        }
        if let obs = observedMismatch { return "Now \(obs). TAF: " + s.prefix(1).lowercased() + s.dropFirst() + "." }
        return s + "."
    }

    var body: some View {
        if let taf, !hours.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                    Text("TAF")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let issued = taf.issueTime {
                        Text("issued \(issued.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(sentence)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                timeline
                if !overlayWindows.isEmpty {
                    Text(overlayWindows.contains { $0.isProb } ? "Hatched: TEMPO or PROB, a chance over the base forecast."
                                                               : "Hatched: TEMPO, a chance over the base forecast.")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var timeline: some View {
        let (start, end) = span
        return TafStrip(hours: hours, overlays: overlayWindows, start: start, end: end, now: now,
                        nights: nights, sunMarks: sunMarks,
                        tafEnds: taf?.validTo.flatMap { $0 < start.addingTimeInterval(24 * 3600) ? $0 : nil })
            .frame(height: 96)
    }

    /// TEMPO and PROB windows as drawn: (from, to, category, isProb).
    private var overlayWindows: [TafStrip.Overlay] {
        guard let taf else { return [] }
        let (start, end) = span
        return taf.periods
            .filter { $0.change == "TEMPO" || ($0.change ?? "").hasPrefix("PROB") }
            .compactMap { p in
                guard let cat = p.fltCat, p.timeTo > start, p.timeFrom < end else { return nil }
                return TafStrip.Overlay(from: max(p.timeFrom, start), to: min(p.timeTo, end),
                                        category: cat, isProb: (p.change ?? "").hasPrefix("PROB"))
            }
    }

    /// The METAR's category when it disagrees with the TAF's for this hour.
    private var observedMismatch: String? {
        guard let obs = combined.pressure.current.fltCat, let first = hours.first?.base, obs != first else { return nil }
        return obs
    }

}

// MARK: - The strip

/// The 24 h category strip, drawn by hand: one rounded segment per run of
/// hours, labeled when there is room; night washed behind; TEMPO and PROB
/// windows hatched in their own category's color; sunset, sunrise and now
/// marked. Swift Charts cannot hatch, so this is a Canvas.
struct TafStrip: View {
    struct Overlay: Identifiable {
        let from: Date; let to: Date; let category: String; let isProb: Bool
        var id: Date { from }
    }
    struct HourCell { let t: Date; let base: String? }

    let hours: [TafTimelineCard.HourLike]
    let overlays: [Overlay]
    let start: Date
    let end: Date
    let now: Date
    let nights: [(Date, Date)]
    let sunMarks: [(Date, Bool)]
    let tafEnds: Date?

    private let barTop: CGFloat = 22
    private let barHeight: CGFloat = 40
    private let axisTop: CGFloat = 70

    private func x(_ d: Date, _ w: CGFloat) -> CGFloat {
        let f = d.timeIntervalSince(start) / max(1, end.timeIntervalSince(start))
        return CGFloat(min(1, max(0, f))) * w
    }

    /// Consecutive hours of one category as (category, from, to).
    private var runs: [(String?, Date, Date)] {
        var out: [(String?, Date, Date)] = []
        for h in hours {
            if let last = out.last, last.0 == h.base {
                out[out.count - 1].2 = h.t.addingTimeInterval(3600)
            } else {
                out.append((h.base, h.t, h.t.addingTimeInterval(3600)))
            }
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    // Night, behind everything.
                    for n in nights {
                        let r = CGRect(x: x(n.0, w), y: barTop - 6, width: x(n.1, w) - x(n.0, w), height: barHeight + 12)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(Color.primary.opacity(0.07)))
                    }
                    // Segments.
                    for run in runs {
                        if run.0 == nil, let ends = tafEnds, run.1 >= ends { continue }
                        let x0 = x(run.1, w), x1 = x(run.2, w)
                        let r = CGRect(x: x0 + 0.75, y: barTop, width: max(0, x1 - x0 - 1.5), height: barHeight)
                        let path = Path(roundedRect: r, cornerRadius: 5)
                        let fill: Color = run.0.map { FlightCategory.color($0) } ?? Color.secondary.opacity(0.35)
                        ctx.fill(path, with: .color(fill.opacity(0.9)))
                        if r.width >= 34 {
                            let label = Text(run.0 ?? "—").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                            ctx.draw(ctx.resolve(label), at: CGPoint(x: r.midX, y: r.midY))
                        }
                    }
                    // TEMPO / PROB hatching, clipped to its window.
                    for o in overlays {
                        let x0 = x(o.from, w), x1 = x(o.to, w)
                        let r = CGRect(x: x0, y: barTop, width: x1 - x0, height: barHeight)
                        var sub = ctx
                        sub.clip(to: Path(roundedRect: r, cornerRadius: 5))
                        sub.fill(Path(r), with: .color(FlightCategory.color(o.category).opacity(o.isProb ? 0.25 : 0.35)))
                        var stripes = Path()
                        var sx = r.minX - r.height
                        while sx < r.maxX {
                            stripes.move(to: CGPoint(x: sx, y: r.maxY))
                            stripes.addLine(to: CGPoint(x: sx + r.height, y: r.minY))
                            sx += 7
                        }
                        sub.stroke(stripes, with: .color(FlightCategory.color(o.category).opacity(o.isProb ? 0.6 : 0.95)), lineWidth: 1.5)
                        sub.stroke(Path(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 5),
                                   with: .color(FlightCategory.color(o.category)), lineWidth: 1)
                    }
                    // The TAF running out inside the window.
                    if let ends = tafEnds {
                        let xe = x(ends, w)
                        let r = CGRect(x: xe, y: barTop, width: w - xe, height: barHeight)
                        ctx.fill(Path(r), with: .color(Color(.secondarySystemBackground)))
                        var tick = Path(); tick.move(to: CGPoint(x: xe, y: barTop)); tick.addLine(to: CGPoint(x: xe, y: barTop + barHeight))
                        ctx.stroke(tick, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        if w - xe >= 52 {
                            let label = Text("TAF ends").font(.system(size: 9)).foregroundColor(.secondary)
                            ctx.draw(ctx.resolve(label), at: CGPoint(x: xe + 4, y: barTop + barHeight / 2), anchor: .leading)
                        }
                    }
                    // Sun lines and the now line.
                    for m in sunMarks {
                        var line = Path()
                        line.move(to: CGPoint(x: x(m.0, w), y: barTop - 4)); line.addLine(to: CGPoint(x: x(m.0, w), y: barTop + barHeight + 4))
                        ctx.stroke(line, with: .color(.orange.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                    var nowLine = Path()
                    nowLine.move(to: CGPoint(x: x(now, w), y: barTop - 8)); nowLine.addLine(to: CGPoint(x: x(now, w), y: barTop + barHeight + 8))
                    ctx.stroke(nowLine, with: .color(.primary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    // Hour ticks and labels along the bottom.
                    let cal = Calendar.current
                    var t = cal.date(bySetting: .minute, value: 0, of: start) ?? start
                    while t <= end {
                        let hr = cal.component(.hour, from: t)
                        if hr % 6 == 0 {
                            let label = Text(t.formatted(.dateTime.hour())).font(.system(size: 9)).foregroundColor(.secondary)
                            ctx.draw(ctx.resolve(label), at: CGPoint(x: x(t, w), y: axisTop + 6), anchor: .top)
                            var tick = Path(); tick.move(to: CGPoint(x: x(t, w), y: barTop + barHeight + 2)); tick.addLine(to: CGPoint(x: x(t, w), y: barTop + barHeight + 6))
                            ctx.stroke(tick, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                        }
                        t = t.addingTimeInterval(3600)
                    }
                }
                // Sun icons and the now caption sit above the bar.
                ForEach(sunMarks, id: \.0) { m in
                    Image(systemName: m.1 ? "sunset.fill" : "sunrise.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .position(x: x(m.0, w), y: 9)
                }
                nowCaption(w)
            }
        }
    }

    private func nowCaption(_ w: CGFloat) -> some View {
        Text("now")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .position(x: max(12, x(now, w)), y: 9)
    }
}
