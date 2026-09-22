//  FieldConditionsView.swift
//  Barry — iOS
//
//  Field conditions: density altitude now + where it's headed, and the fog
//  outlook for the coming night. The DA forecast is the takeoff-performance
//  decision made visible ("3,100 ft if you go at 9, 5,200 ft if you wait for
//  4 PM"); the fog line only exists on nights that actually have a setup —
//  quiet nights render nothing, same rule as the front watch.

import SwiftUI

struct FieldConditionsCard: View {
    let conditions: ConditionsOut
    /// The METAR (cloud layers) and the forecast (cloud cover trend).
    let combined: CombinedResponse
    let now: Date
    /// Opens the Aloft column. The Clouds row and the card's last row both
    /// lead there; nil means neither is offered.
    var onAloft: (() -> Void)? = nil

    /// "agl" (the model's own height above ground) or "msl" (field
    /// elevation added, so the number reads like an altimeter).
    static let blReferenceKey = "boundaryLayerReference"
    @AppStorage(FieldConditionsCard.blReferenceKey, store: AppConfig.sharedDefaults)
    private var blReference: String = "agl"

    private var blMSL: Bool { blReference == "msl" && conditions.fieldElevationFt != nil }
    private var blOffset: Int { blMSL ? (conditions.fieldElevationFt ?? 0) : 0 }
    private var blSuffix: String { blMSL ? " MSL" : " AGL" }

    @State private var showRideInfo = false

    /// The ride sentence: which kind of bumps, how high, and when it changes.
    /// Falls back to the static explainer on an old backend.
    private var rideText: String {
        guard let r = conditions.ride else {
            return "Bumpy, hazy air mixes below it, smoother air above."
        }
        let top = (r.topFt ?? conditions.boundaryLayerFt).map { ft($0 + blOffset) }
        let below = top.map { " below \($0)" } ?? ""
        var line: String
        switch (r.band, r.kind) {
        case ("bumpy", "thermal"): line = "Bumpy\(below), strong thermals."
        case ("bumpy", "wind"):    line = "Rough\(below), gusty wind and shear."
        case ("bumpy", _):         line = "Bumpy\(below), thermals and wind together."
        case ("chop", "thermal"):  line = "Light thermal bumps\(below)."
        case ("chop", "wind"):     line = "Light chop\(below), mostly wind."
        case ("chop", _):          line = "Light chop\(below), some thermals, some wind."
        default:                   line = r.thermal >= r.mechanical
                                        ? "Smooth, shallow layer and weak thermals."
                                        : "Smooth, little wind to stir it."
        }
        if let next = r.changeBand, let at = r.changeAt {
            let when = at.formatted(date: .omitted, time: .shortened)
            let rank = ["smooth": 0, "chop": 1, "bumpy": 2]
            let easing = (rank[next] ?? 0) < (rank[r.band] ?? 0)
            line += easing ? " Settling down after \(when)." : " Getting bumpier after \(when)."
        }
        return line
    }

    private var rideColor: Color {
        switch conditions.ride?.band {
        case "bumpy": return .orange
        case "chop": return .primary
        default: return .secondary
        }
    }

    private static let ftFormat: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private func ft(_ v: Int) -> String {
        (Self.ftFormat.string(from: NSNumber(value: v)) ?? "\(v)") + " ft"
    }

    /// The highest forecast DA in the window — the number that decides whether
    /// to fly now or wait. Only worth a line when it's meaningfully above (or
    /// below) the current value.
    private var peak: DAPoint? {
        conditions.daForecast.max { $0.ft < $1.ft }
    }

    private var peakLine: (text: String, rising: Bool)? {
        guard let p = peak else { return nil }
        let time = p.t.formatted(date: .omitted, time: .shortened)
        if let now = conditions.densityAltitudeFt {
            if p.ft - now >= 300 {
                return ("Rising to \(ft(p.ft)) around \(time)", true)
            }
            if let low = conditions.daForecast.min(by: { $0.ft < $1.ft }),
               now - low.ft >= 300 {
                let lowTime = low.t.formatted(date: .omitted, time: .shortened)
                return ("Down to \(ft(low.ft)) by \(lowTime)", false)
            }
            return nil  // flat day: the current number is the story
        }
        return ("Around \(ft(p.ft)) at \(time)", true)
    }

    /// A station without temp/dew point (some AWOS fields) still gets the
    /// forecast DA; nothing at all means the card shouldn't exist.
    private var hasDA: Bool { conditions.densityAltitudeFt != nil || peak != nil }

    /// The headline is the AWOS method (dry air, what the field broadcasts
    /// and what the POH assumes); say what today's humidity would add.
    private var humidityNote: String {
        guard let dry = conditions.densityAltitudeFt, let humid = conditions.densityAltitudeHumidFt,
              humid - dry >= 100 else { return "" }
        return " · humidity adds \(ft(humid - dry))"
    }

