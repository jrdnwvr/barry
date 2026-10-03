//  RadarGlide.swift
//  Barry — iOS
//
//  The sums behind the radar gliding between frames (RadarGlideView): which
//  two frames a moment sits between, the rain's motion between them turned
//  into map units, and how a frame's tiles are laid into one picture. Pure
//  functions, so the rules are tested without a GPU.

import Foundation
import MapKit

/// The rain's motion between each pair of frames a loop plays, over the
/// region it was asked for (`/radar/motion`), ready to read for a pair.
struct RadarMotionField: Equatable {
    let id = UUID()
    let lat0: Double
    let lon0: Double
    let dlat: Double
    let dlon: Double
    let ny: Int
    let nx: Int
    /// By (start, end) frame time.
    let pairs: [Pair: RadarMotionPair]
    /// The newest observed frame when it was fetched: the pairs change
    /// with every new frame.
    let nowTime: Int

    struct Pair: Hashable {
        let start: Int
        let end: Int
    }

    init?(_ resp: RadarMotionResponse, nowTime: Int) {
        guard resp.nx > 0, resp.ny > 0 else { return nil }
        lat0 = resp.lat0
        lon0 = resp.lon0
        dlat = resp.dlat
        dlon = resp.dlon
        ny = resp.ny
        nx = resp.nx
        var byPair: [Pair: RadarMotionPair] = [:]
        for p in resp.pairs where p.u.count == resp.nx * resp.ny && p.v.count == p.u.count {
            byPair[Pair(start: p.start, end: p.end)] = p
        }
        pairs = byPair
        self.nowTime = nowTime
    }

    func pair(from start: Int, to end: Int) -> RadarMotionPair? {
        pairs[Pair(start: start, end: end)]
    }

    /// The pair's motion as the map's own units per hour: how far east
    /// and how far down the map (Web Mercator, the world one unit across)
    /// the rain in each block moves in an hour. A degree of latitude is
    /// more map at higher latitudes, which is why this is worked out per
    /// row rather than in the shader. Row-major, two values a block.
    func texels(for pair: RadarMotionPair) -> [Float] {
        var out = [Float](repeating: 0, count: nx * ny * 2)
        for r in 0..<ny {
            let lat = lat0 - Double(r) * dlat
            let cosLat = max(0.05, cos(lat * .pi / 180))
            for c in 0..<nx {
                let i = r * nx + c
                out[i * 2] = Float(pair.u[i] / 360)
                out[i * 2 + 1] = Float(-pair.v[i] / (360 * cosLat))
            }
        }
        return out
    }
}

enum RadarGlide {
    /// Which two frames a moment sits between, and how far from the first
    /// to the second. Before the first or past the last frame, or on one
    /// exactly, both are that frame.
    static func bracket(at t: Double, times: [Int]) -> (a: Int, b: Int, f: Double) {
        guard let last = times.indices.last else { return (0, 0, 0) }
        guard t > Double(times[0]) else { return (0, 0, 0) }
        guard t < Double(times[last]) else { return (last, last, 0) }
        var b = 1
        while b < last, Double(times[b]) <= t { b += 1 }
        let a = b - 1
        let span = Double(times[b] - times[a])
        guard span > 0 else { return (a, a, 0) }
        return (a, b, (t - Double(times[a])) / span)
    }

    /// The frames to have ready for a moment: the two it sits between, the
    /// next the loop will reach (going round) and the one before, so a
    /// scrub either way finds its next frame there.
    static func wanted(a: Int, b: Int, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let out = [a, b, (b + 1) % count, (a - 1 + count) % count]
        var seen: Set<Int> = []
        return out.filter { seen.insert($0).inserted }
    }

    /// The tiles a frame's picture is stitched from: one zoom, a rectangle
    /// of columns and rows, and where that sits in the world (Web
    /// Mercator, the world one unit across, y down from the north).
    struct TileSet: Hashable {
        let z: Int
        let x0: Int, x1: Int
        let y0: Int, y1: Int

        init?(_ paths: [MKTileOverlayPath]) {
            guard let first = paths.first, paths.allSatisfy({ $0.z == first.z }) else { return nil }
            z = first.z
            x0 = paths.map(\.x).min()!
            x1 = paths.map(\.x).max()!
            y0 = paths.map(\.y).min()!
            y1 = paths.map(\.y).max()!
        }

