//  CardRenderTests.swift
//  BarryTests
//
//  The cards render from a real payload at phone widths without crashing
//  and produce a picture. Not a golden comparison: nobody has reviewed a
//  reference image on a device, so this is the regression net, not the eye.

import Foundation
import SwiftUI
import Testing
@testable import Barry

@MainActor
struct CardRenderTests {
    private func render<V: View>(_ view: V, width: CGFloat) -> CGImage? {
        let r = ImageRenderer(content: view.frame(width: width).fixedSize(horizontal: false, vertical: true))
        r.scale = 2
        return r.cgImage
    }

    /// The rain, wind and temperature card, saved as a picture so the
    /// three time axes can be checked against each other by eye.
    @Test func rainWindTemperatureCardRendersAndSavesAPicture() throws {
        let combined = try Fixtures.combinedKLUK()
        let view = ConfirmationOverlayView(combined: combined, now: Fixtures.fixtureNow)
            .padding(12)
            .background(Color(.systemBackground))
        let r = ImageRenderer(content: view.frame(width: 358).fixedSize(horizontal: false, vertical: true))
        r.scale = 3
        let img = try #require(r.uiImage)
        #expect(img.size.height > 150)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rainwind.png")
        try img.pngData()?.write(to: url)
        NSLog("rainwind card saved to %@", url.path)
    }

    @Test func tafRunwayAndHeroCardsRenderAtEveryPhoneWidth() throws {
        let combined = try Fixtures.combinedKLUK()
        let now = Fixtures.fixtureNow
        for width in [320.0, 390.0, 430.0] {
            let taf = try #require(render(TafTimelineCard(combined: combined, now: now), width: width))
            #expect(taf.width > 0 && taf.height > 40, "taf at \(width)")
            let rwy = try #require(render(RunwayWindsCard(combined: combined), width: width))
            #expect(rwy.width > 0 && rwy.height > 40, "runways at \(width)")
            let hero = try #require(render(HeroView(combined: combined, unit: .hPa, barometer: BarometerManager(),
                                                    now: now, barometerEnabled: false, stale: true,
                                                    staleReason: "Network problem."), width: width))
            #expect(hero.width > 0 && hero.height > 80, "hero at \(width)")
        }
    }
}
