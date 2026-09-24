//  StationLayer.swift
//  Barry — iOS
//
//  Reporting stations on the radar, two ways: the classic METAR wind barb
//  (staff toward where the wind comes from; pennant 50 kt, full barb 10, half
//  barb 5, a circle for calm) or a plain speed label. Knots throughout — it's
//  the aviation convention the barbs are defined in.

import MapKit
import SwiftUI
import UIKit

enum StationLayerStyle: String {
    case off, barbs, speeds
}

extension FlightCategory {
    /// The map's barbs draw with UIKit.
    static func uiColor(_ cat: String?) -> UIColor {
        cat.map(order.contains) == true ? UIColor(color(cat)) : .label
    }
}

final class StationAnnotation: MKPointAnnotation {
    var obs = StationObs(id: "", lat: 0, lon: 0)
    /// The home station drawn in place of the pin ("you are here").
    var isHome = false
}

/// How the map marks the home station. `asBarb` when the selection is an
/// airport or the user is within 3 NM of the station: the station's own
/// barb with a halo replaces the pin, and tapping it opens its METAR.
struct HomeMarker: Equatable {
    let obs: StationObs
    let asBarb: Bool
}

/// Bolt colors by how close the lightning is: at the field, close by, distant.
enum LightningInk {
    static func uiColor(_ status: String) -> UIColor {
        switch status {
        case "thunderstorm": return .systemRed
        case "vicinity": return .systemOrange
        default: return UIColor(red: 0.85, green: 0.65, blue: 0.0, alpha: 1)
        }
    }

    static func color(_ status: String) -> Color { Color(uiColor: uiColor(status)) }

    /// A small bolt image view, hidden until a station reports lightning.
    static func makeBadge() -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.isHidden = true
        v.isUserInteractionEnabled = false
        return v
    }

    static func apply(_ lt: LightningOut?, to badge: UIImageView) {
        guard let lt else { badge.isHidden = true; return }
        let cfg = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        badge.image = UIImage(systemName: lt.status == "distant" ? "bolt" : "bolt.fill",
                              withConfiguration: cfg)?
            .withTintColor(uiColor(lt.status), renderingMode: .alwaysOriginal)
        badge.isHidden = false
    }
}

/// The blue "you are here" ring drawn behind the home station's glyph.
private func makeHalo(diameter: CGFloat) -> UIView {
    let v = UIView(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
    v.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.16)
    v.layer.cornerRadius = diameter / 2
    v.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.7).cgColor
    v.layer.borderWidth = 1.5
    v.isUserInteractionEnabled = false
    v.isHidden = true
    return v
}

// MARK: - Wind barb

