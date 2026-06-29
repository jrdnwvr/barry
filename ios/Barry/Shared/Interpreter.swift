//  Interpreter.swift
//  Barry — Shared
//
//  Swift mirror of `backend/app/interpreter.py` (brief §4.3) — a pure rule-based
//  pressure curve analyzer. Used to decode the server's `reading` field AND to
//  run the same analysis locally as an offline fallback when the network is
//  unavailable.
//
//  The pipeline mirrors the Python source verbatim:
//      resample (30 min) → de-tide (S2 sinusoid) → smooth (3-pt MA) →
//      slope+steadiness (LSQ over trailing 3h) → derivative + feature scan →
//      classify trend (shared §4.1 table) → confidence + caveats.
//
//  Constants must match `interpreter.py` exactly so the two implementations stay
//  in sync. The Python test fixtures (`tests/test_interpreter.py`) are the
//  cross-language contract.

import Foundation

// MARK: - Tunables (match interpreter.py)

enum InterpreterConstants {
    static let resampleMinutes: Double = 30
    static let gapMinutes: Double = 120
    static let smoothK: Int = 3
    static let slopeWindowHours: Double = 3.0
    static let shortWindowHours: Double = 3.0
    static let kneeLookbackHours: Double = 3.0
    static let kneeRatio: Double = 3.0
    static let kneeMinRate: Double = 0.7
    static let kneeMaxBefore: Double = 0.4
    static let rapidFallRate: Double = 1.0
    static let rapidFallHours: Double = 2.0
    static let diurnalAmplitudeHPa: Double = 1.2
    static let diurnalFlatnessHPa: Double = 0.6
    static let diurnalCorrMin: Double = 0.85
    static let troughNearHours: Double = 1.0
    static let ridgeNearHours: Double = 1.0
    static let forecastLeadHours: Double = 1.0
}

// MARK: - Data types

struct Sample: Hashable {
    let t: Date
    let p: Double
    let observed: Bool
}

/// Structured curve interpretation (brief §4.3). Codable so the iOS client can
/// decode the server's `reading` field directly into this type.
struct Reading: Hashable, Codable {
    let trend: String
    let rate3h: Double
    let steadiness: Double
    let feature: String
    let featureTime: Date?
    let confidence: Double
    let caveats: [String]
}

// MARK: - Helpers

/// S2 semidiurnal atmospheric tide. ±~1.2 hPa cosine peaking around 10am/10pm
/// local solar time, troughing at 4am/4pm. Mirrors `interpreter.py:tide`.
func barometricTide(_ t: Date, localHourOffset: Double = 0) -> Double {
    let hUTC = (t.timeIntervalSince1970 / 3600.0).truncatingRemainder(dividingBy: 24.0)
    let h = hUTC + localHourOffset
    let phase = 2.0 * .pi * (h - 10.0) / 12.0
    return InterpreterConstants.diurnalAmplitudeHPa * cos(phase)
}

/// Linear least-squares fit y = a + b·x. Returns (intercept, slope, R²).
private func lsq(_ xs: [Double], _ ys: [Double]) -> (Double, Double, Double) {
    let n = xs.count
    guard n >= 2 else { return (ys.first ?? 0, 0, 0) }
    let mx = xs.reduce(0, +) / Double(n)
    let my = ys.reduce(0, +) / Double(n)
    let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
    let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
    guard sxx > 0 else { return (my, 0, 0) }
    let b = sxy / sxx
    let a = my - b * mx
    let syy = ys.reduce(0) { $0 + ($1 - my) * ($1 - my) }
    let r2: Double
    if syy <= 0 {
        r2 = 1
    } else {
        let ssRes = zip(xs, ys).reduce(0) { acc, pair in
            let pred = a + b * pair.0
            return acc + (pair.1 - pred) * (pair.1 - pred)
        }
        r2 = max(0, 1 - ssRes / syy)
    }
    return (a, b, r2)
}

private func slope(_ seg: [Sample]) -> Double {
    guard seg.count >= 2 else { return 0 }
    let t0 = seg[0].t
    let xs = seg.map { $0.t.timeIntervalSince(t0) / 3600.0 }
    let ys = seg.map(\.p)
    return lsq(xs, ys).1
}

private func correlation(_ xs: [Double], _ ys: [Double]) -> Double {
    let n = xs.count
    guard n >= 2 else { return 0 }
    let mx = xs.reduce(0, +) / Double(n)
    let my = ys.reduce(0, +) / Double(n)
    let num = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
    let dx = sqrt(xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) })
    let dy = sqrt(ys.reduce(0) { $0 + ($1 - my) * ($1 - my) })
    guard dx > 0, dy > 0 else { return 0 }
    return num / (dx * dy)
}

private func segmentSamples(_ samples: [Sample]) -> [[Sample]] {
    guard !samples.isEmpty else { return [] }
    let sorted = samples.sorted { $0.t < $1.t }
    var out: [[Sample]] = [[sorted[0]]]
    for i in 1..<sorted.count {
        let gapMin = sorted[i].t.timeIntervalSince(sorted[i - 1].t) / 60.0
        if gapMin > InterpreterConstants.gapMinutes {
            out.append([sorted[i]])
        } else {
            out[out.count - 1].append(sorted[i])
        }
    }
    return out
}

