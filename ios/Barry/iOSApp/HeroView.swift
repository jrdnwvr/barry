//  HeroView.swift
//  Barry — iOS
//
//  The glance (replaces the old verdict header). One block answers "what's the
//  pressure doing here, right now, and is weather coming?":
//    • station + freshness (a live dot when the phone sensor is trusted, else the
//      METAR age)
//    • the current pressure — the live calibrated sensor value when trusted,
//      otherwise the METAR value
//    • the 3-hour trend chip + the live micro-trend since the last METAR
//    • the plain-language verdict (with an honesty note only when confidence is low)
//  Everything else (chart, wind/rain, sources) lives below.

import SwiftUI

struct HeroView: View {
    let combined: CombinedResponse
    let unit: PressureUnit
    @ObservedObject var barometer: BarometerManager
    let now: Date
    var barometerEnabled: Bool

    private var tendency: TendencyOut? { combined.tendency }

    /// The phone reading is only trusted when the feature is on, the device has a
    /// barometer, we're stationary, and we've calibrated against a METAR.
    private var liveSLP: Double? {
        guard barometerEnabled, barometer.isAvailable,
              case .stationary = barometer.motionState,
              barometer.isCalibrated else { return nil }
        return barometer.latestLocalSLP
    }

    private var displayValue: Double? { liveSLP ?? combined.currentPressure }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusRow(combined: combined, barometer: barometer, now: now,
                      barometerEnabled: barometerEnabled)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let v = displayValue {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(unit.format(v))
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(unit.label)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let t = tendency { TendencyBadge(tendency: t, unit: unit) }
            }

            // Live micro-trend — the between-METAR signal — shown only when the
            // sensor value is the trusted one.
            if liveSLP != nil, let trend = barometer.microTrend {
                Label(microLabel(trend), systemImage: "sensor.tag.radiowaves.forward")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(combined.verdict)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if let note = honestyNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func microLabel(_ t: MicroTrend) -> String {
        let arrow = t.deltaHPa > 0.1 ? "↑" : (t.deltaHPa < -0.1 ? "↓" : "→")
        let mag = String(format: unit == .hPa ? "%.1f" : "%.2f", abs(unit.convertDelta(t.deltaHPa)))
        return "sensor \(arrow) \(mag) \(unit.label) in last \(t.windowMinutes) min"
    }

    /// Surface non-obvious interpreter caveats (low confidence, sparse data) so the
    /// user knows when to trust the verdict less. `forecast_derived` is already baked
    /// into the verdict sentence's hedged wording.
    private var honestyNote: String? {
        guard let r = combined.reading else { return nil }
        var bits: [String] = []
        if r.caveats.contains("short_window") { bits.append("limited recent data") }
        if r.caveats.contains("sparse") { bits.append("data gaps") }
        if r.confidence < 0.5 && bits.isEmpty { bits.append("lower confidence than usual") }
        return bits.isEmpty ? nil : "Read with care — " + bits.joined(separator: ", ") + "."
    }
}

// MARK: - Status row (station + freshness)

private struct StatusRow: View {
    let combined: CombinedResponse
    @ObservedObject var barometer: BarometerManager
    let now: Date
    var barometerEnabled: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "airplane").font(.caption)
            Text(stationText)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            freshness
        }
    }

    private var stationText: String {
        let code = combined.pressure.station
        if let name = combined.pressure.name, !name.isEmpty { return "\(code) · \(name)" }
        return code
    }

    @ViewBuilder
    private var freshness: some View {
        if let status = sensorStatus {
            HStack(spacing: 5) {
                if status.live {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                }
                Text(status.text)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(status.live ? Color.green : Color.secondary)
            }
        } else {
            Text(metarAge)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Sensor status when the barometer feature is active + available; nil means
    /// fall back to METAR freshness.
    private var sensorStatus: (text: String, live: Bool)? {
        guard barometerEnabled, barometer.isAvailable else { return nil }
        switch barometer.motionState {
        case .stationary:
            return barometer.isCalibrated ? ("Live", true) : ("Calibrating…", false)
        case .settling:
            return ("Settling…", false)
        case .moving:
            return ("Paused", false)
        }
    }

    private var metarAge: String {
        let last = combined.observedSeries.last?.t ?? combined.pressure.cachedAt
        let mins = max(0, Int(now.timeIntervalSince(last) / 60))
        return mins < 60 ? "METAR \(mins)m ago" : "METAR \(mins / 60)h ago"
    }
}

// MARK: - Trend chip

struct TendencyBadge: View {
    let tendency: TendencyOut
    let unit: PressureUnit

    var body: some View {
        let color = tendency.cls.color(intensity: tendency.intensity)
        VStack(spacing: 2) {
            Image(systemName: tendency.cls.symbolName)
                .font(.title2.weight(.bold))
            Text(unit.formatDelta(tendency.delta3h))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            Text("3h")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}