/// Draws one barb. Barbs sit on the right of the staff as seen from the
/// station looking toward the wind's source — the Northern Hemisphere plot
/// convention every surface chart uses.
final class BarbGlyph: UIView {
    var knots: Double = 0
    var directionDeg: Double? = nil
    var ink: UIColor = .label

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let ink = ink.withAlphaComponent(0.92)
        ctx.setStrokeColor(ink.cgColor)
        ctx.setFillColor(ink.cgColor)
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Station dot
        ctx.fillEllipse(in: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5))

        let kt = knots.rounded()
        guard kt >= 3, let dir = directionDeg else {
            // Calm (or variable): the open circle.
            ctx.setLineWidth(1.2)
            ctx.strokeEllipse(in: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12))
            return
        }

        let rad = dir * .pi / 180
        let d = CGPoint(x: sin(rad), y: -cos(rad))          // toward the source
        let perp = CGPoint(x: -d.y, y: d.x)                  // right side of the staff
        let staff: CGFloat = 20
        let tip = CGPoint(x: c.x + d.x * staff, y: c.y + d.y * staff)
        ctx.beginPath()
        ctx.move(to: c)
        ctx.addLine(to: tip)
        ctx.strokePath()

        // Decompose speed (rounded to 5) into pennants / full / half barbs.
        var remaining = Int((kt / 5).rounded()) * 5
        let pennants = remaining / 50; remaining -= pennants * 50
        let fulls = remaining / 10;    remaining -= fulls * 10
        let half = remaining >= 5

        var along: CGFloat = staff                             // walk in from the tip
        let step: CGFloat = 4.2
        func at(_ s: CGFloat) -> CGPoint { CGPoint(x: c.x + d.x * s, y: c.y + d.y * s) }
        func out(_ p: CGPoint, _ len: CGFloat) -> CGPoint {
            // Barbs lean back toward the tip a little, like the real thing.
            CGPoint(x: p.x + perp.x * len + d.x * len * 0.35,
                    y: p.y + perp.y * len + d.y * len * 0.35)
        }
        for _ in 0..<pennants {
            let base = at(along), inner = at(along - 5)
            ctx.beginPath()
            ctx.move(to: base)
            ctx.addLine(to: out(inner, 8))
            ctx.addLine(to: inner)
            ctx.closePath()
            ctx.fillPath()
            along -= 6
        }
        for _ in 0..<fulls {
            let p = at(along)
            ctx.beginPath(); ctx.move(to: p); ctx.addLine(to: out(p, 8)); ctx.strokePath()
            along -= step
        }
        if half {
            // A lone half barb sits one step in from the tip so it can't be
            // mistaken for a full one that got cut off.
            if pennants == 0 && fulls == 0 { along -= step }
            let p = at(along)
            ctx.beginPath(); ctx.move(to: p); ctx.addLine(to: out(p, 4.5)); ctx.strokePath()
        }
    }
}

final class WindBarbView: MKAnnotationView {
    private let glyph = BarbGlyph(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
    private let idLabel = UILabel()
    private let halo = makeHalo(diameter: 34)
    private let bolt = LightningInk.makeBadge()
    private var isHome = false

    /// Station ids only past a zoom threshold (the map declutter rule);
    /// the home station always keeps its name.
    var showsID = true { didSet { idLabel.isHidden = !(showsID || isHome) } }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        halo.center = CGPoint(x: 13, y: 13)
        addSubview(halo)
        // The view's bounds double as its collision footprint: MapKit hides an
        // annotation whenever its frame overlaps another's. A 50x58 box
        // collided constantly and barbs blinked out on every zoom, so the
        // bounds are just the dot area (the glyph and label overflow, which
        // MKAnnotationView doesn't clip) and collisions use the inscribed circle.
        bounds = CGRect(x: 0, y: 0, width: 26, height: 26)
        glyph.center = CGPoint(x: 13, y: 13)
        idLabel.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
        idLabel.textColor = .secondaryLabel
        idLabel.textAlignment = .center
        idLabel.frame = CGRect(x: -17, y: 34, width: 60, height: 11)
        addSubview(glyph)
        addSubview(idLabel)
        bolt.frame = CGRect(x: 18, y: -14, width: 14, height: 14)
        addSubview(bolt)
        isEnabled = true        // tappable: opens the station detail sheet
        displayPriority = .defaultHigh
        collisionMode = .circle
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(_ a: StationAnnotation) {
        glyph.knots = a.obs.windKt ?? 0
        glyph.directionDeg = a.obs.windDir
        glyph.ink = a.obs.isBuoy ? .systemTeal : FlightCategory.uiColor(a.obs.fltCat)
        glyph.setNeedsDisplay()
        idLabel.text = a.obs.id
        isHome = a.isHome
        idLabel.isHidden = !(showsID || a.isHome)
        LightningInk.apply(a.obs.lightning, to: bolt)
        halo.isHidden = !a.isHome
        idLabel.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: a.isHome ? .bold : .medium)
        // Home never loses a collision; it's the one station that must show.
        displayPriority = a.isHome ? .required : .defaultHigh
    }
}

// MARK: - Speed label

final class SpeedLabelView: MKAnnotationView {
    private let label = UILabel()
    private let idLabel = UILabel()
    private let halo = makeHalo(diameter: 30)
    private let bolt = LightningInk.makeBadge()
    private var isHome = false

