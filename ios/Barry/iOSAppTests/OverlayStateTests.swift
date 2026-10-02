//  OverlayStateTests.swift
//  BarryTests
//
//  The map's overlays are read on MapKit's drawing queue while the main
//  thread replaces their state. Unguarded, that crashed the first time the
//  state was replaced thirty times a second (2026-10-02).

import Foundation
import MapKit
import Metal
import Testing
@testable import Barry

struct OverlayStateTests {
    private func line(_ n: Int) -> ContourLine {
        ContourLine(level: Double(1000 + n % 30), points: (0..<24).map { [38 + Double($0) * 0.1, -86 + Double(n % 7) * 0.1] })
    }

    @Test func anOverlaysStateCanBeReplacedWhileItIsBeingRead() async {
        let pressure = PressureFieldOverlay()
        let fronts = FrontFieldOverlay()
        let lightning = LightningOverlay()
        let reads = Locked(0)
        let done = Locked(false)
        // Three readers, as MapKit's draw calls would be, for as long as the writer runs.
        let readers = (0..<3).map { _ in
            Task.detached {
                while !done.value {
                    let p = pressure.state
                    let f = fronts.state
                    let l = lightning.state
                    reads.withLock { $0 += (p.field?.isobars.count ?? 0) + f.fronts.count + l.version + 1 }
                }
            }
        }
        for n in 0..<20_000 {
            var p = PressureFieldState()
            p.field = PressureFieldResponse(isobars: [line(n), line(n + 1)], cachedAt: Date())
            p.version = n
            pressure.state = p
            var f = FrontRenderState()
            f.fronts = [RenderedFront(kind: .cold, weak: false,
                                      coordinates: [CLLocationCoordinate2D(latitude: 40, longitude: -90 + Double(n % 5))],
                                      alpha: 1)]
            f.version = n
            fronts.state = f
            lightning.state = LightningState(response: nil, version: n, receivedAt: Date())
        }
        done.value = true
        for r in readers { await r.value }
        #expect(pressure.state.version == 19_999)
        #expect(fronts.state.version == 19_999)
        #expect(reads.value > 0)
    }

    @Test func aLockedValueCountsEveryChange() async {
        let n = Locked(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { for _ in 0..<5_000 { n.withLock { $0 += 1 } } }
            }
        }
        #expect(n.value == 40_000)
    }

    /// When its shaders do not compile the six-hour loop's isobars fall
    /// back to the tiled renderer without a word, so a slip in them would
    /// only show as the broken lines coming back.
    @Test func theIsolineShadersCompile() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        #expect(IsolineView.isAvailable)
    }
}