    /// A trend line that wraps instead of pushing the card past the screen.
    private func trendLabel(_ text: String, rising: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: rising ? "arrow.up.right" : "arrow.down.right")
                .font(.caption2.weight(.semibold))
            Text(text)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Clouds

    private var cur: CurrentObs { combined.pressure.current }

    /// Layers from the METAR, falling back to the ceiling fields on an old
    /// backend. Empty means the station said nothing about the sky.
    private var cloudLayers: [CloudLayer] {
        if let layers = cur.clouds, !layers.isEmpty { return layers }
        if let cover = cur.ceilingCover { return [CloudLayer(cover: cover, baseFt: cur.ceilingFt)] }
        return []
    }

    private var hasClouds: Bool { !cloudLayers.isEmpty || cloudTrend != nil }

    /// "BKN 4,500 ft" (the ceiling), else the lowest layer, else "Clear".
    private var cloudValue: String {
        if let ft = cur.ceilingFt {
            return "\(cur.ceilingCover ?? "CIG") \(ft.formatted()) ft"
        }
        if let first = cloudLayers.first {
            if ["CLR", "SKC", "CAVOK", "NSC"].contains(first.cover) { return "Clear" }
            if let b = first.baseFt { return "\(first.cover) \(b.formatted()) ft" }
            return first.cover
        }
        return "No report"
    }

    /// Every layer in METAR shorthand: "SCT 2,500 · BKN 4,500 · OVC 12,000".
    private var cloudLayersText: String? {
        let named = cloudLayers.filter { $0.baseFt != nil }
        guard named.count > 1 || (named.count == 1 && cur.ceilingFt == nil) else { return nil }
        return named.map { "\($0.cover) \(($0.baseFt ?? 0).formatted())" }.joined(separator: " · ")
    }

    /// Where the model takes the cloud cover over the next 12 h: the first
    /// hour that differs from now by 40 points or more, else "holds".
    private var cloudTrend: (text: String, clearing: Bool)? {
        guard let hours = combined.forecast?.hourly else { return nil }
        let window = hours.filter { $0.t >= now && $0.t <= now.addingTimeInterval(12 * 3600) && $0.cloudcover != nil }
        guard let first = window.first, let nowCover = first.cloudcover, window.count >= 3 else { return nil }
        if let turn = window.first(where: { abs(($0.cloudcover ?? nowCover) - nowCover) >= 40 }),
           let c = turn.cloudcover {
            let when = turn.t.formatted(date: .omitted, time: .shortened)
            return c < nowCover ? ("Clearing to \(Int(c))% around \(when)", true)
                                : ("Thickening to \(Int(c))% by \(when)", false)
        }
        return ("Cover holds near \(Int(nowCover))% through the next 12 h", nowCover < 50)
    }

    /// Where the boundary layer is headed over the next hours: the top of the
    /// bumpy, hazy air. Rising through the day is the normal story; the line
    /// only appears when it moves a real amount.
    private var blLine: (text: String, rising: Bool)? {
        guard let now = conditions.boundaryLayerFt else { return nil }
        let fc = conditions.blForecast
        guard let hi = fc.max(by: { $0.ft < $1.ft }), let lo = fc.min(by: { $0.ft < $1.ft }) else { return nil }
        if hi.ft - now >= 1000 {
            return ("Rising to \(ft(hi.ft + blOffset)) around \(hi.t.formatted(date: .omitted, time: .shortened))", true)
        }
        if now - lo.ft >= 1000 {
            return ("Down to \(ft(lo.ft + blOffset)) by \(lo.t.formatted(date: .omitted, time: .shortened))", false)
        }
        return nil
    }

    /// "Thunderstorms 40 mi to the west" / "Thunderstorms likely 3 PM to
    /// 7 PM" / "Thunderstorms possible around 4 PM".
    private func stormLine(_ st: StormOut) -> String {
        let t = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        switch st.risk {
        case "observed":
            if let d = st.distanceMi, d < 3 { return "Thunderstorms at the field" }
            return "Thunderstorms in the area"
        case "likely":
            var line = "Thunderstorms likely"
            if let s = st.start { line += " \(t(s))" }
            if let s = st.start, let e = st.end, e > s { line += " to \(t(e))" }
            return line
        default:
            var line = "Thunderstorms possible"
            if let s = st.start { line += " around \(t(s))" }
            return line
        }
    }

