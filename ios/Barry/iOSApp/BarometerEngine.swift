//  BarometerEngine.swift
//  Barry — iOS
//
//  The phone-barometer feature's pure value types: samples, micro-trend,
//  calibration points and the multi-point model with drift, altitude helpers,
//  the motion gate, and the rolling sample buffer. No Core Motion, no
//  ObservableObject: everything here is unit-testable with plain values.
//  BarometerManager.swift is the thin shell that feeds sensor data into these.

import Foundation

// MARK: - BarometerSample

struct BarometerSample: Equatable {
    let date: Date
    let stationPressureHPa: Double  // raw phone reading (kPa × 10), NOT SLP
    var slpEquivalent: Double?      // set after calibration against a METAR
    /// Usable for display / micro-trend / history. True when the classifier says
    /// stationary, OR when the pressure stream itself is weather-plausible while
    /// hand-carried (physics check) — the barometer only cares about vertical motion.
    var trusted: Bool
    /// Calibration-grade: the activity classifier vouched for stillness. Only these
    /// feed the offset model — mis-calibration is expensive, a display sample isn't.
    var stationary: Bool = true
}

// MARK: - MicroTrend

struct MicroTrend: Equatable {
    let deltaHPa: Double    // signed change (negative = falling)
    let windowMinutes: Int  // width of the observation window
}

// MARK: - CalibrationState

/// The SLP offset derived from aligning one phone reading with a fresh METAR SLP.
/// offset = metar_slp − phone_station_pressure_hPa. This is one calibration *point*;
/// CalibrationModel keeps a short history of them for a robust offset + drift.
struct CalibrationState: Equatable, Codable {
    let offset: Double
    let calibratedAt: Date
    /// The station observation this point was paired against. Drives dedupe: one
    /// calibration point per METAR obs, so frequent app refreshes against the same
    /// (frozen) report can't cluster the model or absorb between-report weather
    /// change into the offset. Optional so pre-existing persisted points decode.
    var metarObsTime: Date? = nil

    /// A sudden jump of this magnitude means the user changed altitude, not the weather.
    static let maxOffsetJump: Double = 5.0

    func slpEquivalent(for stationPressureHPa: Double) -> Double {
        stationPressureHPa + offset
    }

    static func make(metarSLP: Double, phonePressureHPa: Double, at date: Date = Date(),
                     obsTime: Date? = nil) -> CalibrationState {
        CalibrationState(offset: metarSLP - phonePressureHPa, calibratedAt: date,
                         metarObsTime: obsTime)
    }
}

func isAltitudeJump(from existing: CalibrationState, to incoming: CalibrationState) -> Bool {
    abs(incoming.offset - existing.offset) > CalibrationState.maxOffsetJump
}

// MARK: - CalibrationModel (multi-point, persistable)

/// Keeps the last several calibration points (~12h) and derives a robust offset
/// as their median — so a noisy or outlier METAR can't yank the live reading —
/// plus a drift estimate (how fast the offset is wandering, i.e. sensor drift).
/// With one point per METAR obs (deduped upstream) the window genuinely spans
/// hours, which is what makes the drift fit meaningful. Pure + Codable so it
/// persists across launches and is unit-testable.
struct CalibrationModel: Equatable, Codable {
    static let maxPoints = 12
    static let maxAgeSeconds: Double = 12 * 3600
    static let maxOffsetJump = CalibrationState.maxOffsetJump
    /// Cap how far past the last calibration the drift trend is extrapolated.
    static let maxExtrapolationHours: Double = 2.0
    /// Clamp the drift-projected offset to within this of the flat mean (safety).
    static let maxDriftDeviation: Double = 2.0

    var points: [CalibrationState] = []

