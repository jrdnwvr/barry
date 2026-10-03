//  LayerTimelines.swift
//  Barry — iOS
//
//  The wind, the stations and the lightning on the radar's clock: what each
//  layer shows for a moment that is not now, from the server's series of
//  past hours (/radar/field/series, /metars/series, /lightning/series).
//  Pure values and functions, tested without a map.
//
//  Each is honest about what it has. The wind is a model field an hour
//  apart, so it is slid between two hours like the isobars. A station's
//  report is a moment, so the barb shows the latest report at or before
//  the clock and steps when the next comes. The lightning is the twenty
//  minutes before the last ten-minute mark, as the live layer is the
//  twenty minutes before now. Where a series has nothing within reach of
//  the moment, the layer stays at now and the note under the frame time
//  says so (RadarTimeline.nowOnlyNote).

import Foundation

/// The map's wind grid at each hour the series holds, the surface and the
/// altitude stops alike, on the one lattice.
struct WindTimeline: Equatable {
    let id = UUID()
    struct Frame: Equatable {
        let time: Int
        /// By level: 0 the surface, else the pressure level in hPa.
        let fields: [Int: [WindArrow]]
    }
    let frames: [Frame]
    /// The newest observed radar frame when it was fetched.
    let nowTime: Int

    init?(_ resp: FieldSeriesResponse, nowTime: Int) {
        var out: [Frame] = []
        for f in resp.frames {
            var fields: [Int: [WindArrow]] = [:]
            fields[0] = f.points.map { WindArrow(lat: $0.lat, lon: $0.lon, speedKmh: $0.windKmh, fromDeg: $0.windDeg) }
            var byLevel: [Int: [WindArrow]] = [:]
            for p in f.levels {
                for l in p.levels {
                    byLevel[l.hPa, default: []].append(WindArrow(lat: p.lat, lon: p.lon, speedKmh: l.windKmh, fromDeg: l.windDeg))
                }
            }
            for (hpa, arrows) in byLevel { fields[hpa] = arrows }
            out.append(Frame(time: f.time, fields: fields))
        }
        guard !out.isEmpty else { return nil }
        frames = out.sorted { $0.time < $1.time }
        self.nowTime = nowTime
    }

    /// A frame further from the moment than this is no use for it.
    static let reachS = 90 * 60

    /// The two fields either side of a moment at a level and how far from
    /// the first to the second, or nil when the series does not reach the
    /// moment at that level. On a frame exactly, or past the last frame
    /// within reach, both fields are the one.
    func fields(at t: Double, level: Int) -> (a: [WindArrow], b: [WindArrow], f: Double)? {
        let have = frames.filter { $0.fields[level]?.isEmpty == false }
        guard !have.isEmpty else { return nil }
        let times = have.map(\.time)
        let at = RadarGlide.bracket(at: t, times: times)
        let a = have[at.a], b = have[at.b]
        let near = min(abs(Double(a.time) - t), abs(Double(b.time) - t))
        guard near <= Double(Self.reachS) else { return nil }
        if at.a == at.b || abs(Double(b.time) - t) > Double(Self.reachS) {
            return (a.fields[level]!, a.fields[level]!, 0)
        }
        if abs(Double(a.time) - t) > Double(Self.reachS) {
            return (b.fields[level]!, b.fields[level]!, 0)
        }
        return (a.fields[level]!, b.fields[level]!, at.f)
    }

    /// One field for a moment: the two either side slid together, point
    /// for point where the lattices match (they do, the server lays every
    /// frame on the one lattice), as vectors, so a wind backing from west
    /// to south passes through southwest and not through calm.
    func field(at t: Double, level: Int) -> [WindArrow]? {
        guard let got = fields(at: t, level: level) else { return nil }
        return Self.blend(got.a, got.b, f: got.f)
    }

