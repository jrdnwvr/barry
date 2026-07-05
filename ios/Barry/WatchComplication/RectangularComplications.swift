//  RectangularComplications.swift
//  Barry — Watch Complication
//
//  Two selectable large-middle (accessoryRectangular, e.g. Modular face) styles:
//
//  Graph — the thesis in pixels: pressure + 3h delta on the left, the last ~12 h
//  drawn as a slope-colored sparkline on the right, with a dashed tail slanted by
//  the model's expected next-3h change and an orange dot at now.
//
//  METAR — aviation rows in mono: station + flight category + pressure, the trend
//  word + delta, then wind/visibility/ceiling in raw METAR notation (16011G18KT
//  10SM BKN045). Reads like a sibling of a real METAR complication.

import WidgetKit
import SwiftUI
import Charts

// MARK: - Graph

struct BarryGraphComplication: Widget {
    let kind = "BarryGraph"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TendencyProvider()) { entry in
            GraphComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Graph")
        .description("Pressure now and the last 12 hours drawn as a line.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct GraphComplicationView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var unitRaw: String = PressureUnit.inHg.rawValue
    let entry: TendencyEntry

    private var unit: PressureUnit { PressureUnit(rawValue: unitRaw) ?? .inHg }
    private var snap: TendencySnapshot? { entry.snapshot }
    private var cls: TendencyClass { snap?.cls ?? .steady }
    private var isStale: Bool { snap?.isStale(asOf: entry.date) ?? false }

    private var tint: Color {
        guard !isStale else { return .gray }
        guard renderingMode == .fullColor else { return .primary }
        return cls.color(intensity: max(0.35, snap?.intensity ?? 0))
    }

    private var pressureShort: String {
        guard let hPa = snap?.currentPressureHPa else { return "—" }
        return String(format: unit == .hPa ? "%.0f" : "%.2f", unit.convert(hPa))
    }

    private var deltaShort: String {
        let d = snap?.delta3h ?? 0
        let sign = d > 0 ? "+" : (d < 0 ? "−" : "")
        return "\(sign)\(String(format: "%.1f", abs(d)))"
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(pressureShort)
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                    Text(unit.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    Image(systemName: snap?.trendSymbolName ?? cls.symbolName)
                        .font(.system(size: 10, weight: .bold))
                    Text(isStale ? "Stale" : "\(deltaShort) · 3h")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                .foregroundStyle(tint)
                .widgetAccentable()
            }
            sparkline
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var sparkline: some View {
        let pts = snap?.spark ?? []
        if pts.count >= 2 {
            Chart {
                ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                    LineMark(x: .value("t", pt.t), y: .value("p", pt.p),
                             series: .value("s", "obs"))
                }
                .foregroundStyle(lineStyle(for: pts))
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .interpolationMethod(.catmullRom)

                // Expected next ~2h, slanted by the model's next-3h change —
                // dashed because it's forecast, per the app-wide convention.
                if let last = pts.last, let exp = snap?.expectedDelta3h {
                    let tailT = last.t.addingTimeInterval(2 * 3600)
                    let tailP = last.p + exp * (2.0 / 3.0)
                    LineMark(x: .value("t", last.t), y: .value("p", last.p),
                             series: .value("s", "tail"))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    LineMark(x: .value("t", tailT), y: .value("p", tailP),
                             series: .value("s", "tail"))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                }

                if let last = pts.last {
                    PointMark(x: .value("t", last.t), y: .value("p", last.p))
                        .foregroundStyle(isStale ? Color.gray : Color.orange)
                        .symbolSize(28)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .widgetAccentable()
        } else {
            Text("Open Barry once to load data.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// Slope-colored gradient in full color (same shared logic as the app chart);
    /// plain primary in the face's tinted/vibrant modes.
    private func lineStyle(for pts: [SparkPoint]) -> AnyShapeStyle {
        guard renderingMode == .fullColor, !isStale,
              let first = pts.first?.t, let last = pts.last?.t, last > first
        else { return AnyShapeStyle(.primary) }
        let span = last.timeIntervalSince(first)
        let times = pts.map(\.t)
        let values = pts.map(\.p)
        let stops = pts.enumerated().map { i, pt in
            Gradient.Stop(
                color: TendencyClass.slopeColor(
                    hPaPerHour: PressureSlope.windowed(times: times, values: values, at: i)),
                location: min(1.0, max(0.0, pt.t.timeIntervalSince(first) / span)))
        }
        return AnyShapeStyle(LinearGradient(stops: stops,
                                            startPoint: .leading, endPoint: .trailing))
    }
}

// MARK: - METAR

struct BarryMetarComplication: Widget {
    let kind = "BarryMETAR"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TendencyProvider()) { entry in
            MetarComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("METAR")
        .description("Station, flight category, pressure trend, wind, visibility, and ceiling.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct MetarComplicationView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @AppStorage("pressureUnit", store: AppConfig.sharedDefaults)
    private var unitRaw: String = PressureUnit.inHg.rawValue
    let entry: TendencyEntry

    private var unit: PressureUnit { PressureUnit(rawValue: unitRaw) ?? .inHg }
    private var snap: TendencySnapshot? { entry.snapshot }
    private var cls: TendencyClass { snap?.cls ?? .steady }
    private var isStale: Bool { snap?.isStale(asOf: entry.date) ?? false }
    private var fullColor: Bool { renderingMode == .fullColor }

    private var trendTint: Color {
        guard !isStale else { return .gray }
        guard fullColor else { return .primary }
        return cls.color(intensity: max(0.35, snap?.intensity ?? 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(snap?.station ?? "----")
                    .foregroundStyle(.secondary)
                if let cat = snap?.fltCat {
                    Text(cat)
                        .fontWeight(.bold)
                        .foregroundStyle(fullColor && !isStale ? fltCatColor(cat) : .primary)
                        .widgetAccentable()
                }
                Spacer(minLength: 0)
                Text(pressureText)
                    .fontWeight(.semibold)
            }
            .font(.system(size: 12, design: .monospaced))

            HStack(spacing: 5) {
                Text(isStale ? "STALE" : trendWord)
                    .fontWeight(.bold)
                    .foregroundStyle(trendTint)
                    .widgetAccentable()
                Spacer(minLength: 0)
                Text("\(deltaShort)/3h")
                    .foregroundStyle(.primary)
            }
            .font(.system(size: 13, design: .monospaced))

            Text(conditionsLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
    }

    // MARK: strings

    private var pressureText: String {
        guard let hPa = snap?.currentPressureHPa else { return "—" }
        let v = String(format: unit == .hPa ? "%.0f" : "%.2f", unit.convert(hPa))
        return "\(v)\(unit.label)"
    }

    private var deltaShort: String {
        let d = snap?.delta3h ?? 0
        let sign = d > 0 ? "+" : (d < 0 ? "−" : "")
        return "\(sign)\(String(format: "%.1f", abs(d)))"
    }

    private var trendWord: String {
        switch cls {
        case .risingFast:  return "RISING FAST"
        case .rising:      return "RISING"
        case .steady:      return "STEADY"
        case .falling:     return "FALLING"
        case .fallingMod:  return "FALLING"
        case .fallingFast: return "FALLING FAST"
        }
    }

    /// "16011G18KT 10SM BKN045" — wind, visibility, ceiling in METAR notation.
    private var conditionsLine: String {
        var parts: [String] = []
        if let w = windMetar { parts.append(w) }
        if let v = snap?.visibilitySM {
            let vs = v >= 10 ? "10SM"
                : (v == v.rounded() ? "\(Int(v))SM" : String(format: "%.1fSM", v))
            parts.append(vs)
        }
        if let ft = snap?.ceilingFt {
            parts.append("\(snap?.ceilingCover ?? "CIG")\(String(format: "%03d", ft / 100))")
        } else if let cover = snap?.ceilingCover {
            parts.append(cover)
        }
        return parts.isEmpty ? "NO CONDITIONS DATA" : parts.joined(separator: " ")
    }

    private var windMetar: String? {
        guard let kmh = snap?.windKmh else { return nil }
        let kt = Int((kmh / 1.852).rounded())
        if kt == 0 { return "00000KT" }
        let dir = snap?.windDirDeg.map { String(format: "%03d", Int($0.rounded()) == 0 ? 360 : Int($0.rounded())) } ?? "VRB"
        var s = dir + String(format: "%02d", kt)
        if let gustKmh = snap?.windGustKmh {
            s += "G\(Int((gustKmh / 1.852).rounded()))"
        }
        return s + "KT"
    }

    /// Standard aviation flight-category colors.
    private func fltCatColor(_ cat: String) -> Color {
        switch cat {
        case "VFR":  return Color(red: 0.20, green: 0.78, blue: 0.35)
        case "MVFR": return Color(red: 0.25, green: 0.56, blue: 0.93)
        case "IFR":  return Color(red: 0.92, green: 0.26, blue: 0.21)
        case "LIFR": return Color(red: 0.79, green: 0.24, blue: 0.76)
        default:     return .secondary
        }
    }
}

// MARK: - Previews

#Preview("Graph", as: .accessoryRectangular) {
    BarryGraphComplication()
} timeline: {
    TendencyEntry.placeholder
}

#Preview("METAR", as: .accessoryRectangular) {
    BarryMetarComplication()
} timeline: {
    TendencyEntry.placeholder
}
