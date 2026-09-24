//  ConfirmationOverlayView.swift
//  Barry — iOS
//
//  The next twelve hours on one chart: rain chance as bars, wind as a
//  dashed line with its gust band, temperature as a dotted line with the
//  high and low marked. Three values across the top are the current
//  readings; tapping one puts its scale on the axis, and the small button
//  beside the others hides or shows that series. Everything is drawn on one
//  0 to 1 plot with each series normalised to its own range, which is what
//  lets three units share a picture without one flattening the others.

import SwiftUI
import Charts

struct ConfirmationOverlayView: View {
    let combined: CombinedResponse
    let now: Date

    @AppStorage("windUnit", store: AppConfig.sharedDefaults)
    private var windUnitRaw: String = WindUnit.mph.rawValue
    private var windUnit: WindUnit { WindUnit(rawValue: windUnitRaw) ?? .mph }
    @AppStorage(TemperatureUnit.key, store: AppConfig.sharedDefaults)
    private var tempUnitRaw: String = TemperatureUnit.celsius.rawValue
    private var tempUnit: TemperatureUnit { TemperatureUnit(rawValue: tempUnitRaw) ?? .celsius }
    /// Which series is on the axis, and which are hidden, across launches.
    @AppStorage("forecastCard.hidden", store: AppConfig.sharedDefaults)
    private var hiddenRaw: String = ""

    enum Series: String, CaseIterable, Identifiable {
        case precip, wind, temp
        var id: String { rawValue }
        var title: String {
            switch self {
            case .precip: return "Precip probability"
            case .wind: return "Wind"
            case .temp: return "Temperature"
            }
        }
        var icon: String {
            switch self {
            case .precip: return "cloud.rain"
            case .wind: return "wind"
            case .temp: return "thermometer.medium"
            }
        }
        var color: Color {
            switch self {
            case .precip: return .blue
            case .wind: return Color(red: 0.22, green: 0.69, blue: 0.88)   // a sky blue, apart from the rain's
            case .temp: return Color(red: 0.87, green: 0.22, blue: 0.20)
            }
        }
    }

