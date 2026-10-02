//  PressureTimeline.swift
//  Barry — iOS
//
//  The isobars of any moment on the radar's timeline. The server sends the
//  pressure field gridded at each hour and at now, all on one lattice; a
//  moment between two of them is the two slid together, and its isobars are
//  contoured here, the same way the server contours the field now
//  (backend/app/pressure_field.py, marching squares). That is what lets the
//  lines move thirty times a second instead of once a frame.

import Foundation

/// Marching squares over a regular lat/lon lattice.
enum Contour {
    /// Polylines of (lat, lon) where a field crosses `level`. `values` is
    /// row-major, row 0 the south edge; a cell that is not finite has no
    /// data and no line through it. Segments are joined end to end; a line
    /// of fewer than three points is dropped, as the server drops it.
    static func lines(values: [Double], nx: Int, ny: Int, lat0: Double, lon0: Double,
                      dlat: Double, dlon: Double, level: Double) -> [[[Double]]] {
        guard nx > 1, ny > 1, values.count == nx * ny else { return [] }
        typealias P = (Double, Double)
        var segs: [(P, P)] = []
        func t(_ a: Double, _ b: Double) -> Double { a == b ? 0.5 : (level - a) / (b - a) }
        for j in 0..<(ny - 1) {
            let latS = lat0 + Double(j) * dlat, latN = latS + dlat
            for i in 0..<(nx - 1) {
                let bl = values[j * nx + i], br = values[j * nx + i + 1]
                let tr = values[(j + 1) * nx + i + 1], tl = values[(j + 1) * nx + i]
                guard bl.isFinite, br.isFinite, tr.isFinite, tl.isFinite else { continue }
                let idx = (bl >= level ? 1 : 0) | (br >= level ? 2 : 0) | (tr >= level ? 4 : 0) | (tl >= level ? 8 : 0)
                if idx == 0 || idx == 15 { continue }
                let lonW = lon0 + Double(i) * dlon, lonE = lonW + dlon
                // Edge crossings: south, east, north, west.
                let s: P = (latS, lonW + t(bl, br) * dlon)
                let e: P = (latS + t(br, tr) * dlat, lonE)
                let n: P = (latN, lonW + t(tl, tr) * dlon)
                let w: P = (latS + t(bl, tl) * dlat, lonW)
                switch idx {
                case 1: segs.append((w, s))
                case 2: segs.append((s, e))
                case 3: segs.append((w, e))
                case 4: segs.append((e, n))
                case 6: segs.append((s, n))
                case 7: segs.append((w, n))
                case 8: segs.append((n, w))
                case 9: segs.append((n, s))
                case 11: segs.append((n, e))
                case 12: segs.append((e, w))
                case 13: segs.append((e, s))
                case 14: segs.append((s, w))
                default:
                    // A saddle: which pair of corners joins is the centre's call.
                    let high = (bl + br + tr + tl) / 4 >= level
                    if (idx == 5) == high {
                        segs += idx == 5 ? [(w, n), (e, s)] : [(w, s), (e, n)]
                    } else {
                        segs += idx == 5 ? [(w, s), (e, n)] : [(w, n), (e, s)]
                    }
                }
            }
        }
        return chain(segs)
    }

    private static func key(_ p: (Double, Double)) -> Int {
        Int((p.0 * 1e5).rounded()) &* 100_000_000 &+ Int((p.1 * 1e5).rounded())
    }

    /// Join segments end to end into polylines.
    private static func chain(_ segs: [((Double, Double), (Double, Double))]) -> [[[Double]]] {
        var ends: [Int: [Int]] = [:]
        for (n, seg) in segs.enumerated() {
            ends[key(seg.0), default: []].append(n)
            ends[key(seg.1), default: []].append(n)
        }
        var used = [Bool](repeating: false, count: segs.count)
        var lines: [[[Double]]] = []
        for n in segs.indices where !used[n] {
            used[n] = true
            var line = [segs[n].0, segs[n].1]
            for forward in [true, false] {
                while true {
                    let tip = forward ? line[line.count - 1] : line[0]
                    guard let next = ends[key(tip)]?.first(where: { !used[$0] }) else { break }
                    used[next] = true
                    let other = key(segs[next].0) == key(tip) ? segs[next].1 : segs[next].0
                    if forward { line.append(other) } else { line.insert(other, at: 0) }
                }
            }
            if line.count >= 3 {
                lines.append(line.map { [($0.0 * 1e4).rounded() / 1e4, ($0.1 * 1e4).rounded() / 1e4] })
            }
        }
        return lines
    }
}

/// A pressure series made ready to be read at any moment.
struct PressureTimeline {
    private struct Frame {
        let time: Double
        let values: [Double]        // row-major, NaN where there is no data
        let mean: Double            // over the cells that have data
    }
    private let frames: [Frame]     // oldest first
    /// The mean of the field now (the frame the server marks as now, else
    /// the newest): what `pattern(at:)` holds every other moment to.
    private let nowMean: Double
    let nx: Int, ny: Int
    let lat0: Double, lon0: Double, dlat: Double, dlon: Double
    let stepHPa: Double

