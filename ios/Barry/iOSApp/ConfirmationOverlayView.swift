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
    @AppStorage("forecastCard.primary", store: AppConfig.sharedDefaults)
    private var primaryRaw: String = Series.precip.rawValue
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
            case .wind: return .green
            case .temp: return .orange
            }
        }
    }

    private var primary: Series { Series(rawValue: primaryRaw) ?? .precip }
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

    /// A label near either edge of the plot leans inward instead of clipping.
    private func edgeAware(_ t: Date, top: Bool) -> AnnotationPosition {
        let span = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound)
        let f = t.timeIntervalSince(xDomain.lowerBound) / span
        if f < 0.12 { return top ? .topTrailing : .bottomTrailing }
        if f > 0.88 { return top ? .topLeading : .bottomLeading }
        return top ? .top : .bottom
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
    private var tempRange: ClosedRange<Double> {
        let vals = tempValues.map(\.v)
        guard let lo = vals.min(), let hi = vals.max() else { return 0...10 }
        let pad = max(1, (hi - lo) * 0.15)
        return (lo - pad)...(hi + pad)
    }

    private func norm(_ s: Series, _ v: Double) -> Double {
        switch s {
        case .precip: return v / 100
        case .wind: return v / windTop
        case .temp: return (v - tempRange.lowerBound) / (tempRange.upperBound - tempRange.lowerBound)
        }
    }

    /// The axis ticks for the primary series: bottom, middle, top.
    private var axisTicks: [(Double, String)] {
        switch primary {
        case .precip: return [(0, "0%"), (0.5, "50%"), (1, "100%")]
        case .wind: return [0, 0.5, 1].map { ($0, "\(Int(($0 * windTop).rounded())) \(windUnit.label)") }
        case .temp:
            let lo = tempRange.lowerBound, hi = tempRange.upperBound
            return [0, 0.5, 1].map { ($0, TemperatureUnit.degrees(lo + (hi - lo) * $0)) }
        }
    }

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
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(primary.title) · \(Self.windowHours) h")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("Tap a value for its scale")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
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
        HStack(spacing: 6) {
            chip(.precip, precipChip)
            chip(.wind, windChip)
            if let t = tempChip { chip(.temp, t) }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    /// The reading, as a button that puts the series on the axis, and for
    /// the two off the axis a small button that hides or shows them.
    private func chip(_ s: Series, _ value: String) -> some View {
        HStack(spacing: 6) {
            Button { primaryRaw = s.rawValue } label: {
                HStack(spacing: 5) {
                    Image(systemName: s.icon)
                        .font(.subheadline)
                        .foregroundStyle(s.color)
                    Text(value)
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(isShown(s) ? Color.primary : Color.secondary)
                }
                .padding(.horizontal, s == primary ? 10 : 2)
                .padding(.vertical, 6)
                .background(s == primary ? Color(.tertiarySystemFill) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(s.title) \(value)")
            .accessibilityHint(s == primary ? "On the axis" : "Puts this on the axis")
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
                    if isShown(.precip) { legendItem(.precip, "Precip probability") }
                    if isShown(.wind) { legendItem(.wind, "Wind\(gustText)") }
                }
                if isShown(.temp) { legendItem(.temp, "Temperature\(tempText)") }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func legendItems(_ gustText: String, _ tempText: String) -> some View {
        if isShown(.precip) { legendItem(.precip, "Precip probability") }
        if isShown(.wind) { legendItem(.wind, "Wind\(gustText)") }
        if isShown(.temp) { legendItem(.temp, "Temperature\(tempText)") }
    }

    private func legendItem(_ s: Series, _ text: String) -> some View {
        HStack(spacing: 5) {
            Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: 18, y: 0)) }
                .stroke(s.color, style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                    dash: s == .wind ? [5, 3] : (s == .temp ? [1, 3] : [])))
                .frame(width: 18, height: 2)
            Text(text).lineLimit(1)
        }
    }

    // MARK: Chart

    private var chart: some View {
        let tHi = tempValues.max { $0.v < $1.v }
        let tLo = tempValues.min { $0.v < $1.v }
        return Chart {
            // The clock's edge: a thin blue rule at now.
            RuleMark(x: .value("Now", now))
                .foregroundStyle(Series.precip.color.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.5))

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
                if let tHi {
                    PointMark(x: .value("Time", tHi.t), y: .value("Temperature", norm(.temp, tHi.v)))
                        .symbol { hollow(Series.temp.color) }
                        .annotation(position: edgeAware(tHi.t, top: true), spacing: 2) {
                            Text("H \(TemperatureUnit.degrees(tHi.v))")
                                .font(.caption2.weight(.semibold)).foregroundStyle(Series.temp.color)
                        }
                }
                if let tLo, tLo.t != tHi?.t {
                    PointMark(x: .value("Time", tLo.t), y: .value("Temperature", norm(.temp, tLo.v)))
                        .symbol { hollow(Series.temp.color) }
                        .annotation(position: edgeAware(tLo.t, top: false), spacing: 2) {
                            Text("L \(TemperatureUnit.degrees(tLo.v))")
                                .font(.caption2.weight(.semibold)).foregroundStyle(Series.temp.color)
                        }
                }
            }

            if isShown(.precip) {
                ForEach(precipValues) { p in
                    BarMark(x: .value("Time", p.t, unit: .hour), y: .value("Precip", max(0.04, norm(.precip, p.v))), width: .ratio(0.42))
                        .foregroundStyle(Series.precip.color.opacity(0.85))
                        .cornerRadius(3)
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
                AxisValueLabel {
                    if let d = v.as(Date.self) {
                        let h = Int((d.timeIntervalSince(hours[0].t) / 3600).rounded())
                        Text(h == 0 ? "now" : "+\(h) h")
                            .font(.caption2.weight(h == 0 ? .semibold : .regular))
                            .foregroundStyle(h == 0 ? Series.precip.color : Color.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in select(at: value.location, proxy: proxy, geo: geo) })
            }
        }
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
