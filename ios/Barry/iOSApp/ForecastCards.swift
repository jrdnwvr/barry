//  ForecastCards.swift
//  Barry — iOS
//
//  The short-term forecast card, in the style chosen in Settings:
//    Summary  a sentence on what changes, over four bands (rain, wind,
//             temperature, sky) with no axes; drag across to read an hour.
//    Changes  only the moments something changes, as a timeline.
//    Hourly   every hour for a day, side by side.
//    Chart    rain, wind and temperature on one chart (ConfirmationOverlayView).
//  All four are here for testing; the list will be cut after that.

import SwiftUI

enum ForecastCardStyle: String, CaseIterable, Identifiable {
    case summary, changes, hourly, chart
    static let key = "forecastCardStyle"
    /// The card people already have, until they pick another.
    static let fallback: ForecastCardStyle = .chart
    var id: String { rawValue }

    var label: String {
        switch self {
        case .summary: return "Summary"
        case .changes: return "Changes"
        case .hourly: return "Hourly"
        case .chart: return "Chart"
        }
    }

}

struct ShortTermForecastCard: View {
    let combined: CombinedResponse
    let now: Date
    @AppStorage(ForecastCardStyle.key, store: AppConfig.sharedDefaults)
    private var styleRaw: String = ForecastCardStyle.fallback.rawValue

    var body: some View {
        switch ForecastCardStyle(rawValue: styleRaw) ?? .fallback {
        case .summary: SummaryForecastCard(combined: combined, now: now)
        case .changes: ChangesForecastCard(combined: combined, now: now)
        case .hourly: HourlyForecastCard(combined: combined, now: now)
        case .chart: ConfirmationOverlayView(combined: combined, now: now)
        }
    }
}

// MARK: - Shared pieces

enum ForecastPalette {
    static let rain = Color(red: 0.18, green: 0.48, blue: 0.88)
    static let wind = Color(red: 0.22, green: 0.69, blue: 0.88)
    static let windDeep = Color(red: 0.08, green: 0.42, blue: 0.60)
    static let temp = Color(red: 0.87, green: 0.22, blue: 0.20)
    static let sky = Color(red: 0.43, green: 0.47, blue: 0.55)
    static let front = Color(red: 0.72, green: 0.40, blue: 0.05)

    /// A fixed scale, so 10 °C is the same colour every day: blue through
    /// teal and green to amber and red.
    static func temperature(_ c: Double) -> Color {
        let stops: [(Double, Double)] = [(-1, 215), (10, 195), (18, 130), (27, 45), (35, 10)]
        var hue = stops[0].1
        if c >= stops[stops.count - 1].0 { hue = stops[stops.count - 1].1 }
        else if c > stops[0].0 {
            for (a, b) in zip(stops, stops.dropFirst()) where c >= a.0 && c <= b.0 {
                hue = a.1 + (b.1 - a.1) * (c - a.0) / (b.0 - a.0)
                break
            }
        }
        return Color(hue: hue / 360, saturation: 0.50, brightness: 0.72)
    }
}

private struct ForecastCardChrome<Content: View>: View {
    let title: String
    let range: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(range).font(.caption).foregroundStyle(.secondary)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private func rangeText(_ m: ShortTermForecast) -> String {
    guard let a = m.hours.first?.t, let b = m.hours.last?.t else { return "" }
    return "\(ShortTermForecast.clock(a)) to \(ShortTermForecast.clock(b))"
}

/// A drag that only takes sideways movement, so the page still scrolls.
private struct SidewaysDrag: ViewModifier {
    let onChanged: (CGPoint) -> Void
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(HorizontalDragGesture(onChanged: { _, p in onChanged(p) }, onEnded: {}))
        } else {
            content.gesture(DragGesture(minimumDistance: 12).onChanged { g in onChanged(g.location) })
        }
    }
}

// MARK: - Summary: a sentence over four bands

struct SummaryForecastCard: View {
    let combined: CombinedResponse
    let now: Date
    @AppStorage("windUnit", store: AppConfig.sharedDefaults) private var windUnitRaw: String = WindUnit.mph.rawValue
    @AppStorage(TemperatureUnit.key, store: AppConfig.sharedDefaults) private var tempUnitRaw: String = TemperatureUnit.celsius.rawValue
    @State private var picked: Int?

    private var wind: WindUnit { WindUnit(rawValue: windUnitRaw) ?? .mph }
    private var temp: TemperatureUnit { TemperatureUnit(rawValue: tempUnitRaw) ?? .celsius }