    var showsID = true { didSet { idLabel.isHidden = !(showsID || isHome) } }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        addSubview(halo)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .label
        label.textAlignment = .center
        label.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.78)
        label.layer.cornerRadius = 5
        label.layer.masksToBounds = true
        idLabel.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
        idLabel.textColor = .secondaryLabel
        idLabel.textAlignment = .center
        addSubview(label)
        addSubview(idLabel)
        addSubview(bolt)
        isEnabled = true        // tappable: opens the station detail sheet
        // Speed labels rank below barbs and centers: a number that mostly
        // matches its neighbors shouldn't cover anything.
        displayPriority = .defaultLow
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(_ a: StationAnnotation) {
        let o = a.obs
        if let kt = o.windKt, kt >= 1 {
            var t = " \(Int(kt)) "
            if let g = o.gustKt { t = " \(Int(kt)) G \(Int(g)) " }
            label.text = t + "kt "
        } else {
            label.text = " calm "
        }
        // Flight category tints the label: VFR green, MVFR blue, IFR red,
        // LIFR magenta. No category (a station without ceiling/visibility)
        // stays neutral.
        let cat = o.isBuoy ? UIColor.systemTeal : FlightCategory.uiColor(o.fltCat)
        label.textColor = cat
        label.layer.borderColor = cat.withAlphaComponent(0.55).cgColor
        label.layer.borderWidth = 1
        label.sizeToFit()
        label.frame.size.height += 4
        label.frame.size.width += 2
        idLabel.text = o.id
        isHome = a.isHome
        idLabel.isHidden = !(showsID || a.isHome)
        // Bounds = the speed pill only (its collision footprint); the id label
        // hangs below, outside the bounds, and never causes a collision.
        bounds = CGRect(x: 0, y: 0, width: label.bounds.width, height: label.bounds.height)
        label.frame.origin = .zero
        idLabel.frame = CGRect(x: (bounds.width - 60) / 2, y: bounds.height + 1, width: 60, height: 11)
        bolt.frame = CGRect(x: bounds.width + 1, y: (bounds.height - 12) / 2, width: 12, height: 12)
        LightningInk.apply(o.lightning, to: bolt)
        centerOffset = CGPoint(x: 0, y: -bounds.height / 2 - 4)
        // The ring sits on the station point itself (below the pill).
        halo.center = CGPoint(x: bounds.width / 2, y: bounds.height + 4 + bounds.height / 2)
        halo.isHidden = !a.isHome
        displayPriority = a.isHome ? .required : .defaultLow
    }
}

// MARK: - Storm marker (the Storms overlay with the station layer off)

final class LightningAnnotation: MKPointAnnotation {
    var obs = StationObs(id: "", lat: 0, lon: 0)
}

/// A bolt with the station id under it: where lightning is being reported
/// right now. Tappable, like a station.
final class LightningMarkerView: MKAnnotationView {
    private let bolt = UIImageView()
    private let idLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
        bolt.frame = bounds
        bolt.contentMode = .scaleAspectFit
        idLabel.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
        idLabel.textColor = .secondaryLabel
        idLabel.textAlignment = .center
        idLabel.frame = CGRect(x: -19, y: 22, width: 60, height: 11)
        addSubview(bolt)
        addSubview(idLabel)
        isEnabled = true
        displayPriority = .defaultHigh
        collisionMode = .circle
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(_ a: LightningAnnotation) {
        guard let lt = a.obs.lightning else { return }
        let cfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        bolt.image = UIImage(systemName: lt.status == "distant" ? "bolt" : "bolt.fill",
                             withConfiguration: cfg)?
            .withTintColor(LightningInk.uiColor(lt.status), renderingMode: .alwaysOriginal)
        idLabel.text = a.obs.id
    }
}

// MARK: - Detail sheet

