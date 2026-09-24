//  RouteViews.swift
//  Barry — iOS
//
//  A route from one field to another (docs/ROUTES.md, section 2): the card
//  on the main page, the screen behind it, and the sheet that plans one.
//  Still air, a straight line, a 15 NM corridor; the screen says so once.

import MapKit
import SwiftUI

/// The route the user set, kept in the shared store: from, to, recent pairs.
enum RouteSettings {
    static let fromKey = "route.from"
    static let toKey = "route.to"
    static let recentKey = "route.recent"
    static let speedKey = "cruiseSpeedKt"

    static func set(from: String, to: String) {
        let d = AppConfig.sharedDefaults
        let a = from.uppercased(), b = to.uppercased()
        d.set(a, forKey: fromKey)
        d.set(b, forKey: toKey)
        var recent = (d.string(forKey: recentKey) ?? "").split(separator: ",").map(String.init)
        recent.removeAll { $0 == "\(a)>\(b)" }
        recent.insert("\(a)>\(b)", at: 0)
        d.set(recent.prefix(5).joined(separator: ","), forKey: recentKey)
    }

    static func clear() {
        AppConfig.sharedDefaults.set("", forKey: fromKey)
        AppConfig.sharedDefaults.set("", forKey: toKey)
    }

    static var recent: [(String, String)] {
        (AppConfig.sharedDefaults.string(forKey: recentKey) ?? "").split(separator: ",").compactMap {
            let p = $0.split(separator: ">").map(String.init)
            return p.count == 2 ? (p[0], p[1]) : nil
        }
    }
}

/// Words the card and the screen share.
enum RouteWords {
    static func wind(_ kt: Double?, _ dir: Double?, _ gust: Double?) -> String {
        guard let kt, kt >= 1 else { return "calm" }
        let d = dir.map { String(format: "%03d", Int($0.rounded()) == 0 ? 360 : Int($0.rounded())) } ?? "VRB"
        var t = "\(d)@\(Int(kt.rounded()))"
        if let g = gust, g >= kt + 3 { t += "G\(Int(g.rounded()))" }
        return t
    }

    static func duration(_ min: Int) -> String {
        min < 60 ? "\(min) min" : "\(min / 60) h \(min % 60) min"
    }

    /// "52 min before sunset", "20 min after sunset", or nothing.
    static func sunset(_ m: Int?) -> String? {
        guard let m else { return nil }
        if m < 0 { return "\(-m) min before sunset" }
        return m == 0 ? "at sunset" : "\(m) min after sunset"
    }

