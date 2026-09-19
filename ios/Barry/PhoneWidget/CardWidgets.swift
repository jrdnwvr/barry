//  CardWidgets.swift
//  Barry — iPhone Widget
//
//  The app's cards as home screen widgets: the TAF strip, the field glance,
//  the trend with its curve, and the runway dial. Each is the card the app
//  draws, on the same shared model, so they never disagree with the app.

import SwiftUI
import WidgetKit

// MARK: - Shared bits

private struct Stale: View {
    let entry: CombinedEntry
    var body: some View {
        if entry.isStale, let at = entry.savedAt {
            Text("as of \(at.formatted(date: .omitted, time: .shortened))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct NoData: View {
    let text: String
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "airplane").foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private func unitPref() -> PressureUnit {
    PressureUnit(rawValue: AppConfig.sharedDefaults.string(forKey: "pressureUnit") ?? "") ?? .inHg
}

/// "160@7" / "160@7G14" / "calm", the TAF's own shorthand.
private func windShort(_ cur: CurrentObs) -> String {
    let kt = (cur.windspeed ?? 0) / 1.852
    guard kt >= 1, let d = cur.winddir else { return "calm" }
    var s = "\(String(format: "%03d", Int(d.rounded())))@\(Int(kt.rounded()))"
    if let g = cur.windgust, g / 1.852 >= kt + 3 { s += "G\(Int((g / 1.852).rounded()))" }
    return s
}

// MARK: - TAF

struct TafWidget: Widget {
    let kind = "BarryTafWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CombinedProvider()) { entry in
            TafWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("TAF")
        .description("Flight category by the hour for the next 24 hours, with sunset and sunrise.")
        .supportedFamilies([.systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct TafWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CombinedEntry

    private var timeline: TafTimeline? {
        entry.combined.flatMap { TafTimeline(combined: $0, now: entry.date) }
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            if let tl = timeline {
                Text("\(entry.combined?.pressure.station ?? "") \(tl.shortSentence)")
            } else {
                Text("No TAF")
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                if let tl = timeline {
                    Text(entry.combined?.pressure.station ?? "")
                        .font(.caption2.weight(.semibold))
                    Text(tl.shortSentence)
                        .font(.caption2)
                        .lineLimit(2)
                    TafStrip(timeline: tl, compact: true)
                        .widgetAccentable()
                } else {
                    Text("No TAF for \(entry.combined?.pressure.station ?? "this field")")
                        .font(.caption2)
                }
            }
        default:
            if let tl = timeline, let c = entry.combined {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("TAF").font(.caption.weight(.semibold))
                        Text(c.pressure.station).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if entry.isStale {
                            Stale(entry: entry)
                        } else if let issued = tl.issueTime {
                            Text("issued \(issued.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(tl.sentence)
                        .font(.caption)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                    TafStrip(timeline: tl)
                        .frame(height: 84)
                        .clipped()
                }
            } else {
                NoData(text: "No TAF for \(entry.combined?.pressure.station ?? "this field")")
            }
        }
    }
}

// MARK: - Field glance

struct FieldGlanceWidget: Widget {
    let kind = "BarryFieldGlanceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CombinedProvider()) { entry in
            FieldGlanceView(entry: entry)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Field")
        .description("The station's report at a glance: category, wind, altimeter, ceiling, density altitude.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct FieldGlanceView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CombinedEntry

    private var unit: PressureUnit { unitPref() }

    var body: some View {
        if let c = entry.combined {
            let cur = c.pressure.current
            let cat = cur.fltCat
            VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(c.pressure.station)
                        .font(.headline)
                    if let cat {
                        Text(cat)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(entry.isStale ? Color.gray : FlightCategory.color(cat))
                        if cur.fltCatDerived == true {
                            Circle().fill(FlightCategory.color(cat)).frame(width: 5, height: 5)
                        }
                    }
                    Spacer()
                    if family != .systemSmall {
                        Text(age(c)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Label(windShort(cur), systemImage: "wind")
                    if let a = cur.altim {
                        Label("\(unit.format(a))", systemImage: "gauge.with.needle")
                    }
                }
                .font(.system(.subheadline, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.7)
                if family == .systemSmall {
                    if let ceiling = ceilingText(cur) {
                        Text(ceiling).font(.caption).foregroundStyle(.secondary)
                    }
                    if let v = cur.visibilitySM {
                        Text("\(v.formatted()) SM").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let da = c.conditions?.densityAltitudeFt {
                        Text("DA \(da.formatted()) ft").font(.caption).foregroundStyle(.secondary)
                    }
                    if entry.isStale { Stale(entry: entry) } else {
                        Text(age(c)).font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    Divider()
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            if let v = cur.visibilitySM { row("Visibility", "\(v.formatted()) SM") }
                            if let ceiling = ceilingText(cur) { row(isCeiling(cur) ? "Ceiling" : "Clouds", ceiling) }
                            if let t = cur.temp { row("Temp", "\(Int(t.rounded()))°\(cur.dewpoint.map { " / \(Int($0.rounded()))°" } ?? "")") }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            if let da = c.conditions?.densityAltitudeFt { row("Density alt", "\(da.formatted()) ft") }
                            if let elev = c.conditions?.fieldElevationFt { row("Field", "\(elev.formatted()) ft") }
                            if let slp = cur.slp, cur.altim != nil { row("Sea level", unit.format(slp)) }
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    if entry.isStale { Stale(entry: entry) }
                }
            }
        } else {
            NoData(text: "Open Barry once to load a station.")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    /// FEW and SCT are layers, not a ceiling.
    private func isCeiling(_ cur: CurrentObs) -> Bool {
        ["BKN", "OVC", "VV"].contains(cur.ceilingCover ?? "")
    }

    private func ceilingText(_ cur: CurrentObs) -> String? {
        guard let ft = cur.ceilingFt else { return cur.ceilingCover == nil ? nil : cur.ceilingCover }
        return "\(cur.ceilingCover ?? "") \(ft.formatted()) ft".trimmingCharacters(in: .whitespaces)
    }

    private func age(_ c: CombinedResponse) -> String {
        let last = c.observedSeries.last?.t ?? c.pressure.cachedAt
        let m = max(0, Int(entry.date.timeIntervalSince(last) / 60))
        return m < 60 ? "\(m) min ago" : "\(m / 60) h ago"
    }
}

// MARK: - Trend, medium

struct TrendWidget: Widget {
    let kind = "BarryTrendWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CombinedProvider()) { entry in
            TrendWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Pressure Trend, with the curve")
        .description("The reading, the 3-hour change, the verdict, and the last 12 hours drawn as a line.")
        .supportedFamilies([.systemMedium])
    }
}

struct TrendWidgetView: View {
    let entry: CombinedEntry
    private var unit: PressureUnit { unitPref() }

    var body: some View {
        if let c = entry.combined {
            let snap = TendencySnapshot(from: c, updatedAt: entry.savedAt ?? entry.date, atAirport: entry.atAirport)
            let cls = snap.cls
            let tint: Color = entry.isStale ? .gray : cls.color(intensity: max(0.35, snap.intensity))
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: snap.trendSymbolName)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(tint)
                        Text(c.pressure.station).font(.caption).foregroundStyle(.secondary)
                    }
                    if let p = snap.displayPressureHPa {
                        Text("\(unit.format(p)) \(unit.label)")
                            .font(.title3.weight(.semibold)).monospacedDigit()
                    }
                    Text("\(unit.formatDelta(snap.delta3h)) · 3h")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Spacer(minLength: 0)
                    Text(c.verdict)
                        .font(.caption2)
                        .lineLimit(c.lightningNearby == nil ? 3 : 2)
                    if let n = c.lightningNearby {
                        Label(n.headline(now: entry.date), systemImage: "bolt.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(n.distanceMi < 3 ? Color.red : Color.orange)
                            .lineLimit(1)
                    }
                    if entry.isStale { Stale(entry: entry) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                TrendSpark(points: snap.spark ?? [], stale: entry.isStale, expected: snap.expectedDelta3h)
                    .frame(width: 120)
            }
        } else {
            NoData(text: "Open Barry once to load a station.")
        }
    }
}

/// The last ~12 h as the slope-colored line, a dot at now, the dashed model tail.
private struct TrendSpark: View {
    let points: [SparkPoint]
    let stale: Bool
    let expected: Double?

    var body: some View {
        Canvas { ctx, size in
            guard points.count >= 2, let t0 = points.first?.t, let t1 = points.last?.t, t1 > t0 else { return }
            let tail = expected.map { (points.last!.t.addingTimeInterval(2 * 3600), points.last!.p + $0 * (2.0 / 3.0)) }
            let tEnd = tail?.0 ?? t1
            var lo = points.map(\.p).min()!, hi = points.map(\.p).max()!
            if let tail { lo = min(lo, tail.1); hi = max(hi, tail.1) }
            let pad = max(0.6, (hi - lo) * 0.15); lo -= pad; hi += pad
            func pt(_ t: Date, _ p: Double) -> CGPoint {
                let x = CGFloat(t.timeIntervalSince(t0) / tEnd.timeIntervalSince(t0)) * (size.width - 8) + 4
                let y = size.height - 4 - CGFloat((p - lo) / (hi - lo)) * (size.height - 8)
                return CGPoint(x: x, y: y)
            }
            let times = points.map(\.t), values = points.map(\.p)
            for i in 1..<points.count {
                var seg = Path()
                seg.move(to: pt(points[i - 1].t, points[i - 1].p))
                seg.addLine(to: pt(points[i].t, points[i].p))
                let slope = PressureSlope.windowed(times: times, values: values, at: i)
                let color = stale ? Color.gray : TendencyClass.slopeColor(hPaPerHour: slope)
                ctx.stroke(seg, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            if let tail {
                var dash = Path()
                dash.move(to: pt(points.last!.t, points.last!.p))
                dash.addLine(to: pt(tail.0, tail.1))
                ctx.stroke(dash, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            let last = pt(points.last!.t, points.last!.p)
            ctx.fill(Path(ellipseIn: CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7, height: 7)),
                     with: .color(stale ? .gray : .orange))
        }
    }
}

// MARK: - Runway winds

struct RunwayWindsWidget: Widget {
    let kind = "BarryRunwayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CombinedProvider()) { entry in
            RunwayWindsWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(.systemBackground) }
        }
        .configurationDisplayName("Runway Winds")
        .description("The wind on the rose, and the crosswind on the best runway at an airport.")
        .supportedFamilies([.systemSmall])
    }
}

struct RunwayWindsWidgetView: View {
    let entry: CombinedEntry

    private var mode: RunwayWindsMode {
        RunwayWindsMode(rawValue: AppConfig.sharedDefaults.string(forKey: RunwayWindsMode.key) ?? "") ?? .auto
    }

    var body: some View {
        if let c = entry.combined {
            let cur = c.pressure.current
            let kt = (cur.windspeed ?? 0) / 1.852
            let gust = cur.windgust.map { $0 / 1.852 }
            let runways = mode.usesRunways(atAirport: entry.atAirport) ? Runway.merged(c.runways ?? []) : []
            let winds = RunwayWinds.compute(runways: runways, windDirDeg: cur.winddir, windKt: kt, gustKt: gust)
            let best = winds.first
            let caption = best.map { RunwayWinds.compact($0) }
                ?? (kt >= 1 ? "\(String(format: "%03d", Int((cur.winddir ?? 0).rounded()))) at \(Int(kt.rounded())) kt" : "calm")
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(c.pressure.station).font(.caption.weight(.semibold))
                    Spacer()
                    if entry.isStale { Stale(entry: entry) }
                }
                // The caption sits up here, clear of the barb's own label,
                // which lands at the bottom of the rose in a southerly wind.
                Text(caption)
                    .font(.caption2).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
                RunwayWindDial(runways: best.map { b in runways.filter { $0.le == b.ident || $0.he == b.ident } } ?? [],
                               bestIdent: best?.ident, windDirDeg: cur.winddir, windKt: kt, gustKt: gust)
                    .padding(.horizontal, -24)
                    .padding(.vertical, -14)
            }
        } else {
            NoData(text: "Open Barry once to load a station.")
        }
    }
}
