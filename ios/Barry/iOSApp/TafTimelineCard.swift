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
    private struct Hour: Identifiable {
        let t: Date
        let base: String?
        let tempo: String?
        var id: Date { t }
    }

    private var taf: TafOut? { combined.taf }

    private var span: (start: Date, end: Date) {
        let cal = Calendar.current
        let start = cal.date(bySetting: .minute, value: 0, of: now).map { cal.date(bySetting: .second, value: 0, of: $0) ?? $0 } ?? now
        var end = start.addingTimeInterval(24 * 3600)
        if let to = taf?.validTo, to < end { end = to }
        return (start, end)
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
            let b = base.last { $0.timeFrom <= t }?.fltCat
            let o = overlays.first { $0.timeFrom <= t && t < $0.timeTo }?.fltCat
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
        // The distinct run of base categories with the hour each begins.
        var runs: [(String, Date)] = [(first, hs[0].t)]
        for h in hs { if let b = h.base, b != runs.last!.0 { runs.append((b, h.t)) } }
        var s: String
        if runs.count == 1 {
            s = "\(first) through the forecast"
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
                legend
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var timeline: some View {
        let (start, end) = span
        return Chart {
            ForEach(nights, id: \.0) { n in
                RectangleMark(xStart: .value("Night", n.0), xEnd: .value("Night", n.1),
                              yStart: .value("y", 0), yEnd: .value("y", 1))
                    .foregroundStyle(Color.primary.opacity(0.07))
            }
            ForEach(hours) { h in
                if let b = h.base {
                    RectangleMark(xStart: .value("Time", h.t), xEnd: .value("Time", h.t.addingTimeInterval(3600)),
                                  yStart: .value("y", 0), yEnd: .value("y", 0.62))
                        .foregroundStyle(FlightCategory.color(b))
                }
                if let t = h.tempo {
                    RectangleMark(xStart: .value("Time", h.t), xEnd: .value("Time", h.t.addingTimeInterval(3600)),
                                  yStart: .value("y", 0.66), yEnd: .value("y", 1))
                        .foregroundStyle(FlightCategory.color(t).opacity(0.55))
                }
            }
            ForEach(sunMarks, id: \.0) { m in
                RuleMark(x: .value("Sun", m.0), yStart: .value("y", 0), yEnd: .value("y", 1.0))
                    .foregroundStyle(.orange.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                PointMark(x: .value("Sun", m.0), y: .value("y", 1.18))
                    .symbol {
                        Image(systemName: m.1 ? "sunset.fill" : "sunrise.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
            }
            RuleMark(x: .value("Now", now), yStart: .value("y", 0), yEnd: .value("y", 1.0))
                .foregroundStyle(.tertiary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
        .frame(height: 74)
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...1.35)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) {
                AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9))
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(["VFR", "MVFR", "IFR", "LIFR"], id: \.self) { c in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(FlightCategory.color(c)).frame(width: 8, height: 8)
                    Text(c)
                }
            }
            Text("· lighter = TEMPO").foregroundStyle(.secondary)
            Spacer()
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
    }
}