/// What you get when you tap a station on the radar: the report decoded, and
/// the METAR itself underneath for anyone who reads them raw.
struct StationDetailSheet: View {
    let obs: StationObs
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(obs.id)
                    .font(.title2.weight(.semibold))
                if let cat = obs.fltCat {
                    Text(cat)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FlightCategory.color(cat))
                }
                Spacer()
                if let t = obs.obsTime {
                    Text(age(t))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if obs.isBuoy {
                Text("NOAA buoy or coastal station")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, -10)
            } else if let name = obs.name {
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, -10)
            }

            if obs.fltCatDerived == true, let cat = obs.fltCat {
                Text("\(obs.id) reports no flight category. \(cat) is derived from ceiling and visibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let lt = obs.lightning {
                Label(lt.sentence, systemImage: lt.status == "distant" ? "bolt" : "bolt.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LightningInk.color(lt.status))
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 10) {
                fact("Wind", windText, icon: "wind")
                if obs.isBuoy {
                    fact("Waves", waveText, icon: "water.waves")
                    fact("Pressure", buoyPressureText, icon: "barometer")
                    fact("Air / dew", tempText, icon: "thermometer.medium")
                    if let w = obs.waterTempC {
                        fact("Water", TemperatureUnit.current.formatWithUnit(w), icon: "drop")
                    }
                } else {
                    fact("Visibility", visText, icon: "eye")
                    fact("Ceiling", ceilingText, icon: "cloud")
                    fact("Temp / dew", tempText, icon: "thermometer.medium")
                    fact("Altimeter", altimText, icon: "barometer")
                    if let wx = obs.wx {
                        fact("Weather", wx, icon: "cloud.rain")
                    }
                }
            }

            if let raw = obs.raw {
                Text(raw)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func fact(_ label: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.medium))
        }
    }

    private var windText: String {
        guard let kt = obs.windKt, kt >= 1 else { return "Calm" }
        let dir = obs.windDir.map { String(format: "%03d°", Int($0.rounded())) } ?? "Variable"
        var t = "\(dir) at \(Int(kt)) kt"
        if let g = obs.gustKt { t += ", gusts \(Int(g))" }
        return t
    }

    private var visText: String {
        guard let v = obs.visibilitySM else { return "Not reported" }
        if v >= 10 { return "10+ mi" }
        return v == v.rounded() ? "\(Int(v)) mi" : String(format: "%.1f mi", v)
    }

    private var ceilingText: String {
        if let ft = obs.ceilingFt {
            return "\(obs.ceilingCover ?? "") \(ft.formatted()) ft".trimmingCharacters(in: .whitespaces)
        }
        switch obs.ceilingCover {
        case nil: return "Not reported"
        case "CLR", "SKC": return "Clear"
        case let c?: return "\(c), no ceiling"
        }
    }

    private var tempText: String {
        guard let t = obs.temp else { return "Not reported" }
        let unit = TemperatureUnit.current
        let d = obs.dewpoint.map { " / \(unit.format($0))" } ?? ""
        return "\(unit.format(t))\(d) \(unit.label.dropFirst())"
    }

    /// "4 ft every 6 s", the significant height and dominant period.
    private var waveText: String {
        guard let ft = obs.waveFt else { return "Not reported" }
        let h = ft < 10 ? String(format: "%.1f ft", ft) : "\(Int(ft.rounded())) ft"
        return obs.wavePeriodS.map { "\(h) every \(Int($0)) s" } ?? h
    }

    /// Sea-level pressure in the chosen unit, with the buoy's own 3 h change
    /// when it sent one.
    private var buoyPressureText: String {
        guard let hPa = obs.slp else { return "Not reported" }
        let unit = PressureUnit(rawValue: AppConfig.sharedDefaults.string(forKey: "pressureUnit") ?? "") ?? .inHg
        var t = "\(unit.format(hPa)) \(unit.label)"
        if let d = obs.presTend { t += ", \(unit.formatDeltaBare(d)) in 3 h" }
        return t
    }

    private var altimText: String {
        guard let hPa = obs.altim else { return "Not reported" }
        return String(format: "%.2f inHg", hPa / 33.8639)
    }

    private func age(_ t: Date) -> String {
        let m = Int(now.timeIntervalSince(t) / 60)
        if m < 1 { return "just now" }
        if m < 60 { return "\(m)m ago" }
        return "\(m / 60)h \(m % 60)m ago"
    }
}
