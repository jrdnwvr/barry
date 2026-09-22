//  AloftView.swift
//  Barry — iOS
//
//  Aloft: the vertical column at the station. Clouds by model level with
//  the METAR's reported ceiling drawn separately, temperature and dew point
//  per level, wind as a barb and as numbers, the freezing level and the
//  boundary layer top, hourly for a day on a scrubber. The scale gives the
//  bottom 6,000 ft half the height, because that is where the detail is.

import SwiftUI

// MARK: - Model

@MainActor
final class AloftModel: ObservableObject {
    @Published private(set) var hours: [AloftHour] = []
    @Published private(set) var failed = false
    @Published private(set) var loading = false
    private let api = BarryAPI()

    func load(lat: Double, lon: Double) async {
        loading = true
        defer { loading = false }
        do {
            hours = try await api.aloft(lat: lat, lon: lon).hours
            failed = hours.isEmpty
        } catch {
            failed = hours.isEmpty
        }
    }
}

enum AloftLayer: String, CaseIterable, Identifiable {
    case clouds, wind, temp, icing, layer
    var id: String { rawValue }
    var label: String {
        switch self {
        case .clouds: return "Clouds"
        case .wind: return "Wind"
        case .temp: return "Temp"
        case .icing: return "Icing"
        case .layer: return "Layer"
        }
    }
    static let defaultOn: Set<AloftLayer> = [.clouds, .wind, .temp, .icing]
    static let key = "aloftLayers"
    static let ceilingKey = "aloftCeilingFt"
}

/// The column's colors: system ones where a system one exists, the rest
/// with a dark variant, so the screen reads at night in a cockpit.
enum AloftColors {
    static let tint = Color(uiColor: .init { $0.userInterfaceStyle == .dark ? UIColor(red: 0.36, green: 0.65, blue: 1.0, alpha: 1) : UIColor(red: 0.04, green: 0.38, blue: 0.82, alpha: 1) })
    static let cloudDense = Color(uiColor: .init { $0.userInterfaceStyle == .dark ? UIColor(red: 0.27, green: 0.38, blue: 0.53, alpha: 1) : UIColor(red: 0.66, green: 0.77, blue: 0.91, alpha: 1) })
    static let cloudLight = Color(uiColor: .init { $0.userInterfaceStyle == .dark ? UIColor(red: 0.18, green: 0.24, blue: 0.33, alpha: 1) : UIColor(red: 0.86, green: 0.91, blue: 0.96, alpha: 1) })
    static let boundary = Color(uiColor: .init { $0.userInterfaceStyle == .dark ? UIColor(red: 0.94, green: 0.63, blue: 0.29, alpha: 1) : UIColor(red: 0.76, green: 0.37, blue: 0.0, alpha: 1) })
    static let surface = Color(uiColor: .init { $0.userInterfaceStyle == .dark ? UIColor(red: 0.23, green: 0.19, blue: 0.16, alpha: 1) : UIColor(red: 0.91, green: 0.87, blue: 0.82, alpha: 1) })
    static let surfaceText = Color(uiColor: .init { $0.userInterfaceStyle == .dark ? UIColor(red: 0.82, green: 0.77, blue: 0.69, alpha: 1) : UIColor(red: 0.36, green: 0.29, blue: 0.21, alpha: 1) })
    static let toggleOn = Color(uiColor: .init { $0.userInterfaceStyle == .dark ? UIColor(red: 0.11, green: 0.18, blue: 0.29, alpha: 1) : UIColor(red: 0.88, green: 0.93, blue: 0.98, alpha: 1) })
    static let scaleBreak = Color(uiColor: .init { $0.userInterfaceStyle == .dark ? UIColor(white: 0.36, alpha: 1) : UIColor(red: 0.78, green: 0.78, blue: 0.8, alpha: 1) })
}

// MARK: - Screen

struct AloftScreen: View {
    let lat: Double
    let lon: Double
    let station: String
    let stationName: String
    let combined: CombinedResponse

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = AloftModel()
    @AppStorage(AloftLayer.ceilingKey, store: AppConfig.sharedDefaults) private var ceilingFt: Int = 18000
    @AppStorage(AloftLayer.key, store: AppConfig.sharedDefaults) private var layersRaw: String = "clouds,wind,temp,icing"
    @State private var hourOffset: Double = 0
    @State private var picked: AloftLevel?