    /// The middle line: the worst category on the way, lightning near the
    /// line, fronts crossing it.
    static func enroute(_ r: RouteResponse) -> String {
        var parts: [String] = []
        if let w = r.worst, let cat = w.fltCat, cat != "VFR" {
            parts.append("\(cat) at \(w.id)")
        } else if !r.corridor.isEmpty {
            parts.append("VFR along the line")
        } else {
            parts.append("no stations along the line")
        }
        if let l = r.lightning {
            parts.append(l.offNm < 3 ? "lightning on the line" : "lightning \(Int(l.offNm.rounded())) NM off the line")
        }
        if let f = r.fronts.first {
            let name = ["cold": "cold front", "warm": "warm front", "stnry": "stationary front",
                        "ocfnt": "occluded front", "trof": "trough"][f.type] ?? "front"
            parts.append("\(name) at \(Int(f.alongNm.rounded())) NM")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Card

struct RouteCard: View {
    let from: String
    let to: String
    let speedKt: Int
    let unit: PressureUnit
    let reloadToken: Date?
    @State private var route: RouteResponse?
    @State private var failed = false

    private var key: String { "\(from)>\(to)@\(speedKt)|\(reloadToken?.timeIntervalSince1970 ?? 0)" }

    var body: some View {
        NavigationLink {
            RouteScreen(from: from, to: to, speedKt: speedKt, unit: unit)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(from) → \(to)")
                        .font(.subheadline.weight(.semibold).monospaced())
                    Spacer()
                    if let r = route {
                        Text("\(Int(r.distanceNm.rounded())) NM · \(RouteWords.duration(r.eteMin))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                if let r = route {
                    endRow("Depart", r.dep, extra: nil)
                    Text(RouteWords.enroute(r))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    arriveRow(r)
                } else if failed {
                    Text("Couldn't work this route out. One of the fields may not report.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .task(id: key) { await load() }
    }

    private func load() async {
        let tz = TimeZone.current.secondsFromGMT() / 60
        if let r = try? await BarryAPI().route(from: from, to: to, speedKt: speedKt, tzMinutes: tz) {
            route = r
            failed = false
        } else {
            failed = route == nil
        }
    }

    private func endRow(_ label: String, _ g: GlanceItem, extra: String?) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            if let cat = g.fltCat {
                Text(cat).font(.caption.weight(.semibold)).foregroundStyle(FlightCategory.color(cat))
            }
            Text(RouteWords.wind(g.windKt, g.windDir, g.gustKt)).font(.caption.monospaced())
            if let hPa = g.altim ?? g.slp {
                Text(unit.format(hPa)).font(.caption.monospacedDigit())
            }
            Spacer(minLength: 0)
        }
    }

    private func arriveRow(_ r: RouteResponse) -> some View {
        HStack(spacing: 8) {
            Text("Arrive").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(r.arriveAt.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit())
            if let cat = r.arriveCat {
                Text(cat).font(.caption.weight(.semibold)).foregroundStyle(FlightCategory.color(cat))
            } else if let cat = r.dest.fltCat {
                Text("\(cat) now").font(.caption).foregroundStyle(FlightCategory.color(cat))
            }
            if let t = r.arriveTempo { Text(t).font(.caption).foregroundStyle(.orange) }
            if let s = RouteWords.sunset(r.sunsetMin) {
                Text(s).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Screen

struct RouteScreen: View {
    let from: String
    let to: String
    let speedKt: Int
    let unit: PressureUnit
    @Environment(\.dismiss) private var dismiss
    @State private var route: RouteResponse?

    var body: some View {
        List {
            if let r = route {
                Section {
                    map(r)
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    row(r.dep.station, "0 NM", r.dep.fltCat, RouteWords.wind(r.dep.windKt, r.dep.windDir, r.dep.gustKt))
                    ForEach(r.corridor, id: \.id) { s in
                        row(s.id, "\(Int(s.alongNm.rounded())) NM", s.fltCat, RouteWords.wind(s.windKt, s.windDir, s.gustKt),
                            bolt: s.lightning)
                    }
                    row(r.dest.station, "\(Int(r.distanceNm.rounded())) NM", r.arriveCat ?? r.dest.fltCat,
                        RouteWords.wind(r.dest.windKt, r.dest.windDir, r.dest.gustKt))
                } footer: {
                    Text("\(Int(r.distanceNm.rounded())) NM at \(speedKt) kt in still air, arriving \(r.arriveAt.formatted(date: .omitted, time: .shortened)). Stations within \(Int(r.corridorNm)) NM of a straight line; not an airway.")
                }
                Section {
                    Button("Reverse") { RouteSettings.set(from: to, to: from); dismiss() }
                    Button("Clear route", role: .destructive) { RouteSettings.clear(); dismiss() }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("\(from) → \(to)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            route = try? await BarryAPI().route(from: from, to: to, speedKt: speedKt,
                                                tzMinutes: TimeZone.current.secondsFromGMT() / 60)
        }
    }

    private func row(_ id: String, _ along: String, _ cat: String?, _ wind: String, bolt: Bool = false) -> some View {
        HStack(spacing: 10) {
            Circle().fill(cat.map(FlightCategory.color) ?? Color(.tertiaryLabel)).frame(width: 8, height: 8)
            Text(id).font(.subheadline.weight(.semibold).monospaced())
            Text(along).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            if bolt { Image(systemName: "bolt.fill").foregroundStyle(.orange).font(.caption) }
            Text(wind).font(.subheadline.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func map(_ r: RouteResponse) -> some View {
        let a = CLLocationCoordinate2D(latitude: r.depLat, longitude: r.depLon)
        let b = CLLocationCoordinate2D(latitude: r.destLat, longitude: r.destLon)
        return Map(initialPosition: .rect(MKPolyline(coordinates: [a, b], count: 2).boundingMapRect
                    .insetBy(dx: -max(20_000, abs(MKMapPoint(a).x - MKMapPoint(b).x) * 0.25),
                             dy: -max(20_000, abs(MKMapPoint(a).y - MKMapPoint(b).y) * 0.25)))) {
            MapPolyline(coordinates: [a, b], contourStyle: .geodesic)
                .stroke(.blue, lineWidth: 3)
            ForEach(r.corridor, id: \.id) { s in
                Annotation(s.id, coordinate: CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)) {
                    Circle().fill(s.fltCat.map(FlightCategory.color) ?? .gray).frame(width: 9, height: 9)
                }
            }
            Marker(r.dep.station, coordinate: a).tint(.blue)
            Marker(r.dest.station, coordinate: b).tint(.blue)
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
    }
}

// MARK: - Planner

struct RoutePlannerSheet: View {
    let current: String
    let savedAirports: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var from = ""
    @State private var to = ""

    private var valid: Bool {
        let ok = { (s: String) in s.count >= 3 && s.count <= 4 && s.allSatisfy { $0.isLetter || $0.isNumber } }
        return ok(from) && ok(to) && from.uppercased() != to.uppercased()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("From", text: $from)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    TextField("To", text: $to)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                }
                let picks = savedAirports.filter { $0.uppercased() != from.uppercased() }
                if !picks.isEmpty {
                    Section("Saved fields") {
                        ForEach(picks, id: \.self) { icao in
                            Button(icao) { to = icao }
                        }
                    }
                }
                let recent = RouteSettings.recent
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(Array(recent.enumerated()), id: \.offset) { _, pair in
                            Button("\(pair.0) → \(pair.1)") { from = pair.0; to = pair.1 }
                        }
                    }
                }
            }
            .navigationTitle("Plan a route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Show") {
                        RouteSettings.set(from: from, to: to)
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
            .onAppear { if from.isEmpty { from = current } }
        }
    }
}
