//  FieldsCard.swift
//  Barry — iOS
//
//  Every saved airport on one line: category, wind, altimeter, trend, and
//  the start of its verdict. Tap a line to switch to that field. Shows only
//  with two or more airports saved (docs/ROUTES.md, section 1).

import SwiftUI

struct FieldsCard: View {
    struct Field: Identifiable, Equatable {
        let id: UUID
        let icao: String
    }

    let fields: [Field]
    let selectedID: UUID?
    let unit: PressureUnit
    /// Changes when the page reloads, so the lines refresh with it.
    let reloadToken: Date?
    let onSelect: (UUID) -> Void
    /// A long press on a line routes from the current field to that one.
    var onRouteTo: ((String) -> Void)? = nil

    @State private var items: [String: GlanceItem] = [:]

    private var loadKey: String {
        fields.map(\.icao).joined(separator: ",") + "|" + (reloadToken.map { "\($0.timeIntervalSince1970)" } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fields")
                .font(.subheadline.weight(.semibold))
            ForEach(fields) { f in
                Button { onSelect(f.id) } label: {
                    row(f, items[f.icao.uppercased()], selected: f.id == selectedID)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if let onRouteTo, f.id != selectedID {
                        Button("Route to \(f.icao)", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                            onRouteTo(f.icao)
                        }
                    }
                }
                .accessibilityIdentifier("fields.\(f.icao)")
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .task(id: loadKey) { await load() }
    }

    private func load() async {
        let ids = fields.map(\.icao).joined(separator: ",")
        let tz = TimeZone.current.secondsFromGMT() / 60
        guard let resp = try? await BarryAPI().glance(stations: ids, tzMinutes: tz) else { return }
        items = Dictionary(resp.items.map { ($0.station.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func row(_ f: Field, _ item: GlanceItem?, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(item?.fltCat.map(FlightCategory.color) ?? Color(.tertiaryLabel))
                    .frame(width: 8, height: 8)
                Text(f.icao)
                    .font(.subheadline.weight(.semibold).monospaced())
                if let w = item.map(windText) {
                    Text(w)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let hPa = item?.altim ?? item?.slp {
                    Text(unit.format(hPa))
                        .font(.subheadline.monospacedDigit())
                }
                if let cls = item?.cls {
                    Image(systemName: cls.symbolName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(cls.color(intensity: 0.6))
                        .frame(width: 16)
                }
            }
            if let v = item.map({ Self.firstSentence($0.verdict) }), !v.isEmpty {
                Text(v)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 16)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(selected ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    /// "240@8", "240@8G15", "VRB@3", "calm".
    private func windText(_ i: GlanceItem) -> String {
        guard let kt = i.windKt, kt >= 1 else { return "calm" }
        let dir = i.windDir.map { String(format: "%03d", Int($0.rounded()) == 0 ? 360 : Int($0.rounded())) } ?? "VRB"
        var t = "\(dir)@\(Int(kt.rounded()))"
        if let g = i.gustKt, g >= kt + 3 { t += "G\(Int(g.rounded()))" }
        return t
    }

    /// The verdict's first sentence, without its full stop.
    static func firstSentence(_ s: String) -> String {
        let first = s.components(separatedBy: ". ").first ?? s
        return first.hasSuffix(".") ? String(first.dropLast()) : first
    }
}