    /// The axis always reads rain chance; wind and temperature ride on it.
    private let primary: Series = .precip
    private var hidden: Set<Series> { Set(hiddenRaw.split(separator: ",").compactMap { Series(rawValue: String($0)) }) }
    private func isShown(_ s: Series) -> Bool { s == primary || !hidden.contains(s) }
    private func toggle(_ s: Series) {
        var h = hidden
        if h.contains(s) { h.remove(s) } else { h.insert(s) }
        hiddenRaw = Series.allCases.filter { h.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    static let windowHours = 12

    private var hours: [ForecastHour] {
        (combined.forecast?.hourly ?? [])
            .filter { $0.t >= now.addingTimeInterval(-1800) }
            .prefix(Self.windowHours + 1)
            .map { $0 }
    }

    /// Half an hour of air past the last bar, so it and the "+12 h" label fit.
    private var xDomain: ClosedRange<Date> {
        let first = hours.first?.t ?? now
        return first.addingTimeInterval(-1200)...first.addingTimeInterval(Double(Self.windowHours) * 3600 + 3600)
    }

    // MARK: Ranges, in the unit shown

    private struct Pt: Identifiable { let t: Date; let v: Double; var id: Date { t } }
    private struct WindPt: Identifiable { let t: Date; let w: Double; let g: Double?; var id: Date { t } }

    private var precipValues: [Pt] {
        var out: [Pt] = []
        for h in hours { if let p = h.precip_prob { out.append(Pt(t: h.t, v: Double(p))) } }
        return out
    }
    private var windValues: [WindPt] {
        var out: [WindPt] = []
        for h in hours {
            if let w = h.windspeed {
                let g: Double? = h.windgust.map { windUnit.convert($0) }
                out.append(WindPt(t: h.t, w: windUnit.convert(w), g: g))
            }
        }
        return out
    }
    private var tempValues: [Pt] {
        var out: [Pt] = []
        for h in hours { if let t = h.temperature { out.append(Pt(t: h.t, v: tempUnit.convert(t))) } }
        return out
    }

    /// Wind's axis runs from calm to just past the strongest gust.
    private var windTop: Double {
        let top = windValues.map { max($0.w, $0.g ?? 0) }.max() ?? 10
        return max(5, (top / 5).rounded(.up) * 5)
    }
    /// Never narrower than a real change, so a flat day draws flat instead
    /// of a one-degree wobble filling the plot.
    private var tempRange: ClosedRange<Double> {
        let vals = tempValues.map(\.v)
        guard let lo = vals.min(), let hi = vals.max() else { return 0...10 }
        let minSpan = tempUnit == .celsius ? 6.0 : 10.0
        let span = max(hi - lo, minSpan)
        let mid = (hi + lo) / 2
        return (mid - span / 2)...(mid + span / 2)
    }

    /// Temperature sits inside the plot with room above and below for the
    /// high and low labels.
    private static let tempBand = 0.2...0.86

    private func norm(_ s: Series, _ v: Double) -> Double {
        switch s {
        case .precip: return v / 100
        case .wind: return v / windTop
        case .temp:
            let f = (v - tempRange.lowerBound) / (tempRange.upperBound - tempRange.lowerBound)
            return Self.tempBand.lowerBound + f * (Self.tempBand.upperBound - Self.tempBand.lowerBound)
        }
    }

    /// The axis ticks: rain chance, bottom, middle, top.
    private let axisTicks: [(Double, String)] = [(0, "0%"), (0.5, "50%"), (1, "100%")]

    // MARK: Current readings for the chips

    private var metarWind: CurrentObs? { combined.pressure.current.windspeed != nil ? combined.pressure.current : nil }
    private var windNowKmh: Double { metarWind?.windspeed ?? hours.first?.windspeed ?? 0 }
    private var gustNowKmh: Double? {
        if let g = metarWind?.windgust { return g }
        guard metarWind == nil, let g = hours.first?.windgust, g > windNowKmh + 8 else { return nil }
        return g
    }
    private var windChip: String {
        var s = windUnit.format(windNowKmh)
        if let g = gustNowKmh { s += " G\(windUnit.format(g))" }
        return s + " \(windUnit.label)"
    }
    private var precipChip: String { "\(Int(hours.first?.precip_prob ?? 0))%" }
    private var tempChip: String? {
        (combined.pressure.current.temp ?? hours.first?.temperature).map(tempUnit.format)
    }

    private struct Selection: Equatable { let date: Date }
    @State private var selection: Selection?

    // MARK: Body

    var body: some View {
        if hours.count < 2 {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                chips
                VStack(alignment: .leading, spacing: 6) {
                    Text("Next \(Self.windowHours) hours")
                        .font(.subheadline.weight(.semibold))
                    legend
                    chart
                    if let sel = selection { readout(sel) }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .onChange(of: combined) { _, _ in selection = nil }
        }
    }

    private var chips: some View {
        HStack(spacing: 14) {
            chip(.precip, precipChip)
            chip(.wind, windChip)
            if let t = tempChip { chip(.temp, t) }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    /// The reading now, and for wind and temperature a small button that
    /// hides or shows that line on the chart.
    private func chip(_ s: Series, _ value: String) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: s.icon)
                    .font(.subheadline)
                    .foregroundStyle(s.color)
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(isShown(s) ? Color.primary : Color.secondary)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(s.title) \(value)")
            if s != primary {
                Button { toggle(s) } label: {
                    Image(systemName: hidden.contains(s) ? "plus" : "minus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color(.systemGray3), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hidden.contains(s) ? "Show \(s.title.lowercased())" : "Hide \(s.title.lowercased())")
            }
        }
    }

    /// The rain key only explains bars; a dry window has none.
    private var showsRainKey: Bool { isShown(.precip) && precipValues.contains { $0.v > 0 } }

    private var legend: some View {
        let gusts = windValues.compactMap(\.g)
        let gustText: String = {
            guard let lo = gusts.min(), let hi = gusts.max() else { return "" }
            return " · gusts \(Int(lo.rounded()))–\(Int(hi.rounded())) \(windUnit.label)"
        }()
        let tempText: String = {
            let v = tempValues.map(\.v)
            guard let lo = v.min(), let hi = v.max() else { return "" }
            return " \(TemperatureUnit.degrees(lo).dropLast())–\(TemperatureUnit.degrees(hi))"
        }()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { legendItems(gustText, tempText) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) {
                    if showsRainKey { legendItem(.precip, "Precip probability") }
                    if isShown(.wind) { legendItem(.wind, "Wind\(gustText)") }
                }
                if isShown(.temp) { legendItem(.temp, "Temperature\(tempText)") }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func legendItems(_ gustText: String, _ tempText: String) -> some View {
        if showsRainKey { legendItem(.precip, "Precip probability") }
        if isShown(.wind) { legendItem(.wind, "Wind\(gustText)") }
        if isShown(.temp) { legendItem(.temp, "Temperature\(tempText)") }
    }

    private func legendItem(_ s: Series, _ text: String) -> some View {
        HStack(spacing: 5) {
            if s == .precip {
                // The bars are the rain, so its key is a bar's colour, square.
                RoundedRectangle(cornerRadius: 2)
                    .fill(s.color.opacity(0.85))
                    .frame(width: 10, height: 10)
            } else {
                Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 18, y: 0)) }
                    .stroke(s.color, style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                        dash: s == .wind ? [5, 3] : [1, 3]))
                    .frame(width: 18, height: 2)
            }
            Text(text).lineLimit(1)
        }
    }

    // MARK: Chart

    /// The high and the low, when temperature is on and they are two hours.
    private struct Extreme: Identifiable {
        let t: Date
        let v: Double
        let high: Bool
        var id: String { high ? "H" : "L" }
        var text: String { (high ? "H " : "L ") + TemperatureUnit.degrees(v) }
    }

    private var extremes: [Extreme] {
        guard isShown(.temp), let hi = tempValues.max(by: { $0.v < $1.v }) else { return [] }
        var out = [Extreme(t: hi.t, v: hi.v, high: true)]
        if let lo = tempValues.min(by: { $0.v < $1.v }), lo.t != hi.t {
            out.append(Extreme(t: lo.t, v: lo.v, high: false))
        }
        return out
    }

    private var chart: some View {
        Chart {
            // The clock's edge: a thin blue rule at now.
            RuleMark(x: .value("Now", now))
                .foregroundStyle(Series.precip.color.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.5))

            if isShown(.precip) {
                ForEach(precipValues) { p in
                    // No bar at 0%: an empty hour reads as dry. A slight
                    // chance keeps a small pale stub so it is not mistaken
                    // for nothing; from 10% the bar is its true height.
                    if p.v > 0 {
                        BarMark(x: .value("Time", p.t, unit: .hour),
                                y: .value("Precip", max(0.04, norm(.precip, p.v))), width: .ratio(0.42))
                            .foregroundStyle(Series.precip.color.opacity(p.v < 10 ? 0.35 : 0.85))
                            .cornerRadius(3)
                    }
                }
            }

            if isShown(.wind) {
                ForEach(windValues) { p in
                    if let g = p.g, g > p.w {
                        AreaMark(x: .value("Time", p.t), yStart: .value("Wind", norm(.wind, p.w)), yEnd: .value("Gust", norm(.wind, g)))
                            .foregroundStyle(Series.wind.color.opacity(0.18))
                            .interpolationMethod(.catmullRom)
                    }
                }
                ForEach(windValues) { p in
                    LineMark(x: .value("Time", p.t), y: .value("Wind", norm(.wind, p.w)), series: .value("Series", "wind"))
                        .foregroundStyle(Series.wind.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [5, 3]))
                        .interpolationMethod(.catmullRom)
                }
            }

            if isShown(.temp) {
                ForEach(tempValues) { p in
                    LineMark(x: .value("Time", p.t), y: .value("Temperature", norm(.temp, p.v)), series: .value("Series", "temp"))
                        .foregroundStyle(Series.temp.color)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [1, 3]))
                        .interpolationMethod(.catmullRom)
                }
                ForEach(extremes) { e in
                    PointMark(x: .value("Time", e.t), y: .value("Temperature", norm(.temp, e.v)))
                        .symbol { hollow(Series.temp.color) }
                }
            }

            if let sel = selection {
                RuleMark(x: .value("Selected", sel.date))
                    .foregroundStyle(.primary.opacity(0.25))
            }
        }
        .frame(height: 170)
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...1.08)
        .chartYAxis {
            AxisMarks(position: .trailing, values: axisTicks.map(\.0)) { v in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel {
                    if let d = v.as(Double.self), let tick = axisTicks.first(where: { abs($0.0 - d) < 0.01 }) {
                        Text(tick.1)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(primary.color)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: stride(from: 0, through: Self.windowHours, by: 3).map { hours[0].t.addingTimeInterval(Double($0) * 3600) }) { v in
                let hh = v.as(Date.self).map { Int(($0.timeIntervalSince(hours[0].t) / 3600).rounded()) } ?? 0
                AxisValueLabel(anchor: hh == Self.windowHours ? .topTrailing : .top, collisionResolution: .disabled) {
                    if let d = v.as(Date.self) {
                        let h = Int((d.timeIntervalSince(hours[0].t) / 3600).rounded())
                        // Clock times, so the chart reads against the day: "now", then 5 PM, 8 PM...
                        Text(h == 0 ? "now" : d.formatted(.dateTime.hour()))
                            .font(.caption2.weight(h == 0 ? .semibold : .regular))
                            .foregroundStyle(h == 0 ? Series.precip.color : Color.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { value in select(at: value.location, proxy: proxy, geo: geo) })
                    ForEach(placements(proxy: proxy, geo: geo)) { item in
                        extremeTag(item.extreme).position(item.at)
                    }
                }
            }
        }
    }

    private struct Placed: Identifiable {
        let extreme: Extreme
        let at: CGPoint
        var id: String { extreme.id }
    }

    /// Each label sits straight above (the high) or below (the low) its own
    /// point, at the point's plotted position, nudged in only far enough to
    /// stay inside the plot. The chart's own annotations moved them to
    /// wherever they fit, which read as floating.
    private func placements(proxy: ChartProxy, geo: GeometryProxy) -> [Placed] {
        guard let plot = proxy.plotFrame else { return [] }
        let frame = geo[plot]
        var out: [Placed] = []
        for e in extremes {
            guard let p = proxy.position(for: (x: e.t, y: norm(.temp, e.v))) else { continue }
            let x = min(max(frame.minX + p.x, frame.minX + 22), frame.maxX - 22)
            let y = frame.minY + p.y + (e.high ? -14 : 14)
            out.append(Placed(extreme: e, at: CGPoint(x: x, y: y)))
        }
        return out
    }

    private func extremeTag(_ e: Extreme) -> some View {
        Text(e.text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Series.temp.color)
            .padding(.horizontal, 3)
            .background(Color(.secondarySystemBackground).opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
            .fixedSize()
            .allowsHitTesting(false)
    }

    private func hollow(_ color: Color) -> some View {
        Circle().strokeBorder(color, lineWidth: 2)
            .background(Circle().fill(Color(.secondarySystemBackground)))
            .frame(width: 10, height: 10)
    }

    private func select(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let plot = proxy.plotFrame else { return }
        let x = location.x - geo[plot].origin.x
        guard let date: Date = proxy.value(atX: x),
              let nearest = hours.min(by: { abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date)) })
        else { return }
        selection = selection?.date == nearest.t ? nil : Selection(date: nearest.t)
    }

    /// The tapped hour in words: every series that is on, in its unit.
    private func readout(_ sel: Selection) -> some View {
        let h = hours.first { $0.t == sel.date }
        var parts: [String] = []
        if isShown(.precip), let p = h?.precip_prob { parts.append("\(Int(p))%") }
        if isShown(.wind), let w = h?.windspeed {
            var s = "\(windUnit.format(w))"
            if let g = h?.windgust, g > w + 5.5 { s += " G\(windUnit.format(g))" }
            parts.append(s + " \(windUnit.label)")
        }
        if isShown(.temp), let t = h?.temperature { parts.append(tempUnit.format(t)) }
        return HStack(spacing: 8) {
            Text(sel.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                .font(.caption).foregroundStyle(.secondary)
            Text(parts.joined(separator: " · "))
                .font(.caption.weight(.semibold)).monospacedDigit()
            Text("forecast").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button { selection = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear selection")
        }
    }
}