    var body: some View {
        let m = ShortTermForecast(forecast: combined.forecast?.hourly ?? [], now: now)
        if m.isEmpty {
            EmptyView()
        } else {
            ForecastCardChrome(title: "Next 12 hours", range: rangeText(m)) {
                Text(m.sentence(wind: wind, temp: temp))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                ForecastRibbons(model: m, wind: wind, temp: temp, picked: $picked)
                HStack(spacing: 8) {
                    if let i = picked, m.hours.indices.contains(i) {
                        Text(ShortTermForecast.clock(m.hours[i].t)).foregroundStyle(.secondary)
                        Text(m.readout(i, wind: wind, temp: temp)).fontWeight(.semibold).monospacedDigit()
                        Spacer()
                        Button { picked = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Clear the hour")
                    } else {
                        Text("Drag across to read an hour").foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .onChange(of: combined) { _, _ in picked = nil }
        }
    }
}

/// Rain, wind, temperature and sky as bands of colour in time. Position is
/// the hour, depth is the amount; numbers sit only where they say something.
struct ForecastRibbons: View {
    let model: ShortTermForecast
    let wind: WindUnit
    let temp: TemperatureUnit
    @Binding var picked: Int?

    static let rowH: CGFloat = 22
    static let gap: CGFloat = 6
    static let labelW: CGFloat = 44
    static let axisH: CGFloat = 18
    static var height: CGFloat { 4 * (rowH + gap) - gap + 6 + axisH }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let cw = (w - Self.labelW) / CGFloat(max(1, model.hours.count))
            Canvas { ctx, _ in draw(&ctx, width: w, cw: cw) }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { v in
                    let i = index(at: v.location.x, cw: cw)
                    picked = (i == nil || picked == i) ? nil : i
                })
                .modifier(SidewaysDrag { p in if let i = index(at: p.x, cw: cw) { picked = i } })
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityLabel(model.sentence(wind: wind, temp: temp))
        .accessibilityAdjustableAction { dir in
            let i = picked ?? 0
            picked = dir == .increment ? min(model.hours.count - 1, i + 1) : max(0, i - 1)
        }
        .accessibilityValue(picked.map { "\(ShortTermForecast.clock(model.hours[$0].t)), \(model.readout($0, wind: wind, temp: temp))" } ?? "")
    }

    private func index(at x: CGFloat, cw: CGFloat) -> Int? {
        guard x >= Self.labelW, cw > 0 else { return nil }
        return min(model.hours.count - 1, max(0, Int((x - Self.labelW) / cw)))
    }

    private func label(_ s: String, size: CGFloat = 11, weight: Font.Weight = .bold, color: Color) -> Text {
        Text(s).font(.system(size: size, weight: weight)).foregroundColor(color)
    }

    private func draw(_ ctx: inout GraphicsContext, width: CGFloat, cw: CGFloat) {
        let hours = model.hours
        let n = hours.count
        let x0 = Self.labelW
        func cx(_ i: Int) -> CGFloat { x0 + (CGFloat(i) + 0.5) * cw }
        let ink = Color(.label)

        for row in 0..<4 {
            let y = CGFloat(row) * (Self.rowH + Self.gap)
            let mid = y + Self.rowH / 2
            let rect = CGRect(x: x0, y: y, width: width - x0, height: Self.rowH)
            ctx.draw(label(["Rain", "Wind", "Temp", "Sky"][row], weight: .semibold, color: .secondary),
                     at: CGPoint(x: 0, y: mid), anchor: .leading)
            var band = ctx
            band.clip(to: Path(roundedRect: rect, cornerRadius: 7))
            band.fill(Path(rect), with: .color(Color(.tertiarySystemFill)))

            // Each hour's colour, and how deep it went for the labels. The
            // band is one gradient through the hours' centres: no seams,
            // and a change reads as the change it is.
            var depth = [Double](repeating: 0, count: n)
            var stops: [Gradient.Stop] = []
            for i in 0..<n {
                let h = hours[i]
                let color: Color
                switch row {
                case 0:
                    depth[i] = Double(h.rain) / 100
                    color = ForecastPalette.rain.opacity(0.06 + 0.9 * depth[i])
                case 1:
                    depth[i] = min(1, (h.peakKmh ?? 0) / 55)
                    color = ForecastPalette.wind.opacity(0.08 + 0.85 * depth[i])
                case 2:
                    depth[i] = 1
                    color = h.tempC.map { ForecastPalette.temperature($0) } ?? .clear
                default:
                    depth[i] = (h.cloud ?? 0) / 100
                    color = ForecastPalette.sky.opacity(0.08 + 0.55 * depth[i])
                }
                stops.append(Gradient.Stop(color: color, location: (CGFloat(i) + 0.5) / CGFloat(n)))
            }
            if let first = stops.first, let last = stops.last {
                stops.insert(Gradient.Stop(color: first.color, location: 0), at: 0)
                stops.append(Gradient.Stop(color: last.color, location: 1))
            }
            band.fill(Path(rect), with: .linearGradient(Gradient(stops: stops),
                                                        startPoint: CGPoint(x: x0, y: mid),
                                                        endPoint: CGPoint(x: width, y: mid)))
            func on(_ i: Int) -> Color { depth[i] >= 0.45 ? .white : ink }

            switch row {
            case 0:
                if let p = hours.indices.max(by: { hours[$0].rain < hours[$1].rain }), hours[p].rain >= 15 {
                    ctx.draw(label("\(hours[p].rain)%", color: on(p)), at: CGPoint(x: cx(p), y: mid))
                    if let s = model.found.rainStart, abs(s - p) >= 2 {
                        ctx.draw(label("\(hours[s].rain)%", size: 10, weight: .semibold, color: on(s)), at: CGPoint(x: cx(s), y: mid))
                    }
                }
            case 1:
                let peak = hours.indices.filter { hours[$0].peakKmh != nil }
                    .max { hours[$0].peakKmh! < hours[$1].peakKmh! }
                    .flatMap { (hours[$0].peakKmh ?? 0) >= 20 ? $0 : nil }
                for i in stride(from: 0, to: n, by: 3) {
                    if let p = peak, abs(i - p) <= 1 { continue }
                    guard let d = hours[i].dir, (hours[i].windKmh ?? 0) >= 4 else { continue }
                    drawArrow(&ctx, at: CGPoint(x: cx(i), y: mid), dir: d,
                              color: depth[i] >= 0.45 ? .white : ForecastPalette.windDeep)
                }
                if let p = peak {
                    ctx.draw(label(ShortTermForecast.windShort(hours[p], wind), color: on(p)), at: CGPoint(x: cx(p), y: mid))
                }
            case 2:
                if let t = hours[0].tempC {
                    ctx.draw(label(temp.format(t), color: .white), at: CGPoint(x: x0 + 6, y: mid), anchor: .leading)
                }
                if let t = hours[n - 1].tempC {
                    ctx.draw(label(temp.format(t), color: .white), at: CGPoint(x: width - 6, y: mid), anchor: .trailing)
                }
                for i in [model.found.low, model.found.high].compactMap({ $0 }) where i > 1 && i < n - 2 {
                    if let t = hours[i].tempC {
                        ctx.draw(label(temp.format(t), color: .white), at: CGPoint(x: cx(i), y: mid))
                    }
                }
            default:
                // The sky word over each long enough run of the same sky.
                var start = 0
                for i in 1...n {
                    let word = ShortTermForecast.sky(hours[start].cloud)
                    if i < n, ShortTermForecast.sky(hours[i].cloud) == word { continue }
                    let run = CGFloat(i - start) * cw
                    if let word, run >= CGFloat(word.count) * 6 + 8 {
                        let mi = (start + i - 1) / 2
                        ctx.draw(label(word, size: 10, weight: .semibold, color: on(mi)),
                                 at: CGPoint(x: x0 + CGFloat(start) * cw + run / 2, y: mid))
                    }
                    start = i
                }
            }
        }

        // The hour being read.
        if let i = picked, i < n {
            var p = Path()
            p.move(to: CGPoint(x: cx(i), y: -3))
            p.addLine(to: CGPoint(x: cx(i), y: 4 * (Self.rowH + Self.gap) - Self.gap + 3))
            ctx.stroke(p, with: .color(ink.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }

        // Time along the bottom: now, then the clock every three hours.
        let ty = 4 * (Self.rowH + Self.gap) - Self.gap + 6 + Self.axisH / 2
        for i in stride(from: 0, to: n, by: 3) {
            let text = i == 0 ? label("now", weight: .semibold, color: .blue)
                              : label(ShortTermForecast.clock(hours[i].t), weight: .regular, color: .secondary)
            let anchor: UnitPoint = i == 0 ? .leading : (i >= n - 1 ? .trailing : .center)
            let x = i == 0 ? x0 : (i >= n - 1 ? width : cx(i))
            ctx.draw(text, at: CGPoint(x: x, y: ty), anchor: anchor)
        }
    }

    /// Points where the wind blows.
    private func drawArrow(_ ctx: inout GraphicsContext, at c: CGPoint, dir: Double, color: Color) {
        let ph = (dir + 180) * .pi / 180
        let v = CGVector(dx: sin(ph), dy: -cos(ph))
        let L: CGFloat = 5
        let tip = CGPoint(x: c.x + v.dx * L, y: c.y + v.dy * L)
        var shaft = Path()
        shaft.move(to: CGPoint(x: c.x - v.dx * L, y: c.y - v.dy * L))
        shaft.addLine(to: tip)
        ctx.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        let base = CGPoint(x: tip.x - v.dx * 3.5, y: tip.y - v.dy * 3.5)
        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: base.x - v.dy * 2.6, y: base.y + v.dx * 2.6))
        head.addLine(to: CGPoint(x: base.x + v.dy * 2.6, y: base.y - v.dx * 2.6))
        head.closeSubpath()
        ctx.fill(head, with: .color(color))
    }
}

// MARK: - Changes: a timeline of what changes

struct ChangesForecastCard: View {
    let combined: CombinedResponse
    let now: Date
    @AppStorage("windUnit", store: AppConfig.sharedDefaults) private var windUnitRaw: String = WindUnit.mph.rawValue
    @AppStorage(TemperatureUnit.key, store: AppConfig.sharedDefaults) private var tempUnitRaw: String = TemperatureUnit.celsius.rawValue
    private var wind: WindUnit { WindUnit(rawValue: windUnitRaw) ?? .mph }
    private var temp: TemperatureUnit { TemperatureUnit(rawValue: tempUnitRaw) ?? .celsius }

    private struct Row: Identifiable {
        let id: String
        let time: String
        let icon: String
        let color: Color
        let text: String
        let isNow: Bool
    }

    private static func look(_ k: ShortTermForecast.Kind) -> (String, Color) {
        switch k {
        case .rainStart: return ("cloud.rain", ForecastPalette.rain)
        case .rainEnd: return ("cloud.drizzle", ForecastPalette.rain)
        case .thunder: return ("cloud.bolt", .orange)
        case .windUp: return ("wind", ForecastPalette.wind)
        case .windShift: return ("arrow.triangle.turn.up.right.circle", ForecastPalette.wind)
        case .front: return ("arrow.right.to.line", ForecastPalette.front)
        case .clearing: return ("sun.max", .yellow)
        case .clouding: return ("cloud", ForecastPalette.sky)
        case .low: return ("thermometer.low", ForecastPalette.temp)
        case .high: return ("thermometer.high", ForecastPalette.temp)
        }
    }

    var body: some View {
        let m = ShortTermForecast(forecast: combined.forecast?.hourly ?? [], now: now)
        if m.isEmpty {
            EmptyView()
        } else {
            let events = m.events(wind: wind, temp: temp)
            let rows = [Row(id: "now", time: "now", icon: "clock", color: .blue,
                            text: m.nowText(current: combined.pressure.current, wind: wind, temp: temp), isNow: true)]
                + events.map { e in
                    let l = Self.look(e.kind)
                    return Row(id: e.id, time: ShortTermForecast.clock(e.t), icon: l.0, color: l.1, text: e.text, isNow: false)
                }
            ForecastCardChrome(title: "What changes, and when", range: rangeText(m)) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        HStack(alignment: .top, spacing: 10) {
                            Text(r.time)
                                .font(.caption.weight(r.isNow ? .semibold : .medium))
                                .foregroundStyle(r.isNow ? Color.blue : Color.secondary)
                                .monospacedDigit()
                                .frame(width: 44, alignment: .leading)
                                .padding(.top, 3)
                            VStack(spacing: 3) {
                                Image(systemName: r.icon)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(r.color)
                                    .frame(width: 24, height: 24)
                                    .background(Color(.systemBackground), in: Circle())
                                    .overlay(Circle().strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5))
                                if i < rows.count - 1 {
                                    Capsule().fill(Color(.systemGray4)).frame(width: 2).frame(minHeight: 14)
                                }
                            }
                            Text(r.text)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 3)
                                .padding(.bottom, i < rows.count - 1 ? 12 : 0)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if events.isEmpty {
                    Text("Nothing changes enough to matter through \(ShortTermForecast.clock(m.hours[m.hours.count - 1].t)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Hourly: every hour, side by side

struct HourlyForecastCard: View {
    let combined: CombinedResponse
    let now: Date
    /// Off only for picture tests: ImageRenderer draws nothing inside a scroll view.
    var scrolls = true
    @AppStorage("windUnit", store: AppConfig.sharedDefaults) private var windUnitRaw: String = WindUnit.mph.rawValue
    @AppStorage(TemperatureUnit.key, store: AppConfig.sharedDefaults) private var tempUnitRaw: String = TemperatureUnit.celsius.rawValue
    private var wind: WindUnit { WindUnit(rawValue: windUnitRaw) ?? .mph }
    private var temp: TemperatureUnit { TemperatureUnit(rawValue: tempUnitRaw) ?? .celsius }

    static func symbol(code: Int?, cloud: Double?, rain: Int, night: Bool) -> String {
        switch code ?? -1 {
        case 0: return night ? "moon.stars.fill" : "sun.max.fill"
        case 1, 2: return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return rain >= 60 ? "cloud.heavyrain.fill" : "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default:
            if rain >= 50 { return "cloud.rain.fill" }
            let c = cloud ?? 0
            if c < 20 { return night ? "moon.stars.fill" : "sun.max.fill" }
            if c < 70 { return night ? "cloud.moon.fill" : "cloud.sun.fill" }
            return "cloud.fill"
        }
    }

    /// Grey clouds with a coloured sun, moon or rain: the multicolor set
    /// draws white clouds, which vanish on the light card.
    static func tint(_ symbol: String) -> (Color, Color) {
        let cloud = Color(.systemGray2)
        let moon = Color(red: 0.45, green: 0.52, blue: 0.80)
        switch symbol {
        case "sun.max.fill": return (.yellow, .yellow)
        case "moon.stars.fill": return (moon, moon)
        case "cloud.sun.fill": return (cloud, .yellow)
        case "cloud.moon.fill": return (cloud, moon)
        case "cloud.snow.fill": return (cloud, .cyan)
        case "cloud.bolt.rain.fill": return (cloud, .yellow)
        case "cloud.drizzle.fill", "cloud.rain.fill", "cloud.heavyrain.fill": return (cloud, ForecastPalette.rain)
        default: return (cloud, cloud)
        }
    }

    private func isNight(_ t: Date) -> Bool { SunTimes.isNight(t, sun: combined.forecast?.sun) }

    var body: some View {
        let m = ShortTermForecast(forecast: combined.forecast?.hourly ?? [], now: now, windowHours: 24)
        if m.isEmpty {
            EmptyView()
        } else {
            ForecastCardChrome(title: "Hour by hour", range: "next \(m.hours.count - 1) h") {
                let shown = scrolls ? m.hours : Array(m.hours.prefix(7))
                let columns = HStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, h in
                        column(i, h)
                    }
                }
                if scrolls {
                    ScrollView(.horizontal, showsIndicators: false) { columns }
                } else {
                    columns
                }
            }
        }
    }

    private func column(_ i: Int, _ h: ShortTermForecast.Hour) -> some View {
        VStack(spacing: 6) {
            Text(i == 0 ? "now" : ShortTermForecast.clock(h.t))
                .font(.caption2.weight(i == 0 ? .semibold : .regular))
                .foregroundStyle(i == 0 ? Color.blue : Color.secondary)
            Text(h.tempC.map(temp.format) ?? "–")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Group {
                if let d = h.dir, (h.windKmh ?? 0) >= 4 {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ForecastPalette.wind)
                        .rotationEffect(.degrees(d + 180))
                } else {
                    Text("calm").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            .frame(height: 14)
            Text(ShortTermForecast.windShort(h, wind))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            VStack(spacing: 3) {
                ZStack(alignment: .bottom) {
                    Color.clear.frame(width: 12, height: 26)
                    // Same rule as the chart: nothing at 0%, a pale stub for a
                    // slight chance, the true height from 10%.
                    if h.rain > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(ForecastPalette.rain.opacity(h.rain < 10 ? 0.3 : (h.rain >= 30 ? 0.9 : 0.5)))
                            .frame(width: 12, height: max(3, 26 * CGFloat(h.rain) / 100))
                    }
                }
                Text("\(h.rain)%")
                    .font(.system(size: 10))
                    .foregroundStyle(h.rain >= 30 ? ForecastPalette.rain : Color.secondary)
                    .monospacedDigit()
            }
            // The sky for the hour, under the rain it goes with.
            let sym = Self.symbol(code: h.code, cloud: h.cloud, rain: h.rain, night: isNight(h.t))
            let tint = Self.tint(sym)
            Image(systemName: sym)
                .symbolRenderingMode(.palette)
                .foregroundStyle(tint.0, tint.1)
                .font(.system(size: 18))
                .frame(height: 22)
        }
        .frame(width: 50)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(i == 0 ? "Now" : ShortTermForecast.clock(h.t)): \(h.tempC.map(temp.format) ?? ""), wind \(ShortTermForecast.windText(h, wind)), rain \(h.rain) percent")
    }
}