    /// The detail under it: the server's sentence, with the arrival time
    /// filled in and, for observed storms, the forecast window after.
    private func stormDetail(_ st: StormOut) -> String {
        let t = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        var text = st.detail
        if let eta = st.etaAt { text = text.replacingOccurrences(of: "{eta}", with: t(eta)) }
        // Where they are leads the detail line: "29 mi to the north. Moving east, away from you."
        if st.risk == "observed", let d = st.distanceMi, d >= 3, let c = st.cardinal {
            text = "\(d) mi to the \(c). " + text
        }
        if st.risk == "observed", let s = st.forecastStart {
            text += " More expected here \(t(s))"
            if let e = st.forecastEnd, e > s { text += " to \(t(e))" }
            text += "."
        }
        return text
    }

    private func stormColor(_ st: StormOut) -> Color {
        switch st.risk {
        case "observed": return (st.distanceMi ?? 100) < 3 || st.towardYou == true ? .red : .orange
        case "likely": return .orange
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasDA {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    PerformanceAltitudeIcon()
                        .frame(height: 13)
                        .foregroundStyle(.blue)
                    Text("Density altitude")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if let da = conditions.densityAltitudeFt {
                        Text(ft(da))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    } else if let p = peak {
                        Text("~\(ft(p.ft)) later")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                HStack(alignment: .top) {
                    if let elev = conditions.fieldElevationFt {
                        Text("Field \(ft(elev))" + humidityNote)
                    } else if conditions.densityAltitudeFt == nil {
                        Text(combined.pressure.current.temp == nil
                             ? "No temperature in this station's report"
                             : "No field elevation on file for this station")
                    }
                    Spacer(minLength: 8)
                    if let line = peakLine {
                        trendLabel(line.text, rising: line.rising)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if hasClouds {
                if hasDA { Divider() }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: cur.ceilingFt != nil ? "cloud.fill" : "cloud")
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                    Text("Clouds")
                        .font(.subheadline.weight(.medium))
                    if let cat = cur.fltCat {
                        Text(cat)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FlightCategory.color(cat))
                    }
                    Spacer()
                    Text(cloudValue)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    if onAloft != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { onAloft?() }
                .accessibilityAddTraits(onAloft != nil ? .isButton : [])
                .accessibilityIdentifier("conditions.clouds")
                HStack {
                    if let layers = cloudLayersText {
                        Text(layers)
                            .monospacedDigit()
                    } else if cur.ceilingFt != nil {
                        Text("Ceiling")
                    }
                    Spacer(minLength: 8)
                    if let t = cloudTrend {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Image(systemName: t.clearing ? "sun.max" : "cloud.fill")
                                .font(.caption2.weight(.semibold))
                            Text(t.text)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let bl = conditions.boundaryLayerFt {
                if hasDA || hasClouds { Divider() }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    AirLayersIcon()
                        .frame(height: 12)
                        .foregroundStyle(.blue)
                    Text("Boundary layer top")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    // MSL chosen but no elevation to add: say so rather
                    // than quietly showing AGL.
                    Text(ft(bl + blOffset) + blSuffix
                         + (blReference == "msl" && !blMSL ? " (no field elevation)" : ""))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                // The trend on its own line, then the ride sentence at full
                // width: sharing a row squeezed the sentence into a column.
                if let line = blLine {
                    trendLabel(line.text, rising: line.rising)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(rideText)
                        .foregroundStyle(rideColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if conditions.ride != nil {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { showRideInfo.toggle() }
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("How the ride estimate is made")
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if showRideInfo {
                    Text("Based on available meteorological data. For advisement only, not a replacement for PIREPs.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }

            if let st = conditions.storm {
                if hasDA || hasClouds || conditions.boundaryLayerFt != nil { Divider() }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: st.risk == "observed" ? "bolt.fill" : "cloud.bolt.fill")
                        .font(.subheadline)
                        .foregroundStyle(stormColor(st))
                    Text(stormLine(st))
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(stormDetail(st))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let fog = conditions.fog {
                if hasDA || hasClouds || conditions.boundaryLayerFt != nil || conditions.storm != nil { Divider() }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "cloud.fog.fill")
                        .font(.subheadline)
                        .foregroundStyle(fog.risk == "likely" ? .orange : .secondary)
                    Text(fogLine(fog))
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(fog.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let onAloft {
                Divider()
                Button(action: onAloft) {
                    HStack(spacing: 8) {
                        Text("Clouds and winds aloft")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("conditions.aloft")
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private func fogLine(_ fog: FogOut) -> String {
        var line = fog.risk == "likely" ? "Fog likely" : "Fog possible"
        if let onset = fog.onset {
            line += " from \(onset.formatted(date: .omitted, time: .shortened))"
        } else {
            line += " overnight"
        }
        if let clearing = fog.clearing {
            line += ", burning off around \(clearing.formatted(date: .omitted, time: .shortened))"
        }
        return line
    }
}
