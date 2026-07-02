//  ComplicationDial.swift
//  Barry — Watch Complication
//
//  A second, separately-selectable complication: a circular Gauge dial. The center
//  reads the current pressure; the indicator's position around the arc is driven by
//  the *expected* pressure change over the next 3 hours (falling at the bottom-left
//  ↓ end, rising at the bottom-right ↑ end), so the angle conveys "what's coming".
//  Tinted/mono-aware like the corner complication.

import WidgetKit
import SwiftUI

struct DialComplicationView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var unitRaw: String = PressureUnit.inHg.rawValue
    let entry: TendencyEntry

    /// Full-scale change (hPa/3h) at which the gauge pegs to an end.
    private let scale = 4.0

    private var unit: PressureUnit { PressureUnit(rawValue: unitRaw) ?? .inHg }
    private var snap: TendencySnapshot? { entry.snapshot }

    /// Expected next-3h change drives the gauge position + color. Falls back to the
    /// observed 3-hour change when the snapshot has no forecast.
    private var change: Double { snap?.expectedDelta3h ?? snap?.delta3h ?? 0 }
    private var clamped: Double { max(-scale, min(scale, change)) }

    private var changeClass: TendencyClass { TendencyClass.classify(delta3h: change) }
    private var changeIntensity: Double { TendencyIntensity.intensity(delta3h: change) }

    /// Data too old to present as current (matches ComplicationView.isStale).
    private var isStale: Bool { snap?.isStale(asOf: entry.date) ?? false }

    /// Real trend color in full color (gray when stale); defer to the face tint in
    /// accented/vibrant.
    private var tint: Color {
        guard renderingMode == .fullColor else { return .primary }
        return isStale ? .gray : changeClass.color(intensity: changeIntensity)
    }

    private var pressureText: String {
        guard let hPa = snap?.currentPressureHPa else { return "—" }
        return String(format: unit == .hPa ? "%.0f" : "%.2f", unit.convert(hPa))
    }

    var body: some View {
        Gauge(value: clamped, in: -scale...scale) {
            Text(unit.label)
        } currentValueLabel: {
            Text(pressureText)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .widgetAccentable()
        } minimumValueLabel: {
            Image(systemName: "arrow.down")
        } maximumValueLabel: {
            Image(systemName: "arrow.up")
        }
        .gaugeStyle(.accessoryCircular)
        .tint(tint)
    }
}

#Preview("Dial", as: .accessoryCircular) {
    BarryDialComplication()
} timeline: {
    TendencyEntry.placeholder
}
