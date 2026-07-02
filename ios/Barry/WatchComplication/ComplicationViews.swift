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
    private var unitRaw: String = PressureUnit.inHg.rawValue
    let entry: TendencyEntry

    private var unit: PressureUnit { PressureUnit(rawValue: unitRaw) ?? .inHg }
    private var cls: TendencyClass { entry.snapshot?.cls ?? .steady }
    private var intensity: Double { entry.snapshot?.intensity ?? 0 }
    private var delta: Double { entry.snapshot?.delta3h ?? 0 }
    private var currentHPa: Double? { entry.snapshot?.currentPressureHPa }
    private var feature: String? { entry.snapshot?.feature }

    /// Data too old to present as current — the trend word becomes "STALE" and the
    /// trend color drops to gray, so old data never masquerades as live.
    private var isStale: Bool { entry.snapshot?.isStale(asOf: entry.date) ?? false }

    private var tint: Color { isStale ? .gray : cls.color(intensity: intensity) }

    /// Tinted/mono-aware tint: the real trend color only in full-color rendering.
    /// In the system's accented/vibrant modes we defer to `.primary` (paired with
    /// `.widgetAccentable()`) so the watch face's own tint drives the look — which
    /// is what makes it read like a regular Apple complication everywhere.
    private var accentTint: Color {
        renderingMode == .fullColor ? tint : .primary
    }

    /// Forecast-aware glyph — shared mapping (TendencySnapshot.trendSymbolName) so
    /// the watch complication and the iPhone widget can never drift apart.
    private var trendSymbol: String {
        entry.snapshot?.trendSymbolName ?? cls.symbolName
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

    // Corner: native curved-text style (like aviation METAR complications) — the
    // outer bezel arc carries the short trend descriptor (curved content, takes the
    // face's accent tint), and the inner arc — nearest the dial — carries the
    // pressure reading as the widgetLabel, which the system renders in white type.
    private var corner: some View {
        Text(trendDescriptor)
            .font(.system(size: 14, weight: .bold))
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .foregroundStyle(accentTint)
            .widgetCurvesContent()
            .widgetLabel {
                Text("\(pressureShort) \(unit.label)")
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
            }
            .widgetAccentable()
    }

    /// Short, uppercase trend descriptor for the corner's outer arc — sized to fit
    /// a curved bezel label (matches the aviation-style all-caps look). Reads
    /// "STALE" when the snapshot is too old to present as the current trend.
    private var trendDescriptor: String {
        if isStale { return "STALE" }
        switch cls {
        case .risingFast:  return "RISING FAST"
        case .rising:      return "RISING"
        case .steady:      return "STEADY"
        case .falling:     return "FALLING"
        case .fallingMod:  return "FALLING"
        case .fallingFast: return "FALLING FAST"
        }
    }

    // Inline: single line that sits next to the time — mirrors the corner so the
    // top and bottom slots read consistently.
    private var inline: some View {
        Label(isStale ? "\(pressureShort) \(unit.label) · Stale"
                      : "\(pressureShort) \(unit.label)",
              systemImage: trendSymbol)
    }

    // Rectangular: the richest tiny surface — glyph, delta, and class label.
    private var rectangular: some View {
        HStack(spacing: 8) {
            Image(systemName: trendSymbol)
                .font(.title3.weight(.bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(isStale ? "Stale" : cls.label)
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