    static func blend(_ a: [WindArrow], _ b: [WindArrow], f: Double) -> [WindArrow] {
        guard f > 0, a.count == b.count else { return f < 0.5 ? a : b }
        var out: [WindArrow] = []
        out.reserveCapacity(a.count)
        for (p, q) in zip(a, b) {
            guard p.lat == q.lat, p.lon == q.lon else { return f < 0.5 ? a : b }
            let ra = p.fromDeg * .pi / 180, rb = q.fromDeg * .pi / 180
            let u = -p.speedKmh * sin(ra) * (1 - f) - q.speedKmh * sin(rb) * f
            let v = -p.speedKmh * cos(ra) * (1 - f) - q.speedKmh * cos(rb) * f
            let speed = (u * u + v * v).squareRoot()
            var deg = speed > 0.05 ? (atan2(-u, -v) * 180 / .pi) : p.fromDeg
            if deg < 0 { deg += 360 }
            out.append(WindArrow(lat: p.lat, lon: p.lon, speedKmh: (speed * 10).rounded() / 10, fromDeg: deg.rounded()))
        }
        return out
    }

    /// Whether the series reaches back to a moment at a level: what the
    /// note under the frame time goes by, so it does not come and go as
    /// a loop plays.
    func covers(_ t: Double, level: Int) -> Bool {
        fields(at: t, level: level) != nil
    }
}

/// Each station's reports over the last hours.
struct StationTimeline: Equatable {
    let id = UUID()
    let stations: [StationSeries]
    let nowTime: Int

    init?(_ resp: StationSeriesResponse, nowTime: Int) {
        guard !resp.stations.isEmpty else { return nil }
        stations = resp.stations
        self.nowTime = nowTime
    }

    /// A report older than this at the moment is last hour's weather.
    static let reachS = 90 * 60

    /// The stations as they reported at a moment: each one's latest report
    /// at or before it (a METAR at :53 stands for the hour that follows),
    /// within reach. Nil when no station has one, so the layer stays at
    /// now.
    func observations(at t: Double) -> [StationObs]? {
        var out: [StationObs] = []
        for s in stations {
            guard let r = s.reports.last(where: { Double($0.t) <= t + 300 }),
                  t - Double(r.t) <= Double(Self.reachS) else { continue }
            var o = StationObs(id: s.id, lat: s.lat, lon: s.lon)
            o.windKt = r.windKt
            o.windDir = r.windDir
            o.gustKt = r.gustKt
            o.fltCat = r.fltCat
            o.obsTime = Date(timeIntervalSince1970: Double(r.t))
            out.append(o)
        }
        return out.isEmpty ? nil : out
    }

    func covers(_ t: Double) -> Bool { observations(at: t) != nil }
}

/// Six hours of flashes in ten-minute frames.
struct LightningTimeline: Equatable {
    let id = UUID()
    let frames: [LightningFrame]
    let windowSec: Int
    let binDeg: Double
    let nowTime: Int

    init?(_ resp: LightningSeriesResponse, nowTime: Int) {
        guard !resp.frames.isEmpty else { return nil }
        frames = resp.frames.sorted { $0.time < $1.time }
        windowSec = resp.windowSec
        binDeg = resp.binDeg
        self.nowTime = nowTime
    }

    /// The frame for a moment: the last mark at or before it.
    func frame(at t: Double) -> LightningFrame? {
        guard let f = frames.last(where: { Double($0.time) <= t }) else { return nil }
        return t - Double(f.time) < 1200 ? f : nil
    }

    /// What the lightning layer draws for a moment, nil when the series
    /// has no frame for it. Ages are from the frame's mark; no arrival
    /// pulse, these are not new.
    func state(at t: Double) -> LightningState? {
        guard let f = frame(at: t) else { return nil }
        let resp = LightningResponse(cells: f.cells, clusters: [], windowSec: windowSec, binDeg: binDeg,
                                     coverage: true, source: nil, cachedAt: Date(timeIntervalSince1970: Double(f.time)))
        return LightningState(response: resp, version: f.time, receivedAt: .distantPast)
    }

    func covers(_ t: Double) -> Bool { frame(at: t) != nil }
}