private func resampleSegment(_ seg: [Sample]) -> [Sample] {
    guard seg.count >= 2 else { return seg }
    let stepSeconds = InterpreterConstants.resampleMinutes * 60
    let start = seg[0].t
    let end = seg[seg.count - 1].t
    var out: [Sample] = []
    var i = 0
    var t = start
    while t <= end {
        while i + 1 < seg.count && seg[i + 1].t < t { i += 1 }
        let a = seg[i]
        let b = seg[min(i + 1, seg.count - 1)]
        let span = b.t.timeIntervalSince(a.t)
        let p: Double
        let obs: Bool
        if span <= 0 {
            p = a.p
            obs = a.observed
        } else {
            let frac = t.timeIntervalSince(a.t) / span
            p = a.p + frac * (b.p - a.p)
            obs = a.observed && b.observed
        }
        out.append(Sample(t: t, p: p, observed: obs))
        t = t.addingTimeInterval(stepSeconds)
    }
    return out
}

private func smooth(_ seg: [Sample]) -> [Sample] {
    let k = InterpreterConstants.smoothK
    guard k > 1, seg.count >= 2 else { return seg }
    let half = k / 2
    return seg.indices.map { i in
        let lo = max(0, i - half)
        let hi = min(seg.count, i + half + 1)
        let vals = seg[lo..<hi].map(\.p)
        return Sample(t: seg[i].t, p: vals.reduce(0, +) / Double(vals.count),
                      observed: seg[i].observed)
    }
}

private func derivative(_ seg: [Sample]) -> [(Date, Double)] {
    seg.indices.map { i in
        let a: Sample
        let b: Sample
        if i == 0 { a = seg[0]; b = seg[min(1, seg.count - 1)] }
        else if i == seg.count - 1 { a = seg[max(0, i - 1)]; b = seg[seg.count - 1] }
        else { a = seg[i - 1]; b = seg[i + 1] }
        let dtHr = b.t.timeIntervalSince(a.t) / 3600.0
        let d = dtHr > 0 ? (b.p - a.p) / dtHr : 0
        return (seg[i].t, d)
    }
}

private func nearest(_ times: [Date], to now: Date) -> Date? {
    guard !times.isEmpty else { return nil }
    return times.min(by: { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) })
}

// MARK: - Feature scan

private func scanKnee(_ smoothed: [Sample], now: Date) -> Date? {
    var kneeTime: Date?
    let earliest = now.addingTimeInterval(-InterpreterConstants.kneeLookbackHours * 3600)
    for s in smoothed {
        let t = s.t
        if t < earliest || t > now { continue }
        let before = smoothed.filter {
            $0.t >= t.addingTimeInterval(-1.5 * 3600) && $0.t < t
        }
        let after = smoothed.filter {
            $0.t >= t && $0.t <= t.addingTimeInterval(1.5 * 3600)
        }
        guard before.count >= 3, after.count >= 3 else { continue }
        let sb = slope(before)
        let sa = slope(after)
        if abs(sa) < InterpreterConstants.kneeMinRate { continue }
        if abs(sb) > InterpreterConstants.kneeMaxBefore { continue }
        if abs(sa) < InterpreterConstants.kneeRatio * max(abs(sb), 0.1) { continue }
        kneeTime = t  // keep latest match
    }
    return kneeTime
}

private func scanFeatures(
    smoothed: [Sample],
    rawSeg: [Sample],
    now: Date,
    localHourOffset: Double
) -> (String, Date?) {
    guard smoothed.count >= 3 else { return ("none", nil) }

    let rawPs = rawSeg.map(\.p)
    let detPs = smoothed.map(\.p)
    let rawRange = (rawPs.max() ?? 0) - (rawPs.min() ?? 0)
    let detRange = (detPs.max() ?? 0) - (detPs.min() ?? 0)

    if detRange <= InterpreterConstants.diurnalFlatnessHPa {
        let tideVals = rawSeg.map { barometricTide($0.t, localHourOffset: localHourOffset) }
        let corr = correlation(rawPs, tideVals)
        if corr >= InterpreterConstants.diurnalCorrMin
            && rawRange > InterpreterConstants.diurnalFlatnessHPa {
            return ("diurnal_only", nil)
        }
        return ("none", nil)
    }

    let deriv = derivative(smoothed)
    var troughs: [Date] = []
    var ridges: [Date] = []
    for i in 1..<deriv.count {
        let dPrev = deriv[i - 1].1
        let d = deriv[i].1
        if dPrev < 0 && d >= 0 { troughs.append(deriv[i].0) }
        else if dPrev > 0 && d <= 0 { ridges.append(deriv[i].0) }
    }

    let nearestTrough = nearest(troughs, to: now)
    let nearestRidge = nearest(ridges, to: now)

    // 1. trough_passing
    if let t = nearestTrough,
       abs(t.timeIntervalSince(now)) <= InterpreterConstants.troughNearHours * 3600 {
        return ("trough_passing", t)
    }

    // 2. front_knee
    if let knee = scanKnee(smoothed, now: now) {
        return ("front_knee", knee)
    }

    // 3. rapid_fall over trailing window
    let rfStart = now.addingTimeInterval(-InterpreterConstants.rapidFallHours * 3600)
    let rfWin = smoothed.filter { $0.t >= rfStart && $0.t <= now }
    if rfWin.count >= 3 && abs(slope(rfWin)) >= InterpreterConstants.rapidFallRate {
        return ("rapid_fall", nil)
    }

    // 4. approaching_trough
    if let t = nearestTrough, t > now {
        return ("approaching_trough", t)
    }

    // 5. ridge_peak
    if let t = nearestRidge,
       abs(t.timeIntervalSince(now)) <= InterpreterConstants.ridgeNearHours * 3600 {
        return ("ridge_peak", t)
    }

    // 6. post_trough_recovery
    if let t = nearestTrough, t < now {
        let recent = smoothed.filter { $0.t >= now.addingTimeInterval(-2 * 3600) }
        if slope(recent) > 0.3 {
            return ("post_trough_recovery", t)
        }
    }

    return ("none", nil)
}