        var columns: Int { x1 - x0 + 1 }
        var rows: Int { y1 - y0 + 1 }
        var paths: [MKTileOverlayPath] {
            var out: [MKTileOverlayPath] = []
            for y in y0...y1 { for x in x0...x1 { out.append(MKTileOverlayPath(x: x, y: y, z: z, contentScaleFactor: 1)) } }
            return out
        }
        /// Where the picture's north-west corner is, and how much of the
        /// world it covers.
        var origin: SIMD2<Double> {
            let n = Double(1 << z)
            return SIMD2(Double(x0) / n, Double(y0) / n)
        }
        var size: SIMD2<Double> {
            let n = Double(1 << z)
            return SIMD2(Double(columns) / n, Double(rows) / n)
        }
    }

    /// One tile's codes read back from its picture: a byte a pixel, dBZ
    /// plus 32 where there is echo, zero where there is none.
    struct TileCodes {
        let side: Int
        let bytes: Data
    }

    /// A run of a loop's frames fetched as one picture a tile
    /// (`/radar/stack`): evenly spaced in time, up to `partFrames` of
    /// them, by the keys the map holds them under.
    struct StackPart: Equatable {
        let start: Int
        let step: Int
        let keys: [Int]
        var count: Int { keys.count }

        func url(host: String, px: Int, path: MKTileOverlayPath) -> URL? {
            URL(string: "\(host)/radar/stack/\(start)/\(step)/\(count)/\(px)/\(path.z)/\(path.x)/\(path.y).png")
        }
    }

    /// How many frames one request carries. Small enough that the first
    /// part of a loop is in quickly and the loop can start on it; the rest
    /// stream in behind the clock.
    static let partFrames = 4

    /// The parts a loop is fetched in: its observed frames, evenly spaced,
    /// all but the newest (which is on screen already, from its own
    /// tile), in runs of `partFrames`. Nil when the frames are not evenly
    /// spaced or there are too few, and the loop fetches a tile a frame.
    /// With `dropLast` false every frame given is in (the span's frames
    /// before the loop, for a scrub).
    static func stackParts(_ frames: [RadarFrame], dropLast: Bool = true) -> [StackPart]? {
        let past = (dropLast ? Array(frames.dropLast()) : frames).filter { $0.kind == .observed }
        guard past.count >= 2, past.count == frames.count - (dropLast ? 1 : 0) else { return nil }
        let step = past[1].time - past[0].time
        guard step == 600 || step == 1200 else { return nil }
        for (a, b) in zip(past, past.dropFirst()) where b.time - a.time != step || b.key != b.time { return nil }
        guard past[0].key == past[0].time else { return nil }
        var out: [StackPart] = []
        var i = past.startIndex
        while i < past.endIndex {
            let run = Array(past[i..<min(i + partFrames, past.endIndex)])
            out.append(StackPart(start: run[0].time, step: step, keys: run.map(\.key)))
            i += partFrames
        }
        return out
    }

    /// A stack picture cut into its frames' tiles: `count` tiles of
    /// `side` pixels, top to bottom. Nil when the picture is not that shape.
    static func slices(_ bytes: [UInt8], width: Int, height: Int, count: Int) -> [TileCodes]? {
        guard width > 0, count > 0, height == width * count, bytes.count == width * height else { return nil }
        let per = width * width
        return (0..<count).map { k in TileCodes(side: width, bytes: Data(bytes[k * per..<(k + 1) * per])) }
    }

    /// The tiles of a set laid side by side into one picture, `side`
    /// pixels a tile, row-major; a tile that is missing is clear. Nil when
    /// no tile came or they are not all one size.
    static func stitch(_ set: TileSet, tiles: [(x: Int, y: Int, codes: TileCodes?)], side: Int) -> [UInt8]? {
        guard side > 0, tiles.contains(where: { $0.codes != nil }) else { return nil }
        let width = set.columns * side, height = set.rows * side
        var out = [UInt8](repeating: 0, count: width * height)
        for tile in tiles {
            guard let codes = tile.codes else { continue }
            guard codes.side == side, codes.bytes.count == side * side else { return nil }
            let col = tile.x - set.x0, row = tile.y - set.y0
            guard col >= 0, col < set.columns, row >= 0, row < set.rows else { continue }
            codes.bytes.withUnsafeBytes { src in
                for r in 0..<side {
                    let from = src.baseAddress!.advanced(by: r * side)
                    let to = (row * side + r) * width + col * side
                    out.withUnsafeMutableBytes { dst in
                        dst.baseAddress!.advanced(by: to).copyMemory(from: from, byteCount: side)
                    }
                }
            }
        }
        return out
    }
}
