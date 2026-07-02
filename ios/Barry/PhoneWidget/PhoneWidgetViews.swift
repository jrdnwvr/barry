//  PhoneWidgetViews.swift
//  Barry — iPhone Widget
//
//  Per-family rendering, mirroring the watch complication's language: forecast-aware
//  trend glyph, color depth by tendency intensity, and honest staleness (the trend
//  word reads "Stale" past 2 h instead of impersonating a live reading).

import WidgetKit
import SwiftUI

struct PhoneWidgetView: View {
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
    private var trendSymbol: String { entry.snapshot?.trendSymbolName ?? cls.symbolName }

    /// Data too old to present as current (same rule as the watch complication).
    private var isStale: Bool { entry.snapshot?.isStale(asOf: entry.date) ?? false }

    private var tint: Color { isStale ? .gray : cls.color(intensity: intensity) }
    /// Real trend color only in full-color rendering; the lock screen's vibrant /
    /// accented modes get .primary so the system's material does the styling.
    private var accentTint: Color { renderingMode == .fullColor ? tint : .primary }

    private var pressureShort: String {
        guard let hPa = currentHPa else { return "—" }
        return String(format: unit == .hPa ? "%.0f" : "%.2f", unit.convert(hPa))
    }

    private var deltaShort: String {
        let sign = delta > 0 ? "+" : (delta < 0 ? "−" : "")
        return "\(sign)\(String(format: "%.1f", abs(delta)))"
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:    circular
            case .accessoryInline:      inline
            case .accessoryRectangular: rectangular
            default:                    small
            }
        }
        .containerBackground(for: .widget) {
            if family == .systemSmall { Color(.systemBackground) } else { Color.clear }
        }
    }

    // Lock screen circular: intensity ring, trend glyph + pressure in the middle.
    private var circular: some View {
        Gauge(value: cls.isFalling && !isStale ? intensity : 0) {
            Image(systemName: trendSymbol)
        } currentValueLabel: {
            VStack(spacing: -1) {
                Image(systemName: trendSymbol)
                    .font(.system(size: 13, weight: .bold))
                Text(pressureShort)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(accentTint)
        .widgetAccentable()
    }

    // Lock screen inline: one line next to the date.
    private var inline: some View {
        Label(isStale ? "\(pressureShort) \(unit.label) · Stale"
                      : "\(pressureShort) \(unit.label)",
              systemImage: trendSymbol)
    }

    // Lock screen rectangular: glyph + trend word + pressure/delta.
    private var rectangular: some View {
        HStack(spacing: 8) {
            Image(systemName: trendSymbol)
                .font(.title3.weight(.bold))
                .foregroundStyle(accentTint)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                Text(isStale ? "Stale" : cls.label)
                    .font(.caption.weight(.semibold))
                Text("\(pressureShort) \(unit.label) · \(deltaShort) 3h")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // Home screen small: the full glance — pressure, trend, verdict.
    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: trendSymbol)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(tint)
                Spacer()
                Text(entry.snapshot?.station ?? "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(pressureShort)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                Text(unit.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(isStale ? "Stale — open Barry to refresh"
                         : "\(deltaShort) \(unit.label) · 3h")
                .font(.caption2).monospacedDigit()
                .foregroundStyle(isStale ? .orange : .secondary)
            Spacer(minLength: 0)
            Text(entry.snapshot?.verdict ?? "Open Barry to load your station.")
                .font(.caption2)
                .lineLimit(3)
                .foregroundStyle(.secondary)
        }
    }
}
