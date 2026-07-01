//  PressureChartView.swift
//  Barry — iOS
//
//  The hero curve (brief §3): solid observed on the left, dashed forecast on the
//  right, a "now" rule down the middle, and min/max markers. Forecast is dashed on
//  purpose — model pressure is smoothed and real fronts arrive sharper (brief §4.3).

import SwiftUI
import Charts

/// How much of the curve the chart shows around "now". 6h is the focused glance
/// (immediate past + near future); 48h is the full −24h observed / +48h forecast.
enum ChartWindow: String, CaseIterable, Identifiable {
    case hours6
    case hours48

    var id: String { rawValue }
    var label: String { self == .hours6 ? "6h" : "48h" }
    var pastHours: Double { self == .hours6 ? 6 : 24 }
    var futureHours: Double { self == .hours6 ? 6 : 48 }
    var axisStrideHours: Int { self == .hours6 ? 2 : 12 }
}

struct PressureChartView: View {
    let combined: CombinedResponse
    let now: Date
    let unit: PressureUnit
    /// Calibrated phone SLP trace for the last ~60 min. Empty when the feature is
    /// off, uncalibrated, or the device is moving. Rendered as a short orange line
    /// clearly distinct from the METAR observed (blue) line.
    var phoneTrace: [(Date, Double)] = []
    /// Visible time window around `now`. Defaults to the full view.
    var window: ChartWindow = .hours48

    /// The point the user last tapped on the chart — shown in the readout below.
    @State private var selected: SelectionPoint?

    private struct Plot: Identifiable {
        let id = UUID()
        let t: Date
        let value: Double      // already converted to `unit`
        let raw: Double        // underlying hPa — for unit-independent slope
        let observed: Bool
    }

    /// One drawable line segment between two consecutive points, pre-tinted by its
    /// local rate of change (color resolved at build time to keep the chart body
    /// simple enough for the type-checker).
    private struct Segment: Identifiable {
        let id: String
        let p0: Plot
        let p1: Plot
        let color: Color
    }

    private struct SelectionPoint: Equatable {
        let date: Date
        let value: Double  // converted to `unit`
        let observed: Bool // true = recorded, false = forecast
    }

    private var observed: [Plot] {
        combined.observedSeries.compactMap { p in
            p.pressure.map { Plot(t: p.t, value: unit.convert($0), raw: $0, observed: true) }
        }
    }

    private var forecast: [Plot] {
        var pts = combined.forecastSeries(after: now).compactMap { h in
            h.pressure_msl.map { Plot(t: h.t, value: unit.convert($0), raw: $0, observed: false) }
        }
        // Bridge the gap so the dashed line visually connects to "now".
        if let last = observed.last {
            pts.insert(Plot(t: last.t, value: last.value, raw: last.raw, observed: false), at: 0)
        }
        return pts
    }

    private var phone: [Plot] {
        phoneTrace.map { Plot(t: $0.0, value: unit.convert($0.1), raw: $0.1, observed: true) }
    }

    // MARK: - Slope → color (rate-of-change intensity)

    /// Below this |slope| the line reads as "steady"; at/above `slopeCeil` it's fully
    /// saturated. Tuned in hPa/hour: a few tenths is routine, ~1+ is a sharp move.
    private static let slopeFloor = 0.2
    private static let slopeCeil = 1.5

    /// Color a segment by its rate of change (shared with the watch sparkline via
    /// TendencyClass.slopeColor). Forecast segments are lightened.
    private func slopeColor(_ slopePerHour: Double, forecast: Bool) -> Color {
        let base = TendencyClass.slopeColor(hPaPerHour: slopePerHour,
                                            floor: Self.slopeFloor, ceil: Self.slopeCeil)
        return forecast ? base.opacity(0.6) : base
    }

    private func segments(_ plots: [Plot], prefix: String, forecast: Bool) -> [Segment] {
        guard plots.count >= 2 else { return [] }
        return (0..<(plots.count - 1)).map { i in
            let a = plots[i], b = plots[i + 1]
            let dt = b.t.timeIntervalSince(a.t) / 3600.0
            let slope = dt > 0 ? (b.raw - a.raw) / dt : 0
            return Segment(id: "\(prefix)-\(i)", p0: a, p1: b,
                           color: slopeColor(slope, forecast: forecast))
        }
    }

    private var observedSegments: [Segment] { segments(visibleObserved, prefix: "obs", forecast: false) }
    private var forecastSegments: [Segment] { segments(visibleForecast, prefix: "fc", forecast: true) }

    // The window the user asked for (−pastHours … +futureHours around now).
    private var requestedBounds: (Date, Date) {
        (now.addingTimeInterval(-window.pastHours * 3600),
         now.addingTimeInterval(window.futureHours * 3600))
    }

