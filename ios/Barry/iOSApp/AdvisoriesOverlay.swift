//  AdvisoriesOverlay.swift
//  Barry — iOS
//
//  The radar's Advisories layer: SIGMET and G-AIRMET areas outlined in their
//  hazard's colour with a short label you can tap, and pilot reports of
//  turbulence and icing as small symbols coloured by intensity. Data from
//  /advisories (the Aviation Weather Center's feeds, pulled by the server).

import MapKit
import SwiftUI

enum AdvisoryInk {
    static func color(_ a: AdvisoryArea) -> UIColor {
        switch a.hazard {
        case "CONVECTIVE": return .systemRed
        case "IFR": return .systemPurple
        case "MT_OBSC": return .systemPink
        case "TURB", "TURB-HI", "TURB-LO", "LLWS": return .systemBrown
        case "ICE": return .systemBlue
        case "SFC_WND": return .systemOrange
        default: return a.kind == "sigmet" ? .systemOrange : .systemGray
        }
    }

    /// NEG grey, light amber, moderate orange, severe red.
    static func intensity(_ s: String?) -> UIColor {
        guard let s else { return .systemGray }
        if s.contains("SEV") || s.contains("EXTM") { return .systemRed }
        if s.contains("MOD") { return .systemOrange }
        if s.contains("LGT") || s.contains("TRC") { return .systemYellow }
        return .systemGray
    }

    /// "SFC to 12,000 ft", "Up to FL430", "" when the bulletin gives none.
    static func heights(_ a: AdvisoryArea) -> String {
        let ft = { (v: Int) -> String in v >= 18_000 ? "FL\(v / 100)" : (v == 0 ? "SFC" : "\(v.formatted()) ft") }
        switch (a.baseFt, a.topFt) {
        case let (b?, t?): return "\(ft(b)) to \(ft(t))"
        case let (nil, t?): return "Up to \(ft(t))"
        case let (b?, nil): return "From \(ft(b))"
        default: return ""
        }
    }

    /// The word on the map: "Conv", "IFR", "Turb", "Ice".
    static func short(_ a: AdvisoryArea) -> String {
        if a.kind == "convective" { return "Conv" }
        return a.label.replacingOccurrences(of: "AIRMET ", with: "").replacingOccurrences(of: "SIGMET ", with: "")
    }
}

final class AdvisoryPolygon: MKPolygon {
    var area: AdvisoryArea!
}

final class AdvisoryLabelAnnotation: MKPointAnnotation {
    var area: AdvisoryArea!
}

final class PirepAnnotation: MKPointAnnotation {
    var pirep: PirepOut!
}

extension AdvisoryPolygon {
    static func make(_ a: AdvisoryArea) -> AdvisoryPolygon {
        var coords = a.points.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
        let p = AdvisoryPolygon(coordinates: &coords, count: coords.count)
        p.area = a
        return p
    }
}

enum AdvisoryRenderers {
    static func renderer(_ p: AdvisoryPolygon) -> MKOverlayRenderer {
        let r = MKPolygonRenderer(polygon: p)
        let ink = AdvisoryInk.color(p.area)
        r.strokeColor = ink.withAlphaComponent(0.85)
        r.fillColor = ink.withAlphaComponent(p.area.kind == "airmet" ? 0.06 : 0.12)
        r.lineWidth = p.area.kind == "airmet" ? 1.2 : 1.8
        if p.area.kind == "airmet" { r.lineDashPattern = [6, 4] }
        return r
    }
}

/// The area's short word in its colour, at the outline's middle; tap for the
/// whole advisory.
final class AdvisoryLabelView: MKAnnotationView {
    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textAlignment = .center
        label.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.8)
        label.layer.cornerRadius = 4
        label.layer.masksToBounds = true
        addSubview(label)
        collisionMode = .rectangle
        displayPriority = .defaultHigh
        canShowCallout = false
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(_ a: AdvisoryLabelAnnotation) {
        label.text = " \(AdvisoryInk.short(a.area)) "
        label.textColor = AdvisoryInk.color(a.area)
        label.sizeToFit()
        label.frame.size.height += 2
        frame = label.bounds
        label.frame = bounds
    }
}

/// A turbulence or icing report: a small symbol in the intensity's colour.
final class PirepView: MKAnnotationView {
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .circle
        displayPriority = .defaultLow
        canShowCallout = false
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(_ a: PirepAnnotation) {
        let p = a.pirep!
        let icing = p.icing != nil && (p.turbulence == nil || p.turbulence == "NEG")
        let level = icing ? p.icing : p.turbulence
        let cfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        image = UIImage(systemName: icing ? "snowflake" : "water.waves", withConfiguration: cfg)?
            .withTintColor(AdvisoryInk.intensity(level), renderingMode: .alwaysOriginal)
        alpha = level == "NEG" ? 0.6 : 1
    }
}

/// What a tapped area or report says, with the bulletin underneath.
struct AdvisoryDetailSheet: View {
    enum Item: Identifiable {
        case area(AdvisoryArea)
        case pirep(PirepOut)
        var id: String {
            switch self {
            case .area(let a): return "a" + a.label + (a.validFrom?.description ?? "")
            case .pirep(let p): return "p" + p.raw
            }
        }
    }

    let item: Item
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch item {
            case .area(let a):
                Text(a.label).font(.title3.weight(.semibold))
                    .foregroundStyle(Color(uiColor: AdvisoryInk.color(a)))
                let h = AdvisoryInk.heights(a)
                if !h.isEmpty { Text(h).font(.subheadline) }
                if let to = a.validTo {
                    Text("Until \(to.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let raw = a.raw { rawText(raw) }
            case .pirep(let p):
                Text(pirepTitle(p)).font(.title3.weight(.semibold))
                    .foregroundStyle(Color(uiColor: AdvisoryInk.intensity(p.turbulence ?? p.icing)))
                Text([p.altFt.map { "\($0.formatted()) ft" }, p.aircraft, p.obsTime.map(age)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
                rawText(p.raw)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func pirepTitle(_ p: PirepOut) -> String {
        var parts: [String] = []
        if let t = p.turbulence { parts.append(t == "NEG" ? "Smooth" : "\(t.lowercased()) turbulence") }
        if let i = p.icing { parts.append(i == "NEG" ? "no ice" : "\(i.lowercased()) icing") }
        let s = parts.joined(separator: ", ")
        return (p.urgent ? "Urgent: " : "") + s.prefix(1).uppercased() + s.dropFirst()
    }

    private func rawText(_ s: String) -> some View {
        Text(s)
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func age(_ t: Date) -> String {
        let m = max(0, Int(now.timeIntervalSince(t) / 60))
        return m < 60 ? "\(m)m ago" : "\(m / 60)h \(m % 60)m ago"
    }
}
