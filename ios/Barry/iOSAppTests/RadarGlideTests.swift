//  RadarGlideTests.swift
//  BarryTests
//
//  The radar gliding between frames: which two frames a moment sits
//  between, which to hold ready, the rain's motion in the map's own units,
//  tiles stitched into one picture, a tile read back to codes, and the
//  shaders compiling (the loop falls back to the tile layers in silence
//  when they do not).

import Foundation
import MapKit
import Metal
import Testing
import UIKit
@testable import Barry

struct RadarGlideTests {
    let times = [600, 1200, 1800]
    static let square: [(Int, Int)] = [(2, 3), (3, 3), (2, 4), (3, 4)]

    @Test func aMomentSitsBetweenTwoFrames() {
        let mid = RadarGlide.bracket(at: 900, times: times)
        #expect(mid.a == 0 && mid.b == 1 && mid.f == 0.5)
        let late = RadarGlide.bracket(at: 1650, times: times)
        #expect(late.a == 1 && late.b == 2 && late.f == 0.75)
        // On a frame exactly: that frame, nothing of the next.
        let on = RadarGlide.bracket(at: 1200, times: times)
        #expect(on.a == 1 && on.f == 0)
        // Before the first or past the last: that frame alone.
        let before = RadarGlide.bracket(at: 10, times: times)
        #expect(before.a == 0 && before.b == 0 && before.f == 0)
        let after = RadarGlide.bracket(at: 5000, times: times)
        #expect(after.a == 2 && after.b == 2 && after.f == 0)
        let none = RadarGlide.bracket(at: 5000, times: [])
        #expect(none.a == 0 && none.b == 0)
    }

    @Test func theFramesHeldAreTheTwoOfTheMomentAndTheNextTwoRound() {
        #expect(RadarGlide.wanted(a: 5, b: 6, count: 7) == [5, 6, 0, 1])
        #expect(RadarGlide.wanted(a: 2, b: 3, count: 7) == [2, 3, 4, 5])
        #expect(RadarGlide.wanted(a: 0, b: 0, count: 1) == [0])
        #expect(RadarGlide.wanted(a: 0, b: 0, count: 0) == [])
    }

    @Test func theMotionBecomesMapUnitsAnHour() throws {
        let resp = RadarMotionResponse(lat0: 40, lon0: -85, dlat: 1, dlon: 1, ny: 1, nx: 2,
                                       pairs: [RadarMotionPair(start: 600, end: 1200, u: [1.2, 0], v: [0, 1]),
                                               RadarMotionPair(start: 1200, end: 1800, u: [1], v: [1])],   // wrong size
                                       cachedAt: Date())
        let field = try #require(RadarMotionField(resp, nowTime: 1800))
        #expect(field.pair(from: 1200, to: 1800) == nil, "a pair of the wrong size is dropped")
        let pair = try #require(field.pair(from: 600, to: 1200))
        let t = field.texels(for: pair)
        // East 1.2 degrees an hour is 1.2/360 of the world's width.
        let east = Float(1.2 / 360)
        #expect(abs(t[0] - east) < 1e-7 && t[1] == 0)
        // North a degree an hour is up the map (negative y), more so than a
        // degree of longitude at 40 N.
        let north = Float(-1 / (360 * cos(40 * Double.pi / 180)))
        #expect(t[2] == 0 && abs(t[3] - north) < 1e-7)
        #expect(RadarMotionField(RadarMotionResponse(lat0: 0, lon0: 0, dlat: 1, dlon: 1, ny: 0, nx: 0,
                                                     pairs: [], cachedAt: Date()), nowTime: 0) == nil)
    }

    @Test func aTileSetIsARectangleWithAPlaceInTheWorld() throws {
        let paths = Self.square.map { MKTileOverlayPath(x: $0.0, y: $0.1, z: 5, contentScaleFactor: 3) }
        let set = try #require(RadarGlide.TileSet(paths))
        #expect(set.x0 == 2 && set.x1 == 3 && set.y0 == 3 && set.y1 == 4)
        #expect(set.columns == 2 && set.rows == 2 && set.paths.count == 4)
        let origin: SIMD2<Double> = [2.0 / 32, 3.0 / 32], size: SIMD2<Double> = [2.0 / 32, 2.0 / 32]
        #expect(set.origin == origin && set.size == size)
        var mixed = paths
        mixed.append(MKTileOverlayPath(x: 1, y: 1, z: 6, contentScaleFactor: 3))
        #expect(RadarGlide.TileSet(mixed) == nil && RadarGlide.TileSet([]) == nil)
    }

    @Test func tilesAreStitchedIntoPlaceAndAMissingOneIsClear() throws {
        let paths = Self.square.map { MKTileOverlayPath(x: $0.0, y: $0.1, z: 5, contentScaleFactor: 3) }
        let set = try #require(RadarGlide.TileSet(paths))
        let a = RadarGlide.TileCodes(side: 2, bytes: Data([1, 2, 3, 4]))
        let b = RadarGlide.TileCodes(side: 2, bytes: Data([5, 6, 7, 8]))
        let tiles: [(x: Int, y: Int, codes: RadarGlide.TileCodes?)] = [(2, 3, a), (3, 3, nil), (3, 4, b)]
        let out = try #require(RadarGlide.stitch(set, tiles: tiles, side: 2))
        let want: [UInt8] = [1, 2, 0, 0,
                             3, 4, 0, 0,
                             0, 0, 5, 6,
                             0, 0, 7, 8]
        #expect(out == want)
        let odd = RadarGlide.TileCodes(side: 1, bytes: Data([9]))
        #expect(RadarGlide.stitch(set, tiles: [(2, 3, a), (3, 3, odd)], side: 2) == nil, "tiles of two sizes")
        #expect(RadarGlide.stitch(set, tiles: [(2, 3, nil)], side: 2) == nil, "nothing to stitch")
    }

    @Test func aTileReadsBackToCodesAndToBarrysColours() throws {
        // Two by two, Universal Blue: 20 dBZ top left, 45 dBZ bottom right.
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: cs,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let px = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        for (i, v) in [0x00, 0xA3, 0xE0, 0xFF].enumerated() { px[i] = UInt8(v) }
        for (i, v) in [0xFF, 0x44, 0x00, 0xFF].enumerated() { px[12 + i] = UInt8(v) }
        let image = try #require(ctx.makeImage())
        let png = try #require(UIImage(cgImage: image).pngData())
        let codes = try #require(RadarPalette.codes(png))
        #expect(codes.side == 2 && [UInt8](codes.bytes) == [20 + 32, 0, 0, 45 + 32])
        let painted = try #require(UIImage(data: RadarPalette.recolor(png))?.cgImage)
        let back = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        back.draw(painted, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        let out = try #require(back.data).assumingMemoryBound(to: UInt8.self)
        let c = RadarPalette.color(dBZ: 20)
        let want = [c.r * c.a, c.g * c.a, c.b * c.a, c.a].map { Int(($0 * 255).rounded()) }
        let got = (0..<4).map { Int(out[$0]) }
        #expect(zip(got, want).allSatisfy { abs($0 - $1) <= 1 }, "\(got) vs \(want)")
        #expect(out[4] == 0 && out[7] == 0, "nothing where there was nothing")
        #expect(RadarPalette.codes(Data([1, 2, 3])) == nil)
    }

    @Test func theGlideShadersCompile() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        #expect(RadarGlideView.isAvailable)
    }
}