    private var layers: Set<AloftLayer> {
        Set(layersRaw.split(separator: ",").compactMap { AloftLayer(rawValue: String($0)) })
    }

    private func toggle(_ l: AloftLayer) {
        var set = layers
        if set.contains(l) { set.remove(l) } else { set.insert(l) }
        layersRaw = AloftLayer.allCases.filter { set.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    private var hourIndex: Int { min(Int(hourOffset.rounded()), max(0, model.hours.count - 1)) }
    private var hour: AloftHour? { model.hours.isEmpty ? nil : model.hours[hourIndex] }
    private var groundFt: Int { combined.conditions?.fieldElevationFt ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            card
                .padding(.horizontal, 12)
            toggles
            scrubber
            Text("Levels Open-Meteo · ceiling AWC · elevation OurAirports")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 6)
        }
        .background(Color(.systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load(lat: lat, lon: lon) }
        .sensoryFeedback(.selection, trigger: hourIndex)
        .sheet(item: $picked) { lv in
            AloftLevelSheet(level: lv, hour: hour, groundFt: groundFt)
                .presentationDetents([.height(300)])
        }
    }

    // MARK: Nav bar

    private var navBar: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AloftColors.tint)
                    .frame(width: 36, height: 36)
                    .background(Color(.secondarySystemGroupedBackground), in: Circle())
                    .overlay(Circle().strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5))
            }
            .accessibilityLabel("Back")
            .frame(width: 44, alignment: .leading)
            VStack(spacing: 1) {
                Text("Aloft").font(.headline)
                Text("\(station) · \(stationName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            Menu {
                ForEach(AloftScale.ceilings, id: \.self) { ft in
                    Button { ceilingFt = ft } label: {
                        if ft == ceilingFt { Label("\(AloftFormat.feet(ft)) ft", systemImage: "checkmark") }
                        else { Text("\(AloftFormat.feet(ft)) ft") }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(AloftFormat.feet(ceilingFt)) ft")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AloftColors.tint)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                .overlay(Capsule().strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Sets the top of the column")
            .accessibilityIdentifier("aloft.ceiling")
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                plot(size: geo.size)
            }
            .clipped()
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 10, trailing: 12))
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            if model.failed {
                Text("The model has no column for this spot right now.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            } else if model.hours.isEmpty {
                ProgressView()
            }
        }
    }

    private var header: some View {
        AloftGrid(widths: columnWidths) {
            Text("MSL")
            Text("CLOUDS")
            Text("TEMP").frame(maxWidth: .infinity, alignment: .trailing)
            Text("DEW").frame(maxWidth: .infinity, alignment: .trailing)
            Text("")
            Text("WIND").frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(.secondary)
        .padding(.bottom, 10)
    }

    /// 36 | flexible | 50 | 40 | 30 | 80, four points between.
    private var columnWidths: [CGFloat?] { [36, nil, 50, 40, 30, 80] }

    private func plot(size: CGSize) -> some View {
        let W = size.width, H = size.height
        let fixed: CGFloat = 36 + 50 + 40 + 30 + 80 + 5 * 4
        let cloudsX: CGFloat = 40
        let cloudsW = max(60, W - fixed)
        let tempX = cloudsX + cloudsW + 4, dewX = tempX + 54, barbX = dewX + 44, windX = barbX + 34
        let ceiling = Double(ceilingFt)
        let inset: CGFloat = 9                      // room for the top tick label
        let plotH = max(1, H - inset)
        func y(_ ft: Int) -> CGFloat { inset + plotH * AloftScale.fraction(ft: Double(ft), ceiling: ceiling) }
        let hr = hour
        let levels = hr.map { AloftRows.visible($0.levels, groundFt: groundFt, ceilingFt: ceilingFt, plotHeight: plotH) } ?? []
        let cur = combined.pressure.current
        let metarY: CGFloat? = cur.ceilingFt.map { y(groundFt + $0) }

        return ZStack(alignment: .topLeading) {
            // gridlines and ticks
            ForEach(Array(stride(from: 2000, through: ceilingFt, by: 2000)), id: \.self) { ft in
                let isBreak = ft == Int(AloftScale.breakFt) && ceilingFt > Int(AloftScale.breakFt)
                HStack(spacing: 4) {
                    Text("\(ft / 1000)k")
                        .font(.system(size: 13, weight: isBreak ? .semibold : .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .leading)
                    Rectangle()
                        .fill(isBreak ? AloftColors.scaleBreak : Color(.separator).opacity(0.6))
                        .frame(height: 0.5)
                }
                .frame(width: W)
                .position(x: W / 2, y: y(ft))
            }

            // cloud layers, in the clouds column
            if let hr, layers.contains(.clouds) {
                ForEach(Array(hr.clouds.enumerated()), id: \.offset) { _, c in
                    let top = y(min(c.topFt, ceilingFt)), base = y(max(c.baseFt, groundFt))
                    if base > top + 2 && c.baseFt < ceilingFt {
                        AloftCloudBand(cloud: c, showIcing: layers.contains(.icing),
                                       hideBase: metarY.map { abs($0 - base) < 22 } ?? false)
                            .frame(width: cloudsW, height: base - top)
                            .position(x: cloudsX + cloudsW / 2, y: (top + base) / 2)
                    }
                }
            }

            // the METAR's reported ceiling
            if layers.contains(.clouds), let cig = cur.ceilingFt, groundFt + cig < ceilingFt {
                let yy = y(groundFt + cig)
                Rectangle().fill(Color(.label)).frame(width: cloudsW, height: 2)
                    .position(x: cloudsX + cloudsW / 2, y: yy)
                AloftPill(text: "\(cur.ceilingCover ?? "CIG")\(String(format: "%03d", cig / 100)) · METAR", color: Color(.label))
                    .offset(x: cloudsX, y: yy + 4)
            }

            // freezing level
            if layers.contains(.icing), let frz = hr?.freezingFt, frz > groundFt, frz < ceilingFt {
                let yy = y(frz)
                AloftRule(style: .dotted, color: AloftColors.tint)
                    .frame(width: W - cloudsX, height: 1.5)
                    .position(x: cloudsX + (W - cloudsX) / 2, y: yy)
                AloftPill(text: "0 °C · \(AloftFormat.feet(frz)) ft", color: AloftColors.tint)
                    .offset(x: cloudsX, y: yy + 4)
            }

            // boundary layer top
            if layers.contains(.layer), let bl = hr?.blAglFt, groundFt + bl < ceilingFt {
                let yy = y(groundFt + bl)
                AloftRule(style: .dashed, color: AloftColors.boundary)
                    .frame(width: W - cloudsX, height: 1.5)
                    .position(x: cloudsX + (W - cloudsX) / 2, y: yy)
                AloftPill(text: "Boundary layer · \(AloftFormat.feet(bl)) AGL", color: AloftColors.boundary)
                    .offset(x: cloudsX, y: yy - 18)
            }

            // level rows
            ForEach(levels) { lv in
                let yy = y(lv.ft)
                HStack(spacing: 4) {
                    Color.clear.frame(width: 36)
                    Color.clear.frame(width: cloudsW)
                    if layers.contains(.temp) {
                        Text(AloftFormat.degrees(lv.tempC))
                            .fontWeight(.semibold)
                            .foregroundStyle(lv.tempC < 0 ? AloftColors.tint : Color(.label))
                            .frame(width: 50, alignment: .trailing)
                        Text(lv.dewC.map(AloftFormat.degrees) ?? "")
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    } else {
                        Color.clear.frame(width: 94)
                    }
                    if layers.contains(.wind), let dir = lv.dirDeg, let spd = lv.spdKt {
                        AloftBarbView(dirDeg: dir, speedKt: spd)
                            .frame(width: 30, height: 30)
                        HStack(spacing: 0) {
                            Text(AloftFormat.direction(dir)).fontWeight(.semibold)
                            Text(" / ").foregroundStyle(.secondary)
                            Text("\(Int(spd.rounded()))").fontWeight(.semibold)
                            Text(" kt").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .frame(width: 80, alignment: .trailing)
                    } else {
                        Color.clear.frame(width: 114)
                    }
                }
                .font(.system(size: 14))
                .monospacedDigit()
                .frame(width: W, height: 30)
                .contentShape(Rectangle())
                .onTapGesture { picked = lv }
                .position(x: W / 2, y: yy)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(AloftFormat.feet(lv.ft)) feet, \(AloftFormat.degrees(lv.tempC)), wind \(lv.dirDeg.map(AloftFormat.direction) ?? "calm") \(Int((lv.spdKt ?? 0).rounded())) knots")
            }

            // surface band
            let yg = y(groundFt)
            HStack {
                Text("\(station) · \(AloftFormat.feet(groundFt)) ft").fontWeight(.bold)
                Spacer()
                Text(surfaceLine(cur))
            }
            .font(.system(size: 12))
            .foregroundStyle(AloftColors.surfaceText)
            .padding(.horizontal, 8)
            .frame(width: W - cloudsX, height: max(18, H - yg), alignment: .center)
            .background(AloftColors.surface, in: UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
            .position(x: cloudsX + (W - cloudsX) / 2, y: yg + max(18, H - yg) / 2)
        }
        .frame(width: W, height: H)
    }

    private func surfaceLine(_ cur: CurrentObs) -> String {
        var parts: [String] = []
        if let kmh = cur.windspeed {
            let kt = Int((kmh / 1.852).rounded())
            let dir = cur.winddir.map { String(format: "%03d", Int($0.rounded()) == 0 ? 360 : Int($0.rounded())) } ?? "VRB"
            parts.append(kt == 0 ? "00000KT" : "\(dir)\(String(format: "%02d", kt))KT")
        }
        if let t = cur.temp, let d = cur.dewpoint {
            parts.append("\(Int(t.rounded()))/\(Int(d.rounded()))")
        }
        return parts.isEmpty ? "METAR" : "METAR " + parts.joined(separator: " · ")
    }

    // MARK: Toggles and scrubber

    private var toggles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
            ForEach(AloftLayer.allCases) { l in
                let on = layers.contains(l)
                Button { toggle(l) } label: {
                    Text(l.label)
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize()
                        .foregroundStyle(on ? AloftColors.tint : Color(.label).opacity(0.8))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(on ? AloftColors.toggleOn : Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("aloft.layer.\(l.rawValue)")
            }
            Menu {
                Button("Show every layer") { layersRaw = AloftLayer.allCases.map(\.rawValue).joined(separator: ",") }
                Button("Clouds only") { layersRaw = AloftLayer.clouds.rawValue }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(.label).opacity(0.8))
                    .frame(width: 30, height: 30)
                    .background(Color(.tertiarySystemFill), in: Circle())
            }
            .accessibilityLabel("More layers")
        }
        .padding(.horizontal, 12)
        }
        .padding(.top, 10)
    }

    private var timeLabel: (lead: String, time: String) {
        guard let hr = hour else { return ("Now", "") }
        let clock = hr.t.formatted(date: .omitted, time: .shortened)
        return hourIndex == 0 ? ("Now", clock) : ("+\(hourIndex) h", clock)
    }

    private var scrubber: some View {
        HStack(spacing: 12) {
            (Text(timeLabel.lead).fontWeight(.semibold)
             + Text(" · \(timeLabel.time)").foregroundColor(.secondary))
                .font(.subheadline)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 118, alignment: .leading)
                .accessibilityIdentifier("aloft.time")
            Slider(value: $hourOffset, in: 0...Double(max(1, model.hours.count - 1)), step: 1)
                .tint(AloftColors.tint)
                .accessibilityLabel("Forecast hour")
            Text("+24 h").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }
}

// MARK: - Pieces

/// The column grid the header shares with the rows.
struct AloftGrid<Content: View>: View {
    let widths: [CGFloat?]
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 4) {
            _VariadicView.Tree(AloftGridLayout(widths: widths)) { content }
        }
    }
}