// MARK: - Trend classification (mirrors §4.1 table in Tendency.swift)

private func classifyTrend(_ rate3h: Double) -> String {
    // Match TendencyClass thresholds: see Tendency.swift / tendency.py.
    if rate3h >= 1.5 { return "rising_fast" }
    if rate3h >= 0.5 { return "rising" }
    if rate3h > -0.5 { return "steady" }
    if rate3h > -1.5 { return "falling" }
    if rate3h > -3.0 { return "falling_mod" }
    return "falling_fast"
}

// MARK: - Main entry

/// Pure function: turn a pressure time series into a structured Reading.
/// Mirrors `interpreter.interpret(...)` in `backend/app/interpreter.py`.
func interpretSeries(
    _ samples: [Sample],
    now: Date? = nil,
    localHourOffset: Double = 0
) -> Reading {
    guard !samples.isEmpty else {
        return Reading(trend: "steady", rate3h: 0, steadiness: 0,
                       feature: "none", featureTime: nil, confidence: 0, caveats: [])
    }
    let sorted = samples.sorted { $0.t < $1.t }
    let effectiveNow = now ?? sorted[sorted.count - 1].t

    var caveats: [String] = []
    let segs = segmentSamples(sorted)
    if segs.count > 1 { caveats.append("sparse") }

    let chosen = segs.first(where: { $0[0].t <= effectiveNow && $0[$0.count - 1].t >= effectiveNow })
        ?? segs.max(by: { $0.count < $1.count }) ?? []

    let seg = resampleSegment(chosen)
    let detided = seg.map {
        Sample(t: $0.t, p: $0.p - barometricTide($0.t, localHourOffset: localHourOffset),
               observed: $0.observed)
    }
    let smoothed = smooth(detided)

    // --- slope / steadiness over trailing window ---
    let windowStart = effectiveNow.addingTimeInterval(-InterpreterConstants.slopeWindowHours * 3600)
    var win = smoothed.filter { $0.t >= windowStart && $0.t <= effectiveNow }
    if win.count < 3 {
        win = smoothed.count >= 3 ? Array(smoothed.suffix(3)) : smoothed
        guard win.count >= 2 else {
            return Reading(trend: "steady", rate3h: 0, steadiness: 0,
                           feature: "none", featureTime: nil, confidence: 0,
                           caveats: caveats)
        }
    }
    let t0 = win[0].t
    let xs = win.map { $0.t.timeIntervalSince(t0) / 3600.0 }
    let ys = win.map(\.p)
    let (_, slopePerHr, r2) = lsq(xs, ys)
    let rate3h = slopePerHr * 3.0
    let steadiness = r2
    let windowHours = win[win.count - 1].t.timeIntervalSince(win[0].t) / 3600.0
    if windowHours < InterpreterConstants.shortWindowHours - 1e-6 {
        caveats.append("short_window")
    }

    let (feature, featureTime) = scanFeatures(
        smoothed: smoothed, rawSeg: seg,
        now: effectiveNow, localHourOffset: localHourOffset
    )

    if let ft = featureTime,
       ft.timeIntervalSince(effectiveNow) > InterpreterConstants.forecastLeadHours * 3600 {
        caveats.append("forecast_derived")
    }

    let trend = classifyTrend(rate3h)

    var confidence: Double = 1.0
    if caveats.contains("short_window") { confidence *= 0.5 }
    if caveats.contains("sparse") { confidence *= 0.7 }
    if caveats.contains("forecast_derived") { confidence *= 0.7 }
    if ["approaching_trough", "trough_passing", "ridge_peak", "front_knee"].contains(feature),
       steadiness < 0.5 {
        confidence *= 0.7
    }
    confidence = max(0, min(1, confidence))

    return Reading(
        trend: trend,
        rate3h: (rate3h * 100).rounded() / 100,
        steadiness: (steadiness * 1000).rounded() / 1000,
        feature: feature,
        featureTime: featureTime,
        confidence: (confidence * 100).rounded() / 100,
        caveats: caveats
    )
}
