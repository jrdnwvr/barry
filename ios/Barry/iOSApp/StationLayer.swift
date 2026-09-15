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

/// Standard aviation flight-category colors, shared by the METAR readout on
/// the main page and the station layer on the radar. Nil or unknown category
/// falls back to the plain label color.
enum FlightCategory {
    static let order = ["VFR", "MVFR", "IFR", "LIFR"]

    static func uiColor(_ cat: String?) -> UIColor {
        switch cat {
        case "VFR":  return UIColor(red: 0.13, green: 0.62, blue: 0.28, alpha: 1)
        case "MVFR": return UIColor(red: 0.20, green: 0.48, blue: 0.85, alpha: 1)
        case "IFR":  return UIColor(red: 0.85, green: 0.22, blue: 0.18, alpha: 1)
        case "LIFR": return UIColor(red: 0.72, green: 0.20, blue: 0.70, alpha: 1)
        default:     return .label
        }
    }

    static func color(_ cat: String?) -> Color {
        cat.map(order.contains) == true ? Color(uiColor: uiColor(cat)) : .secondary
    }
}

final class StationAnnotation: MKPointAnnotation {
    var obs = StationObs(id: "", lat: 0, lon: 0)
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

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        bounds = CGRect(x: 0, y: 0, width: 50, height: 58)
        glyph.frame.origin = .zero
        idLabel.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
        idLabel.textColor = .secondaryLabel
        idLabel.textAlignment = .center
        idLabel.frame = CGRect(x: -5, y: 46, width: 60, height: 11)
        addSubview(glyph)
        addSubview(idLabel)
        isEnabled = false
        displayPriority = .defaultHigh
        centerOffset = CGPoint(x: 0, y: -4)   // station dot sits on the coordinate
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(_ a: StationAnnotation) {
        glyph.knots = a.obs.windKt ?? 0
        glyph.directionDeg = a.obs.windDir
        glyph.ink = FlightCategory.uiColor(a.obs.fltCat)
        glyph.setNeedsDisplay()
        idLabel.text = a.obs.id
    }
}

// MARK: - Speed label

final class SpeedLabelView: MKAnnotationView {
    private let label = UILabel()
    private let idLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
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
        isEnabled = false
        displayPriority = .defaultHigh
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
        let cat = FlightCategory.uiColor(o.fltCat)
        label.textColor = cat
        label.layer.borderColor = cat.withAlphaComponent(0.55).cgColor
        label.layer.borderWidth = 1
        label.sizeToFit()
        label.frame.size.height += 4
        label.frame.size.width += 2
        idLabel.text = o.id
        idLabel.frame = CGRect(x: 0, y: label.bounds.height + 1, width: max(label.bounds.width, 40), height: 11)
        bounds = CGRect(x: 0, y: 0, width: max(label.bounds.width, 40), height: label.bounds.height + 12)
        label.frame.origin = CGPoint(x: (bounds.width - label.bounds.width) / 2, y: 0)
        centerOffset = CGPoint(x: 0, y: -bounds.height / 2 - 4)
    }
}
