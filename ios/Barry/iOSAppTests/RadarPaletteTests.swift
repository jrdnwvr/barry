//  RadarPaletteTests.swift
//  BarryTests
//
//  Barry's radar colours: nothing below 5 dBZ, blues that deepen with
//  intensity, the convective break at 45, and a repaint that never eats a
//  tile it cannot read.

import Foundation
import Testing
@testable import Barry

struct RadarPaletteTests {
    @Test func lightEchoesAreInvisibleAndTheRampDeepens() {
        #expect(RadarPalette.color(dBZ: -5).a == 0 && RadarPalette.color(dBZ: 4).a == 0)
        var lastAlpha = 0.0
        for d in stride(from: 5, through: 44, by: 5) {
            let c = RadarPalette.color(dBZ: d)
            #expect(c.a >= lastAlpha, "alpha at \(d)")
            #expect(c.b > c.r, "blue side at \(d)")
            lastAlpha = c.a
        }
        let conv = RadarPalette.color(dBZ: 45)
        #expect(conv.r == 1.0 && conv.g > 0.5 && conv.b < 0.3)                 // orange
        #expect(RadarPalette.color(dBZ: 60).r > 0.8 && RadarPalette.color(dBZ: 60).b > 0.8)   // magenta
        #expect(RadarPalette.color(dBZ: 70).a == 1.0)
    }

    @Test func recolorReturnsWhatItCannotRead() {
        let junk = Data([0x00, 0x01, 0x02, 0x03])
        #expect(RadarPalette.recolor(junk) == junk)
        #expect(RadarPalette.recolor(Data()) == Data())
    }
}