struct AloftGridLayout: _VariadicView_MultiViewRoot {
    let widths: [CGFloat?]
    @ViewBuilder func body(children: _VariadicView.Children) -> some View {
        ForEach(Array(children.enumerated()), id: \.offset) { i, child in
            if let w = widths.indices.contains(i) ? widths[i] : nil {
                child.frame(width: w, alignment: .leading)
            } else {
                child.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct AloftCloudBand: View {
    let cloud: AloftCloud
    let showIcing: Bool
    /// The METAR's ceiling line runs through the base; its label wins.
    var hideBase: Bool = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(cloud.coverPct >= 70 ? AloftColors.cloudDense : AloftColors.cloudLight)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(cloud.coverPct)%")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(.label))
                if showIcing && cloud.icing {
                    Text("ICING")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(AloftColors.tint, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(EdgeInsets(top: 5, leading: 7, bottom: 5, trailing: 7))
            VStack {
                Text(AloftFormat.feet(cloud.topFt))
                Spacer(minLength: 0)
                Text(hideBase ? "" : AloftFormat.feet(cloud.baseFt))
            }
            .font(.system(size: 11))
            .foregroundStyle(Color(.label).opacity(0.75))
            .padding(EdgeInsets(top: 5, leading: 7, bottom: 5, trailing: 7))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .clipped()
    }
}

struct AloftPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 3)
            .background(Color(.secondarySystemGroupedBackground).opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
            .fixedSize()
    }
}

struct AloftRule: View {
    enum Style { case dotted, dashed }
    let style: Style
    let color: Color
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round,
                                              dash: style == .dotted ? [0.5, 4] : [6, 4]))
        }
    }
}

