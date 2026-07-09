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
    /// A dragged time range + its analysis — shown as a card below the chart.
    @State private var rangeSelection: ClosedRange<Date>?
    @State private var rangeAnalysis: RangeAnalysis?

    private struct Plot: Identifiable {
        let id = UUID()
        let t: Date
        let value: Double      // already converted to `unit`
        let raw: Double        // underlying hPa — for unit-independent slope
        let observed: Bool
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

    /// Window (± hours) over which each point's slope is fit. ~3 h total matches the
    /// tendency timescale and smooths out sub-window reporting jitter.
    private static let slopeWindowHours = 1.5

    /// Gradient color stops for a line: one stop per point, colored by its *windowed*
    /// slope (so noise doesn't read as steepness) and positioned at the point's
    /// fraction across the plot-wide x-domain. Swift Charts resolves the gradient in
    /// plot space, so the line blends smoothly along its length. Forecast is lightened.
    private func gradientStops(_ plots: [Plot], forecast: Bool) -> [Gradient.Stop] {
        let (lo, hi) = domainBounds
        let span = hi.timeIntervalSince(lo)
        guard plots.count >= 2, span > 0 else { return [] }
        let times = plots.map(\.t)
        let raws = plots.map(\.raw)
        return plots.enumerated().map { i, p in
            let loc = min(1.0, max(0.0, p.t.timeIntervalSince(lo) / span))
            let slope = PressureSlope.windowed(times: times, values: raws, at: i,
                                               windowHours: Self.slopeWindowHours)
            let base = TendencyClass.slopeColor(hPaPerHour: slope,
                                                floor: Self.slopeFloor, ceil: Self.slopeCeil)
            return Gradient.Stop(color: forecast ? base.opacity(0.6) : base, location: loc)
        }
    }

    private var observedGradient: LinearGradient {
        LinearGradient(stops: gradientStops(visibleObserved, forecast: false),
                       startPoint: .leading, endPoint: .trailing)
    }
    private var forecastGradient: LinearGradient {
        LinearGradient(stops: gradientStops(visibleForecast, forecast: true),
                       startPoint: .leading, endPoint: .trailing)
    }

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

    /// The current-reading dot: anchored to the *actual* last observation (its real
    /// time + value, = the headline number), so it sits on the line where observed
    /// hands off to forecast — not floating at the "now" tick, which is later than the
    /// last hourly METAR. Falls back to the first forecast point if there's no observed.
    private var nowPoint: (date: Date, value: Double)? {
        if let last = visibleObserved.last { return (last.t, last.value) }
        if let first = visibleForecast.first { return (first.t, first.value) }
        return nil
    }

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

    // Observed: a single smooth line whose color blends along its length by rate of
    // change (steep = deeper blue), via a plot-space gradient of per-point stops.
    @ChartContentBuilder private var observedLineContent: some ChartContent {
        if visibleObserved.count >= 2 {
            ForEach(visibleObserved) { p in
                LineMark(x: .value("Time", p.t), y: .value("Pressure", p.value),
                         series: .value("Series", "observed"))
            }
            .foregroundStyle(observedGradient)
            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .interpolationMethod(.catmullRom)
        }
    }

    // Forecast: same blended coloring, drawn dashed + lightened.
    @ChartContentBuilder private var forecastLineContent: some ChartContent {
        if visibleForecast.count >= 2 {
            ForEach(visibleForecast) { p in
                LineMark(x: .value("Time", p.t), y: .value("Pressure", p.value),
                         series: .value("Series", "forecast"))
            }
            .foregroundStyle(forecastGradient)
            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [5, 4]))
            .interpolationMethod(.catmullRom)
        }
    }

    /// Recording gaps longer than this break the line. Set to ~90 min: the station
    /// line itself bridges hourly METARs, so local points at METAR-class density
    /// (background refresh lands roughly hourly when iOS cooperates) deserve the
    /// same treatment. Multi-hour holes still break honestly.
    private static let phoneGapSeconds: TimeInterval = 90 * 60

    private struct PhoneSegment: Identifiable {
        let id: Int
        let points: [Plot]
    }

    /// A recording run needs this much continuous span to read as a LINE; shorter
    /// bursts (open the app for a minute, two points land) render as dots instead —
    /// tiny two-point slivers look like broken glass scattered on the chart.
    private static let phoneMinLineSpan: TimeInterval = 20 * 60

    /// Continuous recording runs, split at gaps.
    private var phoneRuns: [[Plot]] {
        var groups: [[Plot]] = []
        for p in visiblePhone {
            if let last = groups.last?.last,
               p.t.timeIntervalSince(last.t) <= Self.phoneGapSeconds {
                groups[groups.count - 1].append(p)
            } else {
                groups.append([p])
            }
        }
        return groups
    }

    /// Runs long enough to draw as line segments. Two points an hour apart are a
    /// legitimate hour of trend (that's exactly what the station line does with
    /// hourly METARs) — the span requirement is what kills sub-minute slivers.
    private var phoneSegments: [PhoneSegment] {
        phoneRuns.enumerated()
            .filter { _, run in
                guard run.count >= 2, let first = run.first, let last = run.last
                else { return false }
                return last.t.timeIntervalSince(first.t) >= Self.phoneMinLineSpan
            }
            .map { PhoneSegment(id: $0.offset, points: $0.element) }
    }

    /// Everything too short for a line — shown as discrete spot readings, matching
    /// how station dots communicate "a measurement happened here".
    private var phoneDots: [Plot] {
        let lineIDs = Set(phoneSegments.map(\.id))
        return phoneRuns.enumerated()
            .filter { !lineIDs.contains($0.offset) }
            .flatMap { $0.element }
    }

    @ChartContentBuilder private var phoneContent: some ChartContent {
        // Phone barometer local trace: sustained runs as orange lines, brief bursts
        // as orange dots. Clipped to the window like every other series.
        ForEach(phoneSegments) { seg in
            ForEach(seg.points) { p in
                LineMark(x: .value("Time", p.t), y: .value("Pressure", p.value),
                         series: .value("Series", "phone-\(seg.id)"))
                    .foregroundStyle(.orange.opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)
            }
        }
        ForEach(phoneDots) { p in
            PointMark(x: .value("Time", p.t), y: .value("Pressure", p.value))
                .foregroundStyle(.orange.opacity(0.85))
                .symbolSize(16)
        }
        // End dot — the freshest local reading, slightly larger. The "local" text
        // label lives in the legend row below.
        if let last = visiblePhone.last {
            PointMark(x: .value("Time", last.t), y: .value("Pressure", last.value))
                .foregroundStyle(.orange)
                .symbolSize(40)
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
        // "now" label sits below the chart — keeps the top clear for the feature
        // pin ("trough", "front edge", …) so the two never overlap.
        RuleMark(x: .value("Now", now))
            .foregroundStyle(.secondary.opacity(0.5))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            .annotation(position: .bottom, alignment: .center, spacing: 2) {
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

        // Solid blue dot on the latest actual reading (observed → forecast junction).
        if let np = nowPoint {
            PointMark(x: .value("Now", np.date), y: .value("Pressure", np.value))
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

        // Drag-selected range: shaded band with edge rules, Screen Time style.
        if let r = rangeSelection {
            RectangleMark(xStart: .value("Start", r.lowerBound),
                          xEnd: .value("End", r.upperBound))
                .foregroundStyle(.blue.opacity(0.08))
            RuleMark(x: .value("Start", r.lowerBound))
                .foregroundStyle(.blue.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1))
            RuleMark(x: .value("End", r.upperBound))
                .foregroundStyle(.blue.opacity(0.4))
                .lineStyle(StrokeStyle(lineWidth: 1))
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
                // Hour labels pushed down a row so the "now" label (annotated at the
                // bottom of the now-rule) gets the band directly under the plot to
                // itself — no more colliding with a time label.
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(d, format: .dateTime.hour())
                            .padding(.top, 14)
                    }
                }
            }
        }
        .chartYAxisLabel(unit.label)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            rangeSelection = nil
                            rangeAnalysis = nil
                            selectAt(location: value.location, proxy: proxy, geo: geo)
                        }
                    )
                    // Horizontal drag paints an analysis range; the minimum
                    // distance keeps vertical page scrolling working.
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onChanged { g in
                                guard let plotFrame = proxy.plotFrame else { return }
                                let x0 = g.startLocation.x - geo[plotFrame].origin.x
                                let x1 = g.location.x - geo[plotFrame].origin.x
                                guard let d0: Date = proxy.value(atX: x0),
                                      let d1: Date = proxy.value(atX: x1) else { return }
                                selected = nil
                                rangeSelection = min(d0, d1)...max(d0, d1)
                            }
                            .onEnded { _ in finalizeRange() }
                    )
            }
        }
        .onChange(of: combined) { _, _ in
            selected = nil
            rangeSelection = nil
            rangeAnalysis = nil
        }
    }

    /// Analyze the finished drag over the real (raw hPa) series in range.
    private func finalizeRange() {
        guard let r = rangeSelection else { return }
        let obsEnd = observed.last?.t ?? .distantPast
        let pts = (observed + forecast.filter { $0.t > obsEnd })
            .filter { r.contains($0.t) }
            .map { ($0.t, $0.raw) }
        guard pts.count >= 2,
              let analysis = RangeAnalysis.analyze(points: pts, forecastStartsAt: now)
        else {
            rangeSelection = nil
            rangeAnalysis = nil
            return
        }
        rangeAnalysis = analysis
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
        if let a = rangeAnalysis {
            analysisCard(a)
        } else if let sel = selected {
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

    /// The drag-selection analysis card: what this stretch of the curve means,
    /// in plain language, with the numbers underneath.
    private func analysisCard(_ a: RangeAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(a.title)
                    .font(.subheadline.weight(.semibold))
                Text("\(a.start.formatted(date: .omitted, time: .shortened)) – \(a.end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    rangeSelection = nil
                    rangeAnalysis = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear selection")
            }
            Text(a.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Text("Net \(unit.formatDelta(a.netHPa))")
                Text("Swing \(String(format: unit == .hPa ? "%.1f" : "%.2f", unit.convertDelta(a.spreadHPa))) \(unit.label)")
                Text("Steepest \(unit.formatDelta(a.steepest3hHPa))/3h")
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            if a.includesForecast {
                Text("Part of this window is forecast, not observation.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Compact key for the line coloring: a blue ramp where deeper blue = a faster
    /// change (steeper rise or fall). Doubles as the tap-to-read hint.
    private var slopeLegend: some View {
        HStack(spacing: 10) {
            legendSwatch(colors: [TendencyClass.blueRamp(0.0), TendencyClass.blueRamp(1.0)],
                         label: "deeper = faster change")
            if !visiblePhone.isEmpty {
                legendSwatch(colors: [.orange, .orange], label: "local")
            }
            Spacer()
            Text("tap or drag to read")
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