    /// Robust offset = MEDIAN of retained per-point offsets — outlier-resistant
    /// beyond what the altitude-jump gate alone provides. nil when empty.
    var offset: Double? {
        guard !points.isEmpty else { return nil }
        let sorted = points.map(\.offset).sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// True when a point paired against this station observation is already
    /// retained — the caller should skip adding a duplicate.
    func containsObservation(_ obsTime: Date) -> Bool {
        points.contains { $0.metarObsTime == obsTime }
    }

    var calibratedAt: Date? { points.last?.calibratedAt }

    /// Least-squares fit of offset vs time (hours since the first retained point).
    /// Returns (intercept a, slope b in hPa/hour). nil until ≥3 points span real time.
    private func regression() -> (a: Double, b: Double)? {
        guard points.count >= 3 else { return nil }
        let t0 = points[0].calibratedAt
        let xs = points.map { $0.calibratedAt.timeIntervalSince(t0) / 3600.0 }
        let ys = points.map(\.offset)
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 1e-6 else { return nil }
        let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let b = sxy / sxx
        return (my - b * mx, b)
    }

    /// Offset slope in hPa/hour — "sensor drift." nil until ≥3 points span real time.
    var driftPerHour: Double? { regression()?.b }

    /// Flat (mean) SLP-equivalent — ignores drift. Kept for callers without a
    /// timestamp; the live path uses the time-aware variant below.
    func slpEquivalent(for stationPressureHPa: Double) -> Double? {
        offset.map { stationPressureHPa + $0 }
    }

    /// Drift-projected offset at `date`: follows the offset trend so the live value
    /// tracks slow sensor drift between calibrations. Falls back to the flat mean
    /// when drift can't be estimated. Conservative — the projection is capped in
    /// time (`maxExtrapolationHours`) and clamped to within `maxDriftDeviation` of
    /// the mean so a steep short-term trend can't run the value away.
    func offset(at date: Date) -> Double? {
        guard let mean = offset else { return nil }
        guard let (a, b) = regression(), let t0 = points.first?.calibratedAt else { return mean }
        let lastX = points[points.count - 1].calibratedAt.timeIntervalSince(t0) / 3600.0
        let x = min(date.timeIntervalSince(t0) / 3600.0, lastX + Self.maxExtrapolationHours)
        let projected = a + b * x
        return min(mean + Self.maxDriftDeviation, max(mean - Self.maxDriftDeviation, projected))
    }

    /// Drift-aware SLP-equivalent for a reading taken at `date`.
    func slpEquivalent(for stationPressureHPa: Double, at date: Date) -> Double? {
        offset(at: date).map { stationPressureHPa + $0 }
    }

    /// Add a calibration point. Returns true if the point deviated so far from the
    /// current robust offset that we treat it as an altitude change and reset the
    /// history to just this point.
    @discardableResult
    mutating func add(_ point: CalibrationState) -> Bool {
        prune(now: point.calibratedAt)
        if let off = offset, abs(point.offset - off) > Self.maxOffsetJump {
            points = [point]
            return true
        }
        points.append(point)
        if points.count > Self.maxPoints {
            points.removeFirst(points.count - Self.maxPoints)
        }
        return false
    }

    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.maxAgeSeconds)
        points.removeAll { $0.calibratedAt < cutoff }
    }

    /// Shift every retained offset by `delta` hPa — used when a measured altitude
    /// change moves the sensor's datum (offset = altitude term + sensor bias; the
    /// altitude term changed, the bias didn't). A uniform shift preserves the drift
    /// regression's slope, so drift tracking survives the move.
    mutating func shiftOffsets(by delta: Double) {
        points = points.map { CalibrationState(offset: $0.offset + delta,
                                               calibratedAt: $0.calibratedAt,
                                               metarObsTime: $0.metarObsTime) }
    }
}

// MARK: - Altitude ↔ pressure helpers

enum PressureAltitude {
    /// Local rate of pressure change with height near the surface (hPa per meter).
    /// ~0.120 at sea level, ~0.110 at 800 m — 0.118 is a good constant for the
    /// small moves (hills, garages, buildings) the altitude bridge handles.
    static let hPaPerMeter = 0.118

    /// ISA (standard atmosphere) sea-level reduction: what SLP would be if the
    /// sensor reading `rawHPa` was taken `altitudeM` above sea level. Used only for
    /// the GPS *bootstrap* (±1–2 hPa) — METAR calibration replaces it when it lands.
    static func standardSLP(rawHPa: Double, altitudeM h: Double) -> Double {
        rawHPa * pow(1.0 - 0.0065 * h / 288.15, -5.257)
    }
}

// MARK: - MotionGate (pure state machine)

/// Three-state motion gate (brief §4.5.3).
/// Transitions driven by CMMotionActivity callbacks; settle timer fires via the
/// scheduleSettleCheck helper in BarometerManager.
struct MotionGate: Equatable {
    enum State: Equatable {
        case stationary
        case settling(until: Date)  // just stopped; waiting for sensor to stabilise
        case moving
    }

    static let settleSeconds: Double = 45.0

    var state: State

    init(state: State = .moving) { self.state = state }

    var isStationary: Bool {
        if case .stationary = state { return true }
        return false
    }

    var isMoving: Bool {
        if case .moving = state { return true }
        return false
    }

    /// Advance the state machine with one activity classification at `now`.
    mutating func process(stationaryActivity: Bool, at now: Date) {
        switch state {
        case .stationary:
            if !stationaryActivity { state = .moving }
        case .settling(let until):
            if !stationaryActivity {
                state = .moving
            } else if now >= until {
                state = .stationary
            }
        case .moving:
            if stationaryActivity {
                state = .settling(until: now.addingTimeInterval(Self.settleSeconds))
            }
        }
    }
}

// MARK: - SampleBuffer (rolling 60-min window)

/// Holds up to 60 min of BarometerSamples; older entries are pruned on each add.
struct SampleBuffer: Equatable {
    static let maxAgeSeconds: Double = 3600.0

