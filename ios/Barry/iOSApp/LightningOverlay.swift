//  LightningOverlay.swift
//  Barry — iOS
//
//  Flashes seen from orbit (GOES lightning mapper, via the backend's
//  /lightning slice) as dots on the radar. The palette is one the radar
//  never uses (RainViewer's rain runs blue to orange): a white core with a
//  dark halo when new, aging through lavender to a dim violet over the 20
//  minute window, sized by how many flashes fell in the cell. New cells
//  arrive with a short expanding ring. One world-sized overlay; the
//  renderer culls to the tile it is asked for.

import MapKit
import UIKit

struct LightningState: Equatable {
    var response: LightningResponse?
    var version = 0
    /// When this slice landed; drives the arrival pulse on new cells.
    var receivedAt: Date = .distantPast
}

final class LightningOverlay: NSObject, MKOverlay {
    var state = LightningState()
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: 0, longitude: 0) }
    var boundingMapRect: MKMapRect { .world }
}

final class LightningRenderer: MKOverlayRenderer {
    /// Cells younger than this when a slice lands are "new" and pulse.
    static let newCellAgeSec = 75
    /// How long the arrival ring runs.
    static let pulseDuration: TimeInterval = 1.0

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        guard let overlay = overlay as? LightningOverlay, let resp = overlay.state.response else { return }
        let scale = 1 / zoomScale
        let visible = mapRect.insetBy(dx: -60 * scale, dy: -60 * scale)
        let window = Double(max(60, resp.windowSec))
        let pulseT = Date().timeIntervalSince(overlay.state.receivedAt) / Self.pulseDuration
        // Oldest first so the fresh ones paint on top.
        for cell in resp.cells.sorted(by: { $0.ageSec > $1.ageSec }) {
            let p = MKMapPoint(CLLocationCoordinate2D(latitude: cell.lat, longitude: cell.lon))
            guard visible.contains(p) else { continue }
            let age = min(1.0, Double(cell.ageSec) / window)
            let r = min(6.0, 2.4 + 1.0 * log2(Double(max(1, cell.count)))) * scale
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            let (color, alpha) = Self.ink(age: age)
            // Dark halo so the dot stays readable on rain of any color.
            ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.55 * alpha).cgColor)
            ctx.setLineWidth(1.4 * scale)
            ctx.strokeEllipse(in: rect.insetBy(dx: -0.7 * scale, dy: -0.7 * scale))
            ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
            ctx.fillEllipse(in: rect)
            if age < 0.1 {
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fillEllipse(in: rect.insetBy(dx: r * 0.4, dy: r * 0.4))
            }
            // Arrival: an expanding, fading ring on cells new to this slice.
            if cell.ageSec <= Self.newCellAgeSec, pulseT >= 0, pulseT < 1 {
                let ring = r * (1.2 + 3.2 * pulseT)
                ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.9 * (1 - pulseT)).cgColor)
                ctx.setLineWidth(1.6 * scale)
                ctx.strokeEllipse(in: CGRect(x: p.x - ring, y: p.y - ring, width: 2 * ring, height: 2 * ring))
            }
        }
    }

    /// White when seconds old, lavender in the first minutes, violet by
    /// mid-window, a dim purple at the end. Nothing the radar paints.
    static func ink(age: Double) -> (UIColor, CGFloat) {
        switch age {
        case ..<0.1:  return (UIColor.white, 1.0)
        case ..<0.35: return (UIColor(red: 0.90, green: 0.82, blue: 1.0, alpha: 1), 0.95)
        case ..<0.7:  return (UIColor(red: 0.68, green: 0.42, blue: 0.95, alpha: 1), 0.85)
        default:      return (UIColor(red: 0.45, green: 0.25, blue: 0.70, alpha: 1), 0.55)
        }
    }
}
