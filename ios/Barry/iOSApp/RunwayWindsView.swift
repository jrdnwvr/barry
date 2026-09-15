//  RunwayWindsView.swift
//  Barry — iOS
//
//  Crosswind readout. The METAR wind is a real measurement; runway headings
//  come from OurAirports via the backend. Both are degrees true, so the
//  components are a straight projection. Positive crosswind = from the right
//  when looking down the runway.

import SwiftUI

struct RunwayWind: Identifiable {
    let ident: String
    let heading: Double
    let headwind: Double        // kt, negative = tailwind
    let crosswind: Double       // kt, signed, positive = from the right
    let gustCrosswind: Double?  // kt, signed, when a gust was reported

    var id: String { ident }
    var isTailwind: Bool { headwind < -0.5 }
}

enum RunwayWinds {
    /// One entry per runway END, best first: headwind ends before tailwind
    /// ends, then least crosswind. Nil wind or unknown runways gives [].
    static func compute(runways: [Runway], windDirDeg: Double?, windKt: Double,
                        gustKt: Double?) -> [RunwayWind] {
        guard let dir = windDirDeg, windKt >= 1 else { return [] }
        var out: [RunwayWind] = []
        for r in runways {
            for (ident, hdg) in [(r.le, r.leHeading), (r.he, r.heHeading)] where !ident.isEmpty {
                let delta = (dir - hdg) * .pi / 180
                let head = windKt * cos(delta)
                let cross = windKt * sin(delta)
                let gustCross = gustKt.map { $0 * sin(delta) }
                out.append(RunwayWind(ident: ident, heading: hdg, headwind: head,
                                      crosswind: cross, gustCrosswind: gustCross))
            }
        }
        return out.sorted {
            if $0.isTailwind != $1.isTailwind { return !$0.isTailwind }
            return abs($0.crosswind) < abs($1.crosswind)
        }
    }
}

/// Main-page card: the best runway end and its components, with the rest a
/// tap away. Renders nothing when the wind is calm or the field is unknown.
struct RunwayWindsCard: View {
    let combined: CombinedResponse
    @State private var expanded = false

    private var winds: [RunwayWind] {
        let cur = combined.pressure.current
        let kt = (cur.windspeed ?? 0) / 1.852
        let gust = cur.windgust.map { $0 / 1.852 }
        return RunwayWinds.compute(runways: combined.runways ?? [],
                                   windDirDeg: cur.winddir, windKt: kt, gustKt: gust)
    }

    /// The next hours on the best runway end: peak crosswind, and when another
    /// end takes over. Model wind (Open-Meteo hourly) already in /combined.
    private struct Outlook { let peakKt: Int; let peakAt: Date; let switchTo: String?; let switchAt: Date? }

    private func outlook(best: RunwayWind, now: Date) -> Outlook? {
        guard let hours = combined.forecast?.hourly, let runways = combined.runways, !runways.isEmpty else { return nil }
        let window = hours.filter { $0.t > now && $0.t <= now.addingTimeInterval(12 * 3600) && $0.windspeed != nil }
        guard window.count >= 3 else { return nil }
        var peak: (Int, Date)? = nil
        var switchTo: (String, Date)? = nil
        for h in window {
            let kt = (h.windspeed ?? 0) / 1.852
            let all = RunwayWinds.compute(runways: runways, windDirDeg: h.winddir, windKt: kt,
                                          gustKt: h.windgust.map { $0 / 1.852 })
            guard let mine = all.first(where: { $0.ident == best.ident }) else { continue }
            let x = Int(abs(mine.crosswind).rounded())
            if peak == nil || x > peak!.0 { peak = (x, h.t) }
            // Another end becomes clearly better: a headwind end with at
            // least 3 kt less crosswind, or mine has turned into a tailwind.
            if switchTo == nil, let top = all.first, top.ident != best.ident,
               (mine.isTailwind || abs(mine.crosswind) - abs(top.crosswind) >= 3) {
                switchTo = (top.ident, h.t)
            }
        }
        guard let pk = peak else { return nil }
        return Outlook(peakKt: pk.0, peakAt: pk.1, switchTo: switchTo?.0, switchAt: switchTo?.1)
    }

    private func outlookText(_ o: Outlook) -> String {
        var t = "Next 12 h: crosswind peaks \(o.peakKt) kt around \(o.peakAt.formatted(date: .omitted, time: .shortened))"
        if let sw = o.switchTo, let at = o.switchAt {
            t += "; Rwy \(sw) better after \(at.formatted(date: .omitted, time: .shortened))"
        }
        return t + "."
    }

    /// Density altitude belongs where the takeoff decision is made.
    private var daCallout: String? {
        guard let c = combined.conditions, let da = c.densityAltitudeFt,
              let field = c.fieldElevationFt, da - field >= 1500 else { return nil }
        return "Density altitude \(da.formatted()) ft (field \(field.formatted()) ft)."
    }

    var body: some View {
        let list = winds
        if let best = list.first {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label {
                        Text("Runway winds")
                    } icon: {
                        RunwayIcon()
                            .frame(height: 15)
                            .foregroundStyle(.blue)
                    }
                    .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("Rwy \(best.ident)")
                        .font(.title3.weight(.semibold))
                }
                Text(sentence(best))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let o = outlook(best: best, now: Date()) {
                    Text(outlookText(o))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let da = daCallout {
                    Text(da)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if expanded, list.count > 1 {
                    Divider()
                    ForEach(list.dropFirst()) { w in
                        HStack {
                            Text("Rwy \(w.ident)")
                                .font(.subheadline.weight(.medium))
                                .frame(width: 84, alignment: .leading)
                            Text(compact(w))
                                .font(.subheadline)
                                .foregroundStyle(w.isTailwind ? .orange : .secondary)
                            Spacer()
                        }
                    }
                }
                if list.count > 1 {
                    Button(expanded ? "Fewer runways" : "All runways") {
                        withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                    }
                    .font(.caption.weight(.medium))
                }
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// "9 kt crosswind from the left, 12 kt headwind. Gusts push it to 14 kt."
    private func sentence(_ w: RunwayWind) -> String {
        let x = Int(abs(w.crosswind).rounded())
        let h = Int(abs(w.headwind).rounded())
        var parts: [String] = []
        if x == 0 {
            parts.append("Straight down the runway")
        } else {
            parts.append("\(x) kt crosswind from the \(w.crosswind > 0 ? "right" : "left")")
        }
        parts.append(h == 0 ? "no head or tail component" : "\(h) kt \(w.isTailwind ? "tailwind" : "headwind")")
        var text = parts.joined(separator: ", ") + "."
        if let g = w.gustCrosswind, Int(abs(g).rounded()) > x {
            text += " Gusts push the crosswind to \(Int(abs(g).rounded())) kt."
        }
        return text
    }

    private func compact(_ w: RunwayWind) -> String {
        let x = Int(abs(w.crosswind).rounded())
        let h = Int(abs(w.headwind).rounded())
        let side = w.crosswind > 0 ? "R" : "L"
        return "\(x) kt x-wind \(x > 0 ? side : "") · \(h) kt \(w.isTailwind ? "tail" : "head")"
            .replacingOccurrences(of: "  ", with: " ")
    }
}