    // --- carried-clean physics check (trusting data while the classifier says
    // "moving"). Weather moves pressure at ~0.1 hPa per 10 MINUTES; elevation moves
    // it at 0.12 hPa per METER — hugely separable rates. A short window catches
    // elevators/stairs; the long window catches slow sustained ramps (gentle hills)
    // that stay inside each short window but accumulate.
    static let carriedShortWindow: TimeInterval = 120
    static let carriedShortSpreadHPa = 0.25   // ≈ same-floor handling tolerance (~2 m)
    static let carriedLongWindow: TimeInterval = 600
    static let carriedLongSpreadHPa = 0.5
    static let carriedMinSamples = 3

    var samples: [BarometerSample] = []

    mutating func add(_ sample: BarometerSample) {
        let cutoff = sample.date.addingTimeInterval(-Self.maxAgeSeconds)
        samples = samples.filter { $0.date >= cutoff }
        samples.append(sample)
    }

    func trustedSamples() -> [BarometerSample] {
        samples.filter { $0.trusted && $0.slpEquivalent != nil }
    }

    /// True when a new raw reading taken while the classifier reports motion is
    /// still barometrically clean: peak-to-peak spread within weather-plausible
    /// bounds over both windows. Raw values are compared regardless of trust —
    /// raw is raw. Requires a minimum of recent context; a cold buffer proves nothing.
    func isCleanWhileMoving(candidateHPa: Double, at now: Date) -> Bool {
        func spread(_ values: [Double]) -> Double {
            guard let lo = values.min(), let hi = values.max() else { return .infinity }
            return hi - lo
        }
        let shortStart = now.addingTimeInterval(-Self.carriedShortWindow)
        let short = samples.filter { $0.date >= shortStart }
            .map(\.stationPressureHPa) + [candidateHPa]
        guard short.count >= Self.carriedMinSamples,
              spread(short) <= Self.carriedShortSpreadHPa else { return false }

        let longStart = now.addingTimeInterval(-Self.carriedLongWindow)
        let long = samples.filter { $0.date >= longStart }
            .map(\.stationPressureHPa) + [candidateHPa]
        return spread(long) <= Self.carriedLongSpreadHPa
    }

    /// Scoped retroactive untrust for the classifier's detection lag: motion is
    /// reported late, so only samples inside the lag window are suspect — not the
    /// whole buffer. Demotes both trust tiers (they may be motion-contaminated).
    mutating func untrustRecent(since cutoff: Date) {
        for i in samples.indices where samples[i].date >= cutoff {
            samples[i].trusted = false
            samples[i].stationary = false
        }
    }

    /// Mean raw station pressure over the last `windowSeconds` of CALIBRATION-GRADE
    /// (classifier-stationary + trusted) samples. Calibrating against this average
    /// instead of a single reading removes sensor jitter from the offset. Falls back
    /// to the latest calibration-grade sample (then the latest sample) if the window
    /// is empty; nil only when there are no samples at all.
    func averageStationPressure(windowSeconds: Double = 300) -> Double? {
        guard let last = samples.last else { return nil }
        let start = last.date.addingTimeInterval(-windowSeconds)
        let win = samples.filter { $0.trusted && $0.stationary && $0.date >= start }
        guard !win.isEmpty else {
            return (samples.last(where: { $0.trusted && $0.stationary }) ?? last).stationPressureHPa
        }
        return win.map(\.stationPressureHPa).reduce(0, +) / Double(win.count)
    }

    /// Mean raw pressure from calibration-grade samples within ±`halfWindow` of the
    /// station's observation time — pairs the phone with the station AT the moment
    /// it reported, not "now" (pressure may have moved since). Falls back to the
    /// trailing-window average when nothing surrounds the obs (app opened later).
    func averageStationPressure(around obsTime: Date, halfWindow: Double = 300) -> Double? {
        let win = samples.filter {
            $0.trusted && $0.stationary
                && abs($0.date.timeIntervalSince(obsTime)) <= halfWindow
        }
        guard !win.isEmpty else { return averageStationPressure() }
        return win.map(\.stationPressureHPa).reduce(0, +) / Double(win.count)
    }

    /// Calibrated (SLP-equivalent) points for the chart trace, oldest → newest.
    func phoneTrace() -> [(Date, Double)] {
        trustedSamples().compactMap { s in s.slpEquivalent.map { (s.date, $0) } }
    }

    /// Δp over the trusted window. Returns nil when fewer than 3 points or
    /// window is shorter than 5 min (not enough signal).
    func microTrend() -> MicroTrend? {
        let trusted = trustedSamples()
        guard trusted.count >= 3 else { return nil }
        let first = trusted[0], last = trusted[trusted.count - 1]
        let windowMinutes = Int(last.date.timeIntervalSince(first.date) / 60)
        guard windowMinutes >= 5 else { return nil }
        let delta = (last.slpEquivalent ?? 0) - (first.slpEquivalent ?? 0)
        return MicroTrend(deltaHPa: delta, windowMinutes: windowMinutes)
    }
}