/// A standard meteorological barb in a 30 pt box: the staff points where
/// the wind comes from, the feathers count the knots.
struct AloftBarbView: View {
    let dirDeg: Double
    let speedKt: Double
    var body: some View {
        Canvas { ctx, size in
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: .degrees(dirDeg))
            let ink = GraphicsContext.Shading.color(Color(.label))
            var staff = Path()
            staff.move(to: .zero)
            staff.addLine(to: CGPoint(x: 0, y: -14))
            ctx.stroke(staff, with: ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            for m in WindBarb.marks(speedKt: speedKt) {
                switch m.kind {
                case .pennant:
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: m.y))
                    p.addLine(to: CGPoint(x: 8, y: m.y + 1))
                    p.addLine(to: CGPoint(x: 0, y: m.y + 4.5))
                    p.closeSubpath()
                    ctx.fill(p, with: ink)
                case .full:
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: m.y))
                    p.addLine(to: CGPoint(x: 8, y: m.y - 3))
                    ctx.stroke(p, with: ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                case .half:
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: m.y))
                    p.addLine(to: CGPoint(x: 4.5, y: m.y - 1.7))
                    ctx.stroke(p, with: ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
            }
            ctx.fill(Path(ellipseIn: CGRect(x: -1.8, y: -1.8, width: 3.6, height: 3.6)), with: ink)
        }
        .accessibilityHidden(true)
    }
}

