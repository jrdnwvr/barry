//  LightningOverlay.swift
//  Barry — iOS
//
//  Flashes seen from orbit (GOES lightning mapper, via the backend's
//  /lightning slice) as dots on the radar: newest white-hot, aging through
//  yellow and orange to a dim red over the 15 minute window, sized by how
//  many flashes fell in the cell. One world-sized overlay; the renderer
//  culls to the tile it is asked for.

import MapKit
import UIKit

struct LightningState: Equatable {
    var response: LightningResponse?
    var version = 0
}

final class LightningOverlay: NSObject, MKOverlay {
    var state = LightningState()
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: 0, longitude: 0) }
    var boundingMapRect: MKMapRect { .world }
}

final class LightningRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        guard let overlay = overlay as? LightningOverlay, let resp = overlay.state.response else { return }
        let scale = 1 / zoomScale
        let visible = mapRect.insetBy(dx: -40 * scale, dy: -40 * scale)
        let window = Double(max(60, resp.windowSec))
        // Oldest first so the fresh ones paint on top.
        for cell in resp.cells.sorted(by: { $0.ageSec > $1.ageSec }) {
            let p = MKMapPoint(CLLocationCoordinate2D(latitude: cell.lat, longitude: cell.lon))
            guard visible.contains(p) else { continue }
            let age = min(1.0, Double(cell.ageSec) / window)
            let r = (2.6 + 1.1 * log2(Double(max(1, cell.count)))) * scale
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            let (color, alpha) = Self.ink(age: age)
            // A soft halo, then the dot.
            ctx.setFillColor(color.withAlphaComponent(alpha * 0.25).cgColor)
            ctx.fillEllipse(in: rect.insetBy(dx: -r * 0.9, dy: -r * 0.9))
            ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
            ctx.fillEllipse(in: rect)
            if age < 0.15 {
                ctx.setFillColor(UIColor.white.withAlphaComponent(0.9).cgColor)
                ctx.fillEllipse(in: rect.insetBy(dx: r * 0.45, dy: r * 0.45))
            }
        }
    }

    /// White-yellow when seconds old, orange by mid-window, dim red at the end.
    static func ink(age: Double) -> (UIColor, CGFloat) {
        switch age {
        case ..<0.15: return (UIColor(red: 1.0, green: 0.95, blue: 0.55, alpha: 1), 1.0)
        case ..<0.4:  return (UIColor(red: 1.0, green: 0.80, blue: 0.20, alpha: 1), 0.95)
        case ..<0.7:  return (UIColor(red: 1.0, green: 0.55, blue: 0.10, alpha: 1), 0.85)
        default:      return (UIColor(red: 0.85, green: 0.25, blue: 0.15, alpha: 1), 0.6)
        }
    }
}
