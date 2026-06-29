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

    private struct Plot: Identifiable {
        let id = UUID()
        let t: Date
        let value: Double      // already converted to `unit`
        let observed: Bool
    }

    private var observed: [Plot] {
        combined.observedSeries.compactMap { p in
            p.pressure.map { Plot(t: p.t, value: unit.convert($0), observed: true) }
        }
    }

    private var forecast: [Plot] {
        var pts = combined.forecastSeries(after: now).compactMap { h in
            h.pressure_msl.map { Plot(t: h.t, value: unit.convert($0), observed: false) }
        }
        // Bridge the gap so the dashed line visually connects to "now".
        if let last = observed.last {
            pts.insert(Plot(t: last.t, value: last.value, observed: false), at: 0)
        }
        return pts
    }

    private var phone: [Plot] {
        phoneTrace.map { Plot(t: $0.0, value: unit.convert($0.1), observed: true) }
    }

    // --- visible window: clip every series so the y-scale, markers, and axes all
    // reflect only what's on screen (otherwise 6h looks flat under a 72h y-range).
    private var domainBounds: (Date, Date) {
        (now.addingTimeInterval(-window.pastHours * 3600),
         now.addingTimeInterval(window.futureHours * 3600))
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

    var body: some View {
        Chart {
            ForEach(visibleObserved) { p in
                LineMark(x: .value("Time", p.t), y: .value("Pressure", p.value),
                         series: .value("Series", "observed"))
                    .foregroundStyle(.blue)
                    .interpolationMethod(.catmullRom)
            }
            ForEach(visibleForecast) { p in
                LineMark(x: .value("Time", p.t), y: .value("Pressure", p.value),
                         series: .value("Series", "forecast"))
                    .foregroundStyle(.blue.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    .interpolationMethod(.catmullRom)
            }

            RuleMark(x: .value("Now", now))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .annotation(position: .top, alignment: .center) {
                    Text("now").font(.caption2).foregroundStyle(.secondary)
                }

            if let lo = minPoint {
                PointMark(x: .value("Time", lo.t), y: .value("Pressure", lo.value))
                    .foregroundStyle(.orange)
                    .annotation(position: .bottom) { marker(lo.value) }
            }
            if let hi = maxPoint {
                PointMark(x: .value("Time", hi.t), y: .value("Pressure", hi.value))
                    .foregroundStyle(.green)
                    .annotation(position: .top) { marker(hi.value) }
            }

            // Phone barometer local trace (§4.5.5): short orange line over the last
            // ~60 min, shown only when calibrated + stationary. Clearly distinct
            // from the METAR blue line; annotated at its end with "local".
            if !visiblePhone.isEmpty {
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

            // Interpreter feature pin (§4.3): a dashed purple guide at the
            // detected/forecast feature time so the user can see where the
            // verdict's "trough at 6pm" actually lives on the curve.
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
        .chartYScale(domain: yDomain)
        .chartXScale(domain: domainBounds.0...domainBounds.1)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: window.axisStrideHours)) { value in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxisLabel(unit.label)
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