    // --- visible window: clip every series so the y-scale, markers, and axes all
    // reflect only what's on screen (otherwise 6h looks flat under a 72h y-range).
    //
    // We shrink the x-domain to the data we actually have inside the requested
    // window, so a partly-filled window (e.g. a fresh install with < 24h of history,
    // or a forecast shorter than +48h) still draws edge-to-edge instead of leaving
    // the curve squished into a corner. "now" is always kept in range.
    private var domainBounds: (Date, Date) {
        let (lo, hi) = requestedBounds
        let times = (observed + forecast + phone).map(\.t).filter { $0 >= lo && $0 <= hi }
        guard let earliest = times.min(), let latest = times.max() else { return (lo, hi) }
        let left = min(max(earliest, lo), now)
        let right = max(min(latest, hi), now)
        return right > left ? (left, right) : (lo, hi)
    }

    private func clip(_ plots: [Plot]) -> [Plot] {
        let (lo, hi) = domainBounds
        return plots.filter { $0.t >= lo && $0.t <= hi }
    }

    private var visibleObserved: [Plot] { clip(observed) }
    private var visibleForecast: [Plot] { clip(forecast) }
    private var visiblePhone: [Plot] { clip(phone) }

    private var allValues: [Double] {
        (visibleObserved + visibleForecast + visiblePhone).map(\.value)
    }
    private var minPoint: Plot? { (visibleObserved + visibleForecast).min { $0.value < $1.value } }
    private var maxPoint: Plot? { (visibleObserved + visibleForecast).max { $0.value < $1.value } }

    /// Pressure value at "now" — the junction where observed hands off to forecast.
    private var nowValue: Double? { visibleObserved.last?.value ?? visibleForecast.first?.value }

