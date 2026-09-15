//  HorizontalDragGesture.swift
//  Barry — iOS
//
//  A drag that only claims sideways movement. SwiftUI's DragGesture grabs the
//  touch in any direction once it passes its minimum distance, which is why a
//  swipe that started on the chart never scrolled the page. A UIKit pan that
//  fails itself the moment the finger heads mostly up or down hands those
//  touches straight to the scroll view instead.

import SwiftUI
import UIKit

final class HorizontalPanRecognizer: UIPanGestureRecognizer {
    /// Where the finger first touched, in the recognizer's view. The pan's own
    /// translation only starts counting once it has begun, so the range would
    /// otherwise miss everything before the slop.
    private(set) var start: CGPoint = .zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first, let v = view { start = t.location(in: v) }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible, let t = touches.first, let v = view {
            let p = t.location(in: v)
            let dx = p.x - start.x, dy = p.y - start.y
            if hypot(dx, dy) > 8, abs(dy) > abs(dx) {
                state = .failed
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }
}

@available(iOS 18.0, *)
struct HorizontalDragGesture: UIGestureRecognizerRepresentable {
    /// (start, current) in the attached view's coordinate space.
    var onChanged: (CGPoint, CGPoint) -> Void
    var onEnded: () -> Void

    func makeUIGestureRecognizer(context: Context) -> HorizontalPanRecognizer {
        let r = HorizontalPanRecognizer()
        r.maximumNumberOfTouches = 1
        return r
    }

    func handleUIGestureRecognizerAction(_ r: HorizontalPanRecognizer, context: Context) {
        switch r.state {
        case .began, .changed:
            // Local space and the recognizer view's space share a scale, so
            // the delta from touch-down carries over as is.
            let now = context.converter.localLocation
            let cur = r.location(in: r.view)
            let start = CGPoint(x: now.x - (cur.x - r.start.x),
                                y: now.y - (cur.y - r.start.y))
            onChanged(start, now)
        case .ended:
            onEnded()
        default:
            break
        }
    }
}