    /// Nil when the series is empty or its frames are not on one lattice.
    init?(_ resp: PressureSeriesResponse) {
        guard let first = resp.frames.first?.pressureGrid, first.nx > 1, first.ny > 1, resp.stepHPa > 0 else { return nil }
        var out: [Frame] = []
        var now: Int?
        for f in resp.frames.sorted(by: { $0.time < $1.time }) {
            let g = f.pressureGrid
            guard g.nx == first.nx, g.ny == first.ny, g.values.count == g.ny,
                  g.values.allSatisfy({ $0.count == g.nx }) else { return nil }
            let values = g.values.flatMap { $0.map { $0 ?? .nan } }
            let finite = values.filter(\.isFinite)
            out.append(Frame(time: Double(f.time), values: values,
                             mean: finite.isEmpty ? .nan : finite.reduce(0, +) / Double(finite.count)))
            if f.kind == "now" { now = out.count - 1 }
        }
        frames = out
        nowMean = out[now ?? out.count - 1].mean
        nx = first.nx; ny = first.ny
        lat0 = first.lat0; lon0 = first.lon0; dlat = first.dlat; dlon = first.dlon
        stepHPa = resp.stepHPa
    }

    /// Names this series: a view holding textures made from one knows
    /// when it has been handed another.
    let id = UUID()

    var frameCount: Int { frames.count }

    /// One frame's field as the difference from the mean now, which is what
    /// fits in a half-float texture with room to spare (a hectopascal in a
    /// thousand does not).
    func offsets(_ i: Int) -> [Double] { frames[i].values.map { $0 - nowMean } }

    /// The mean the offsets are taken from.
    var base: Double { nowMean }

    /// The two frames either side of a moment, how far between them it is,
    /// and the area's rise since then that `pattern(at:)` takes out.
    func bracket(at t: Double) -> (a: Int, b: Int, f: Double, shift: Double) {
        guard let hi = frames.firstIndex(where: { $0.time >= t }) else {
            let last = frames.count - 1
            return (last, last, 0, frames[last].mean - nowMean)
        }
        guard hi > 0 else { return (0, 0, 0, frames[0].mean - nowMean) }
        let a = frames[hi - 1], b = frames[hi]
        let f = b.time > a.time ? (t - a.time) / (b.time - a.time) : 1
        return (hi - 1, hi, f, a.mean + (b.mean - a.mean) * f - nowMean)
    }

    /// The first and last moments the series covers.
    var range: ClosedRange<Double> { frames[0].time...frames[frames.count - 1].time }

    /// The field at a moment: the frames either side slid together, the
    /// first or the last beyond the ends. A cell either frame lacks is
    /// lacking.
    func values(at t: Double) -> [Double] {
        guard let hi = frames.firstIndex(where: { $0.time >= t }) else { return frames[frames.count - 1].values }
        guard hi > 0 else { return frames[0].values }
        let a = frames[hi - 1], b = frames[hi]
        let f = b.time > a.time ? (t - a.time) / (b.time - a.time) : 1
        if f >= 1 { return b.values }
        var out = [Double](repeating: .nan, count: a.values.count)
        for i in out.indices { out[i] = a.values[i] + (b.values[i] - a.values[i]) * f }
        return out
    }

    /// The shape of the field at a moment: the field with the area's own
    /// rise or fall between then and now taken out, so its mean is the mean
    /// now. Six hours behind a front the whole view can be two hectopascals
    /// up; with isobars two apart on a flat field, every line then crosses
    /// the whole map during the loop and lands, when it goes round, where
    /// its neighbour started: lines running on a belt, and nothing a pilot
    /// would call movement (seen 2026-10-02). With that taken out, a line
    /// moves when a trough or a ridge does. The values are no longer the
    /// pressure at that moment, so these lines carry no labels.
    func pattern(at t: Double) -> [Double] {
        let hi = frames.firstIndex(where: { $0.time >= t })
        let mean: Double
        if let hi, hi > 0 {
            let a = frames[hi - 1], b = frames[hi]
            let f = b.time > a.time ? (t - a.time) / (b.time - a.time) : 1
            mean = a.mean + (b.mean - a.mean) * f
        } else {
            mean = frames[hi ?? frames.count - 1].mean
        }
        let shift = mean - nowMean
        guard shift.isFinite, shift != 0 else { return values(at: t) }
        return values(at: t).map { $0 - shift }
    }

    /// The isobars of a field, at the series' spacing.
    func isobars(_ values: [Double]) -> [ContourLine] {
        var lo = Double.infinity, hi = -Double.infinity
        for v in values where v.isFinite { lo = min(lo, v); hi = max(hi, v) }
        guard lo.isFinite, hi.isFinite else { return [] }
        var out: [ContourLine] = []
        var level = (lo / stepHPa).rounded(.down) * stepHPa
        let top = (hi / stepHPa).rounded(.up) * stepHPa
        while level <= top {
            for pts in Contour.lines(values: values, nx: nx, ny: ny, lat0: lat0, lon0: lon0,
                                     dlat: dlat, dlon: dlon, level: level) {
                out.append(ContourLine(level: level, points: pts))
            }
            level += stepHPa
        }
        return out
    }

    /// A field as the grid the shading draws.
    func grid(_ values: [Double]) -> GridOut {
        GridOut(lat0: lat0, lon0: lon0, dlat: dlat, dlon: dlon, ny: ny, nx: nx,
                values: (0..<ny).map { j in (0..<nx).map { i in
                    let v = values[j * nx + i]
                    return v.isFinite ? v : nil
                } })
    }
}
