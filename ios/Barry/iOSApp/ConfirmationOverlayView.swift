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

    @State private var expanded = false

    @AppStorage("windUnit", store: AppConfig.sharedDefaults)
    private var windUnitRaw: String = WindUnit.kmh.rawValue
    private var windUnit: WindUnit { WindUnit(rawValue: windUnitRaw) ?? .kmh }

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

    var body: some View {
        if hours.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(.snappy(duration: 0.22)) { expanded.toggle() }
                } label: {
                    summaryRow
                }
                .buttonStyle(.plain)

                if expanded {
                    if hasMeaningfulPrecip { precipChart }
                    if hasMeaningfulWind { windChart }
                    if !hasMeaningfulPrecip && !hasMeaningfulWind {
                        Text("Calm and dry through the forecast window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var summaryRow: some View {
        HStack(spacing: 16) {
            Label("\(precipMaxPct)%", systemImage: "cloud.rain")
            Label("\(windUnit.format(windNowKmh)) \(windUnit.label)", systemImage: "wind")
            Text("next 6h").foregroundStyle(.secondary)
            Spacer()
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
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
        }
    }
}