/// What one level says, in words, when a row is tapped.
struct AloftLevelSheet: View {
    let level: AloftLevel
    let hour: AloftHour?
    let groundFt: Int

    private var icingRisk: String {
        guard let cover = level.cloudPct, cover >= 30 else { return "No cloud at this level." }
        if level.tempC <= 0 && level.tempC >= -20 { return "In cloud below freezing: icing possible." }
        if level.tempC > 0 { return "In cloud, above freezing." }
        return "In cloud, well below freezing: mostly ice crystals."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(AloftFormat.feet(level.ft)) ft MSL")
                .font(.title3.weight(.semibold))
            Text("\(AloftFormat.feet(level.ft - groundFt)) ft above the field · \(level.hPa) hPa")
                .foregroundStyle(.secondary)
            Divider()
            LabeledContent("Temperature", value: AloftFormat.degrees(level.tempC) + "C")
            if let d = level.dewC {
                LabeledContent("Dew point", value: AloftFormat.degrees(d) + "C")
                LabeledContent("Spread", value: AloftFormat.degrees(level.tempC - d))
            }
            if let dir = level.dirDeg, let spd = level.spdKt {
                LabeledContent("Wind", value: "\(AloftFormat.direction(dir)) at \(Int(spd.rounded())) kt")
            }
            if let c = level.cloudPct { LabeledContent("Cloud", value: "\(c)%") }
            Text(icingRisk)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .monospacedDigit()
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
