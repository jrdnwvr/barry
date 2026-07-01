//  SensorComparisonView.swift
//  Barry — iOS
//
//  "Sensor vs Station" overlay (brief Task 3). Plots the phone's calibrated, continuous
//  SLP trace (the persisted Task 2 history) against the discrete hourly METAR
//  observations on one shared pressure axis over several hours — so the phone's finer
//  resolution and any divergence from the reporting station are both visible.
//
//  Phone trace: continuous orange line (a point every few minutes, ~48h retained).
//  Station:     discrete blue dots, because METARs land roughly hourly.

import SwiftUI
import Charts

struct SensorComparisonView: View {
    let combined: CombinedResponse
    let now: Date
    let unit: PressureUnit
    /// Live barometer — supplies the calibrated SLP history and the on-demand reading.
    @ObservedObject var barometer: BarometerManager

    /// Calibrated phone SLP history, oldest → newest.
    private var history: [(Date, Double)] { barometer.phoneHistoryTrace }

    @State private var window: ComparisonWindow = .hours6
    @State private var measuring = false
    @State private var showMotionWarning = false
    @State private var lastResult: BarometerManager.ManualMeasurement?

    enum ComparisonWindow: String, CaseIterable, Identifiable {
        case hours3, hours6, hours12

        var id: String { rawValue }
        var label: String {
            switch self {
            case .hours3:  return "3h"
            case .hours6:  return "6h"
            case .hours12: return "12h"
            }
        }
        var hours: Double {
            switch self {
            case .hours3:  return 3
            case .hours6:  return 6
            case .hours12: return 12
            }
        }
        var axisStrideHours: Int {
            switch self {
            case .hours3:  return 1
            case .hours6:  return 2
            case .hours12: return 3
            }
        }
    }

    private struct Plot: Identifiable {
        let id = UUID()
        let t: Date
        let value: Double  // already converted to `unit`
    }

    private var lowerBound: Date { now.addingTimeInterval(-window.hours * 3600) }

    /// Phone continuous trace, clipped to the visible window.
    private var phonePlots: [Plot] {
        history
            .filter { $0.0 >= lowerBound && $0.0 <= now }
            .map { Plot(t: $0.0, value: unit.convert($0.1)) }
    }

    /// Discrete METAR observations, clipped to the visible window.
    private var metarPlots: [Plot] {
        combined.observedSeries
            .filter { $0.t >= lowerBound && $0.t <= now }
            .compactMap { p in p.pressure.map { Plot(t: p.t, value: unit.convert($0)) } }
    }

    /// Latest phone reading minus the nearest-in-time METAR observation — the live
    /// divergence the chart is making visible. nil unless both sides have data.
    private var divergenceHPa: Double? {
        guard let lastPhone = history.last,
              let nearestMetar = combined.observedSeries
                .min(by: { abs($0.t.timeIntervalSince(lastPhone.0)) < abs($1.t.timeIntervalSince(lastPhone.0)) }),
              let metarPressure = nearestMetar.pressure
        else { return nil }
        return lastPhone.1 - metarPressure
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sensor vs Station")
                    .font(.headline)
                Spacer()
                Picker("Window", selection: $window) {
                    ForEach(ComparisonWindow.allCases) { w in
                        Text(w.label).tag(w)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityLabel("Comparison time window")
            }

            // Render the chart whenever there's anything to show — station METARs
            // alone are useful; the placeholder is only for a truly empty window.
            if phonePlots.isEmpty && metarPlots.isEmpty {
                placeholder
            } else {
                chart
                legend
            }

            measureButton
        }
        .alert("You're moving", isPresented: $showMotionWarning) {
            Button("Measure anyway") { Task { await runMeasure() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Movement — walking, driving, elevators — changes pressure and can throw off a reading. Barry will log it on the chart but won't use it to calibrate.")
        }
    }

    // MARK: - Measure now

    private var measureButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: triggerMeasure) {
                HStack(spacing: 6) {
                    if measuring {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "dot.scope")
                    }
                    Text(measuring ? "Measuring…" : "Measure now")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(measuring)

            if let r = lastResult {
                Text(resultMessage(r))
                    .font(.caption2)
                    .foregroundStyle(r.hadMotion || r.slp == nil ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func triggerMeasure() {
        // Motion detected → warn but still let them proceed.
        if barometer.isStationaryNow {
            Task { await runMeasure() }
        } else {
            showMotionWarning = true
        }
    }

    private func runMeasure() async {
        measuring = true
        lastResult = await barometer.measureNow(stationSLP: combined.currentPressure)
        measuring = false
    }

    private func resultMessage(_ r: BarometerManager.ManualMeasurement) -> String {
        if r.rawHPa == nil {
            return "Couldn't get a sensor reading — this needs a real device (not the simulator), held still for a moment."
        }
        guard let slp = r.slp else {
            return "Measured, but Barry couldn't calibrate to the station yet — hold the phone still for a moment and try again."
        }
        let shown = String(format: unit == .hPa ? "%.0f" : "%.2f", unit.convert(slp))
        if r.hadMotion {
            return "Logged \(shown) \(unit.label) while moving — shown on the chart but excluded from calibration."
        }
        return "Logged \(shown) \(unit.label)."
    }

    // MARK: - Subviews

    private var chart: some View {
        Chart {
            // Station: discrete hourly observations as dots (+ a faint connecting line
            // so the hourly cadence reads as one series, not scattered points).
            ForEach(metarPlots) { p in
                LineMark(x: .value("Time", p.t), y: .value("Pressure", p.value),
                         series: .value("Series", "station"))
                    .foregroundStyle(.blue.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(metarPlots) { p in
                PointMark(x: .value("Time", p.t), y: .value("Pressure", p.value))
                    .foregroundStyle(.blue)
                    .symbolSize(36)
            }

            // Phone: the continuous, finely-resolved calibrated trace.
            ForEach(phonePlots) { p in
                LineMark(x: .value("Time", p.t), y: .value("Pressure", p.value),
                         series: .value("Series", "phone"))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: lowerBound...now)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: window.axisStrideHours)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxisLabel(unit.label)
        .frame(height: 200)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            if !phonePlots.isEmpty {
                Label {
                    Text("Phone (continuous)").font(.caption2).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "line.diagonal").foregroundStyle(.orange)
                }
            }
            Label {
                Text("Station METAR (hourly)").font(.caption2).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.blue)
            }
            Spacer()
            if let d = divergenceHPa {
                Text("Δ \(unit.formatDelta(d))")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Phone differs from station by \(unit.formatDelta(d))")
            }
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No phone readings yet")
                .font(.subheadline.weight(.medium))
            Text("Once the phone barometer is calibrated and the device is still, Barry logs its own pressure here to compare against the station.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
    }

    private var yDomain: ClosedRange<Double> {
        let values = (phonePlots + metarPlots).map(\.value)
        guard let lo = values.min(), let hi = values.max(), lo < hi else {
            // Single flat value (or none): pad a degenerate range so the line is visible.
            let v = values.first ?? unit.convert(1013)
            let pad = unit == .hPa ? 1.0 : 0.03
            return (v - pad)...(v + pad)
        }
        let pad = max((hi - lo) * 0.15, unit == .hPa ? 0.5 : 0.02)
        return (lo - pad)...(hi + pad)
    }
}
