//  ComplicationViews.swift
//  Barry — Watch Complication
//
//  Per-family rendering. The shared idea (brief §4.1): an arrow glyph whose color
//  intensity scales with the magnitude of the 3-hour tendency — pale amber at
//  −1.5 hPa/3h through deep red at −4+; steady/rising are neutral/green.

import WidgetKit
import SwiftUI

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var unitRaw: String = PressureUnit.hPa.rawValue
    let entry: TendencyEntry

    private var unit: PressureUnit { PressureUnit(rawValue: unitRaw) ?? .hPa }
    private var cls: TendencyClass { entry.snapshot?.cls ?? .steady }
    private var intensity: Double { entry.snapshot?.intensity ?? 0 }
    private var delta: Double { entry.snapshot?.delta3h ?? 0 }
    private var currentHPa: Double? { entry.snapshot?.currentPressureHPa }
    private var feature: String? { entry.snapshot?.feature }
    private var tint: Color { cls.color(intensity: intensity) }

    /// Tinted/mono-aware tint: the real trend color only in full-color rendering.
    /// In the system's accented/vibrant modes we defer to `.primary` (paired with
    /// `.widgetAccentable()`) so the watch face's own tint drives the look — which
    /// is what makes it read like a regular Apple complication everywhere.
    private var accentTint: Color {
        renderingMode == .fullColor ? cls.color(intensity: intensity) : .primary
    }

    /// Forecast-aware glyph: when the interpreter's reading carries a feature
    /// it tells us what's *about* to happen (bottoming out, topping out, sharp
    /// fall just started), which is more useful than just "currently falling".
    /// Falls back to the trend-only icon when there's no clear feature.
    private var trendSymbol: String {
        switch feature {
        case "trough_passing":       return "arrow.up.from.line"     // at bottom, rising next
        case "post_trough_recovery": return "arrow.up.right"          // already rising off a low
        case "approaching_trough":   return "arrow.down.right"        // still falling toward a low
        case "ridge_peak":           return "arrow.down.from.line"    // at top, falling next
        case "rapid_fall":           return "arrow.down.to.line"      // sharp sustained drop
        case "front_knee":           return "bolt.horizontal.fill"    // sudden step change
        default:                     return cls.symbolName
        }
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryCorner:
            corner
        case .accessoryInline:
            inline
        case .accessoryRectangular:
            rectangular
        default:
            circular
        }
    }

    // Tiny: a gauge whose fill depth = falling intensity, with the arrow in center.
    private var circular: some View {
        Gauge(value: cls.isFalling ? intensity : 0) {
            Image(systemName: trendSymbol)
        } currentValueLabel: {
            Image(systemName: trendSymbol)
                .font(.system(size: 16, weight: .bold))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(tint)
    }

    // Corner: two bold lines of text in the inset — absolute pressure over the
    // signed 3-hour delta. No glyph, no bezel label; tinted/mono-aware so it reads
    // like a stock Apple corner complication on any face.
    private var corner: some View {
        VStack(spacing: -1) {
            Text("\(pressureShort) \(unit.label)")
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
            Text(deltaShort)
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
        }
        .minimumScaleFactor(0.6)
        .lineLimit(1)
        .foregroundStyle(accentTint)
        .widgetAccentable()
    }

    // Inline: single line that sits next to the time — mirrors the corner so the
    // top and bottom slots read consistently.
    private var inline: some View {
        Label("\(pressureShort) \(unit.label)", systemImage: trendSymbol)
    }

    // Rectangular: the richest tiny surface — glyph, delta, and class label.
    private var rectangular: some View {
        HStack(spacing: 8) {
            Image(systemName: trendSymbol)
                .font(.title3.weight(.bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(cls.label)
                    .font(.caption.weight(.semibold))
                Text("\(deltaShort) \(unit.label) · 3h")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var deltaShort: String {
        let sign = delta > 0 ? "+" : (delta < 0 ? "−" : "")
        return "\(sign)\(String(format: "%.1f", abs(delta)))"
    }

    /// Absolute pressure in the user's unit, no unit suffix — the surrounding
    /// label supplies that. Falls back to "—" if no snapshot yet.
    private var pressureShort: String {
        guard let hPa = currentHPa else { return "—" }
        let v = unit.convert(hPa)
        let digits = unit == .hPa ? 0 : 2
        return String(format: "%.\(digits)f", v)
    }
}

// MARK: - Previews

#Preview("Circular", as: .accessoryCircular) {
    BarryComplication()
} timeline: {
    TendencyEntry.placeholder
}

#Preview("Rectangular", as: .accessoryRectangular) {
    BarryComplication()
} timeline: {
    TendencyEntry.placeholder
}
