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