    /// Points the tap-to-read gesture can land on: recorded observations plus the
    /// forecast strictly after the last observation (drops the synthetic bridge point
    /// so the junction isn't mislabeled "forecast").
    private var selectablePlots: [Plot] {
        let obsEnd = observed.last?.t ?? .distantPast
        return visibleObserved + visibleForecast.filter { $0.t > obsEnd }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chartView
                .frame(height: 220)
            readout
        }
    }

    // MARK: - Chart content (split so the type-checker doesn't time out)

    // Observed: one colored segment per hop, tinted by its rate of change so a steep
    // rise/fall reads darker than a gentle one. Two endpoints share a series id so
    // Charts draws them as a single straight, solidly-colored hop.
    @ChartContentBuilder private var observedLineContent: some ChartContent {
        ForEach(observedSegments) { seg in
            LineMark(x: .value("Time", seg.p0.t), y: .value("Pressure", seg.p0.value),
                     series: .value("Series", seg.id))
                .foregroundStyle(seg.color)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
            LineMark(x: .value("Time", seg.p1.t), y: .value("Pressure", seg.p1.value),
                     series: .value("Series", seg.id))
                .foregroundStyle(seg.color)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
    }

    // Forecast: same rate-of-change coloring, drawn dashed + lightened.
    @ChartContentBuilder private var forecastLineContent: some ChartContent {
        ForEach(forecastSegments) { seg in
            LineMark(x: .value("Time", seg.p0.t), y: .value("Pressure", seg.p0.value),
                     series: .value("Series", seg.id))
                .foregroundStyle(seg.color)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [5, 4]))
            LineMark(x: .value("Time", seg.p1.t), y: .value("Pressure", seg.p1.value),
                     series: .value("Series", seg.id))
                .foregroundStyle(seg.color)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [5, 4]))
        }
    }

    @ChartContentBuilder private var phoneContent: some ChartContent {
        // Phone barometer local trace (§4.5.5): short orange line over the last
        // ~60 min, shown only when calibrated + stationary.
        if !visiblePhone.isEmpty {
            if let baseline = (visibleObserved.last ?? observed.last)?.value {
                ForEach(visiblePhone) { p in
                    AreaMark(x: .value("Time", p.t),
                             yStart: .value("Baseline", baseline),
                             yEnd: .value("Local", p.value))
                        .foregroundStyle(.orange.opacity(0.12))
                        .interpolationMethod(.catmullRom)
                }
            }
            ForEach(visiblePhone) { p in
                LineMark(x: .value("Time", p.t), y: .value("Pressure", p.value),
                         series: .value("Series", "phone"))
                    .foregroundStyle(.orange.opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)
            }
            if let last = visiblePhone.last {
                PointMark(x: .value("Time", last.t), y: .value("Pressure", last.value))
                    .foregroundStyle(.orange)
                    .annotation(position: .trailing, alignment: .center) {
                        Text("local")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
            }
        }
    }

    @ChartContentBuilder private var featureContent: some ChartContent {
        // Interpreter feature pin (§4.3): a dashed purple guide at the detected /
        // forecast feature time (the verdict's "trough at 6pm" on the curve).
        if let reading = combined.reading,
           let ft = reading.featureTime,
           ft >= domainBounds.0, ft <= domainBounds.1,
           let label = featureChartLabel(reading.feature) {
            RuleMark(x: .value("Feature", ft))
                .foregroundStyle(.purple.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .top, alignment: .center, spacing: 2) {
                    VStack(spacing: 0) {
                        Text(label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.purple)
                        if reading.caveats.contains("forecast_derived") {
                            Text("forecast")
                                .font(.system(size: 8))
                                .foregroundStyle(.purple.opacity(0.6))
                        }
                    }
                }
        }
    }

    @ChartContentBuilder private var overlayContent: some ChartContent {
        RuleMark(x: .value("Now", now))
            .foregroundStyle(.secondary.opacity(0.5))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            .annotation(position: .top, alignment: .center) {
                Text("now").font(.caption2).foregroundStyle(.secondary)
            }

        if let lo = minPoint {
            PointMark(x: .value("Time", lo.t), y: .value("Pressure", lo.value))
                .foregroundStyle(.secondary)
                .symbolSize(28)
                .annotation(position: .bottom) { marker(lo.value) }
        }
        if let hi = maxPoint {
            PointMark(x: .value("Time", hi.t), y: .value("Pressure", hi.value))
                .foregroundStyle(.secondary)
                .symbolSize(28)
                .annotation(position: .top) { marker(hi.value) }
        }

        // Solid blue "now" dot at the observed → forecast junction.
        if let nowValue {
            PointMark(x: .value("Now", now), y: .value("Pressure", nowValue))
                .foregroundStyle(.blue)
                .symbolSize(90)
        }

        // Tap-to-read selection: a guide line + dot at the chosen time.
        if let sel = selected {
            RuleMark(x: .value("Selected", sel.date))
                .foregroundStyle(.primary.opacity(0.25))
                .lineStyle(StrokeStyle(lineWidth: 1))
            PointMark(x: .value("Selected", sel.date), y: .value("Pressure", sel.value))
                .foregroundStyle(sel.observed ? Color.blue : Color.blue.opacity(0.5))
                .symbolSize(70)
        }
    }

    // Chart marks are split into @ChartContentBuilder pieces above — as one big
    // literal the Swift type-checker times out.
    private var chartView: some View {
        Chart {
            observedLineContent
            forecastLineContent
            phoneContent
            featureContent
            overlayContent
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: domainBounds.0...domainBounds.1)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: window.axisStrideHours)) { value in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxisLabel(unit.label)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            selectAt(location: value.location, proxy: proxy, geo: geo)
                        }
                    )
            }
        }
        .onChange(of: combined) { _, _ in selected = nil }
    }

    // MARK: - Tap-to-read

    private func selectAt(location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let xInPlot = location.x - geo[plotFrame].origin.x
        let date: Date? = proxy.value(atX: xInPlot)
        guard let date,
              let nearest = selectablePlots.min(by: {
                  abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date))
              })
        else { return }
        selected = SelectionPoint(date: nearest.t, value: nearest.value, observed: nearest.observed)
    }

    @ViewBuilder private var readout: some View {
        if let sel = selected {
            HStack(spacing: 8) {
                Circle()
                    .fill(sel.observed ? Color.blue : Color.blue.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(sel.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                Text(valueString(sel.value))
                    .font(.caption.weight(.semibold)).monospacedDigit()
                Text(sel.observed ? "recorded" : "forecast")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button { selected = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear selection")
            }
        } else {
            slopeLegend
        }
    }

    /// Compact key for the line coloring: a blue ramp where deeper blue = a faster
    /// change (steeper rise or fall). Doubles as the tap-to-read hint.
    private var slopeLegend: some View {
        HStack(spacing: 10) {
            legendSwatch(colors: [TendencyClass.blueRamp(0.0), TendencyClass.blueRamp(1.0)],
                         label: "deeper = faster change")
            Spacer()
            Text("tap to read")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func legendSwatch(colors: [Color], label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                .frame(width: 22, height: 5)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func valueString(_ v: Double) -> String {
        String(format: unit == .hPa ? "%.1f" : "%.2f", v) + " " + unit.label
    }

    private func marker(_ v: Double) -> some View {
        Text(String(format: unit == .hPa ? "%.0f" : "%.2f", v))
            .font(.caption2).monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private func featureChartLabel(_ feature: String) -> String? {
        switch feature {
        case "approaching_trough", "trough_passing": return "trough"
        case "ridge_peak":                            return "ridge"
        case "front_knee":                            return "front edge"
        case "post_trough_recovery":                  return "past trough"
        default:                                       return nil
        }
    }

    private var yDomain: ClosedRange<Double> {
        guard let lo = allValues.min(), let hi = allValues.max(), lo < hi else {
            return 0...1
        }
        let pad = max((hi - lo) * 0.15, unit == .hPa ? 1 : 0.03)
        return (lo - pad)...(hi + pad)
    }
}
