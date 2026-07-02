//  ConfirmationOverlayView.swift
//  Barry — iOS
//
//  Wind + precip confirmation (brief §4.2, §6). A pressure fall confirmed by rising
//  wind and climbing precip probability is the real frontal-passage tell. Two separate
//  mini-charts with correct individual scales so neither channel is misread.

import SwiftUI
import Charts

struct ConfirmationOverlayView: View {
    let combined: CombinedResponse
    let now: Date

    @AppStorage("windUnit", store: AppConfig.sharedDefaults)
    private var windUnitRaw: String = WindUnit.mph.rawValue
    private var windUnit: WindUnit { WindUnit(rawValue: windUnitRaw) ?? .mph }

    private var hours: [ForecastHour] {
        (combined.forecast?.hourly ?? [])
            .filter { $0.t >= now }
            .prefix(24)
            .map { $0 }
    }

    private var precipHours: [ForecastHour] { hours.filter { $0.precip_prob != nil } }
    private var windHours: [ForecastHour] { hours.filter { $0.windspeed != nil } }

    // Only surface the panel when at least one channel has something to show.
    private var hasMeaningfulPrecip: Bool { precipHours.contains { ($0.precip_prob ?? 0) > 5 } }
    private var hasMeaningfulWind: Bool { windHours.contains { ($0.windspeed ?? 0) > 2 } }

    // --- collapsed summary (next 6h) ------------------------------------------
    private var next6h: [ForecastHour] {
        hours.filter { $0.t <= now.addingTimeInterval(6 * 3600) }
    }
    private var precipMaxPct: Int { next6h.compactMap { $0.precip_prob }.max() ?? 0 }
    private var windNowKmh: Double { (next6h.first ?? hours.first)?.windspeed ?? 0 }
    /// Wind direction (degrees the wind blows *from*: 0 = N, 90 = E), if reported.
    private var windDirNow: Double? { (next6h.first ?? hours.first)?.winddir }

    /// "12 km/h · 230°" — speed plus the from-direction in degrees when available.
    private var windText: String {
        var s = "\(windUnit.format(windNowKmh)) \(windUnit.label)"
        if let dir = windDirNow {
            s += " · \(Int(dir.rounded()))°"
        }
        return s
    }

    /// The forecast hour the user last tapped on the wind chart.
    private struct WindSelection: Equatable {
        let date: Date
        let speedKmh: Double
        let dir: Double?
    }
    @State private var windSelection: WindSelection?

    var body: some View {
        if hours.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                summaryRow

                if hasMeaningfulPrecip { precipChart }
                if hasMeaningfulWind { windChart }
                if !hasMeaningfulPrecip && !hasMeaningfulWind {
                    Text("Calm and dry through the forecast window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // Fresh forecast → any tapped point may no longer exist; clear it.
            .onChange(of: combined) { _, _ in windSelection = nil }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 16) {
            Label("\(precipMaxPct)%", systemImage: "cloud.rain")
            Label(windText, systemImage: "wind")
            Text("next 6h").foregroundStyle(.secondary)
            Spacer()
        }
        .font(.subheadline)
    }

    // MARK: - Precip chart (0–100 %)

    private var precipChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Precip probability", systemImage: "cloud.rain")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Chart {
                ForEach(precipHours) { h in
                    BarMark(
                        x: .value("Time", h.t, unit: .hour),
                        y: .value("Precip %", h.precip_prob ?? 0)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue.opacity(0.65), .blue.opacity(0.25)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .frame(height: 56)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { v in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                    AxisValueLabel {
                        if let pct = v.as(Int.self) {
                            Text("\(pct)%").font(.system(size: 9))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) {
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                    AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9))
                }
            }
        }
    }

    // MARK: - Wind chart (km/h + direction arrows)

    // Every 4th hourly point, offset by 2, so arrows land mid-quadrant of each 6h block.
    private var sparseWindHours: [ForecastHour] {
        windHours.enumerated().compactMap { i, h in i % 4 == 2 ? h : nil }
    }

    private var windChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Wind (\(windUnit.label))", systemImage: "wind")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Chart {
                ForEach(windHours) { h in
                    if let w = h.windspeed {
                        AreaMark(
                            x: .value("Time", h.t),
                            yStart: .value("Base", 0),
                            yEnd: .value("Wind", windUnit.convert(w))
                        )
                        .foregroundStyle(.teal.opacity(0.12))
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Time", h.t),
                            y: .value("Wind", windUnit.convert(w))
                        )
                        .foregroundStyle(.teal)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.catmullRom)
                    }
                }

                // Direction arrows at sparse intervals — winddir is "from" degrees
                // (0 = N, 90 = E) so rotating arrow.up by winddir degrees points
                // the arrow back toward the wind's source (standard vane convention).
                // The >4 km/h gate stays on the raw value so the threshold is stable
                // regardless of display unit.
                ForEach(sparseWindHours) { h in
                    if let w = h.windspeed, let dir = h.winddir, w > 4 {
                        PointMark(
                            x: .value("Time", h.t),
                            y: .value("Wind", windUnit.convert(w))
                        )
                        .foregroundStyle(.clear)
                        .annotation(position: .overlay) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.teal.opacity(0.85))
                                .rotationEffect(.degrees(dir))
                        }
                    }
                }

                // Tap-to-read selection — same pattern as the pressure chart.
                if let sel = windSelection {
                    RuleMark(x: .value("Selected", sel.date))
                        .foregroundStyle(.primary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("Selected", sel.date),
                              y: .value("Wind", windUnit.convert(sel.speedKmh)))
                        .foregroundStyle(.teal)
                        .symbolSize(60)
                }
            }
            .frame(height: 56)
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                    AxisValueLabel().font(.system(size: 9))
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) {
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                    AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture().onEnded { value in
                                selectWind(at: value.location, proxy: proxy, geo: geo)
                            }
                        )
                }
            }

            if let sel = windSelection {
                windReadout(sel)
            }
        }
    }

    private func selectWind(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let xInPlot = location.x - geo[plotFrame].origin.x
        guard let date: Date = proxy.value(atX: xInPlot),
              let nearest = windHours.min(by: {
                  abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date))
              }),
              let speed = nearest.windspeed
        else { return }
        windSelection = WindSelection(date: nearest.t, speedKmh: speed, dir: nearest.winddir)
    }

    private func windReadout(_ sel: WindSelection) -> some View {
        HStack(spacing: 8) {
            Circle().fill(.teal).frame(width: 8, height: 8)
            Text(sel.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                .font(.caption).foregroundStyle(.secondary)
            Text("\(windUnit.format(sel.speedKmh)) \(windUnit.label)")
                .font(.caption.weight(.semibold)).monospacedDigit()
            if let dir = sel.dir {
                Text("\(Int(dir.rounded()))°")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text("forecast")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button { windSelection = nil } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Clear selection")
        }
    }
}
