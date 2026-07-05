//  BarometerManager.swift
//  Barry — iOS
//
//  Phone barometer enrichment (brief §4.5). Wires CMAltimeter + CMMotionActivityManager
//  into a calibrated, motion-gated live pressure supplement.
//
//  Architecture: the pure value types (MotionGate, CalibrationState, SampleBuffer) carry
//  all the logic and are fully testable without Core Motion hardware. BarometerManager
//  is the thin ObservableObject shell that feeds real sensor data into them.
//
//  The feature is off by default. Start/stop is controlled externally (BarryApp reads
//  the "phoneBarometerEnabled" AppStorage key and calls start()/stop() accordingly).

import CoreLocation
import CoreMotion
import Foundation
import SwiftUI

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

// MARK: - BarometerManager

@MainActor
final class BarometerManager: ObservableObject {
    @Published private(set) var motionState: MotionGate.State = .moving
    @Published private(set) var microTrend: MicroTrend?
    @Published private(set) var latestLocalSLP: Double?
    /// True only on physical iPhones with a real barometer; false on simulator.
    @Published private(set) var isAvailable: Bool = false

    // Derived calibration outputs (published for the UI).
    @Published private(set) var offsetHPa: Double?     // robust station→SLP offset
    @Published private(set) var calibratedAt: Date?    // time of the latest point
    @Published private(set) var driftPerHour: Double?  // offset slope (hPa/h)
    /// True when the most recent calibration discarded history as an altitude change.
    @Published private(set) var lastResetWasAltitude: Bool = false

    /// Provisional GPS-altitude-derived offset (ISA reduction). Drives the live
    /// value before the first METAR calibration; never persisted, never fed into
    /// the history log, and cleared the moment a real calibration point lands.
    @Published private(set) var provisionalOffset: Double?

    private var model = CalibrationModel()
    private var lastMetarSLP: Double?
    private var lastMetarObsTime: Date?
    private static let storeKey = "barometer.calibration.v1"

    /// Altitude (m, MSL) captured at the last calibration — the datum the altitude
    /// bridge compares against after the device moves. Persisted with the model.
    private var referenceAltitudeM: Double?
    private static let refAltitudeKey = "barometer.refAltitude.v1"
    /// Ignore altitude deltas below this — inside GPS noise (≈0.5 hPa).
    private static let minBridgeMeters: Double = 4.0
    private var bridgeInFlight = false

    /// How far back the stationary→moving transition retroactively untrusts —
    /// covers the activity classifier's detection lag, nothing more.
    private static let retroactiveUntrustSeconds: TimeInterval = 90

    /// Dedicated best-accuracy location source for vertical fixes (the shared
    /// station-lookup manager uses km accuracy, useless for altitude).
    private lazy var altitudeLocation = LocationManager(desiredAccuracy: kCLLocationAccuracyBest)

    /// Persisted, downsampled long-horizon log of calibrated SLP readings (Task 2).
    private var history = PressureHistory()
    private static let historyStoreKey = "barometer.history.v1"

    private var gate = MotionGate()
    private var buffer = SampleBuffer()
    private var altimeter: CMAltimeter?
    private var activityManager: CMMotionActivityManager?
    private let operationQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "me.wvr.barry.barometer"
        return q
    }()

    var isCalibrated: Bool { offsetHPa != nil }

    /// True while running on the GPS-altitude bootstrap (no METAR calibration yet):
    /// absolute values are approximate (±1–2 hPa); trends are already sound.
    var isProvisional: Bool { offsetHPa == nil && provisionalOffset != nil }

    /// Model offset when calibrated, else the GPS bootstrap offset.
    private func effectiveSLP(for rawHPa: Double, at date: Date) -> Double? {
        model.slpEquivalent(for: rawHPa, at: date) ?? provisionalOffset.map { rawHPa + $0 }
    }

    /// Barry's current motion verdict — true only when the device is classified still.
    /// Drives the "you're moving" warning before a manual reading.
    var isStationaryNow: Bool { gate.isStationary }

    /// True when the newest buffered sample earned trust via the carried-clean
    /// physics check rather than classifier stillness — the header says "carried"
    /// instead of contradicting itself with the raw motion state.
    var latestReadingIsCarried: Bool {
        guard let last = buffer.samples.last else { return false }
        return last.trusted && !last.stationary
    }

    /// Calibrated + trusted SLP trace for the last ~60 min (drives the chart overlay).
    var phoneTrace: [(Date, Double)] { buffer.phoneTrace() }

    /// Persisted calibrated SLP trace over the last ~48 h (drives the Task 3 overlay).
    var phoneHistoryTrace: [(Date, Double)] { history.trace() }


    /// Most recent trusted local SLP and when it was taken. Unlike `latestLocalSLP`
    /// (which is nil while moving), this persists across motion — so the UI can keep
    /// showing the last good local reading; a to-the-second live value isn't required.
    var lastLocalReading: (slp: Double, at: Date)? {
        if let live = latestLocalSLP {
            return (live, buffer.samples.last(where: { $0.trusted })?.date ?? Date())
        }
        return history.entries.last.map { ($0.slp, $0.date) }
    }

    init() {
        loadModel()
        loadHistory()
        loadReferenceAltitude()
    }

    // MARK: Lifecycle

    func start() {
        guard altimeter == nil else { return }  // already running — idempotent
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        isAvailable = true
        startAltimeter()
        if CMMotionActivityManager.isActivityAvailable() {
            startActivityMonitor()
            // A phone already at rest when we start won't get a fresh "stationary"
            // event (updates are change-driven), so seed from recent history — else
            // the gate can sit in .moving indefinitely and never record a thing.
            // Then: bridge any altitude change since the last calibration, and if
            // never calibrated, bootstrap a provisional offset from GPS altitude.
            Task {
                await seedStationarityIfResting()
                await bridgeForAltitudeChangeIfNeeded()
                await bootstrapFromGPSIfNeeded()
            }
        } else {
            // No motion coprocessor (some iPads) — treat device as stationary so
            // calibration can proceed; user understands motion-gating won't fire.
            gate.state = .stationary
            motionState = .stationary
        }
    }

    func stop() {
        altimeter?.stopRelativeAltitudeUpdates()
        activityManager?.stopActivityUpdates()
        altimeter = nil
        activityManager = nil
        isAvailable = false
    }

    /// Call whenever PressureStore receives a fresh METAR with a valid SLP.
    /// Adds a calibration point (when stationary), folding it into the robust offset;
    /// a large deviation is treated as an altitude change and resets the history.
    /// One point per station observation: refreshes that carry the same (frozen)
    /// METAR are skipped, so between-report weather change can't bias the offset
    /// and the retained points genuinely span hours (what drift fitting needs).
    func attemptCalibration(metarSLP: Double, observedAt: Date? = nil) {
        lastMetarSLP = metarSLP
        lastMetarObsTime = observedAt
        if let observedAt, model.containsObservation(observedAt) { return }
        guard gate.isStationary else { return }
        // Pair the phone's average AT the obs time when we have surrounding samples.
        let phonePressureMaybe = observedAt.map { buffer.averageStationPressure(around: $0) }
            ?? buffer.averageStationPressure()
        guard let phonePressure = phonePressureMaybe else { return }
        let point = CalibrationState.make(metarSLP: metarSLP, phonePressureHPa: phonePressure,
                                          obsTime: observedAt)
        let didReset = model.add(point)
        lastResetWasAltitude = didReset
        if didReset {
            // Altitude changed between METAR cycles; discard the stale local trace too.
            buffer = SampleBuffer()
        }
        provisionalOffset = nil  // real calibration supersedes the GPS bootstrap
        syncOutputs()
        backfillCalibration()
        saveModel()
        refreshDerivedState()
        // Stamp the altitude this calibration was taken at — the datum the bridge
        // compares against after the next move.
        Task { await updateReferenceAltitude() }
    }

    /// Manual hard reset: forget the offset history and recalibrate from scratch
    /// against the most recent METAR (if known and we're stationary).
    func recalibrate() {
        model = CalibrationModel()
        lastResetWasAltitude = false
        provisionalOffset = nil
        buffer = SampleBuffer()
        history = PressureHistory()
        syncOutputs()
        saveModel()
        saveHistory()
        refreshDerivedState()
        if let slp = lastMetarSLP { attemptCalibration(metarSLP: slp, observedAt: lastMetarObsTime) }
    }

    // MARK: - On-demand measurement

    /// The result of a user-triggered "Measure now" reading.
    struct ManualMeasurement: Equatable {
        let slp: Double?     // calibrated SLP-equivalent, nil if not calibrated yet
        let rawHPa: Double?  // raw station pressure sampled, nil if no sensor data
        let hadMotion: Bool  // device was moving during the reading
        let recorded: Bool   // stored to the persisted trace (shows on the chart)
    }

    /// Take a reading on demand — independent of the passive 120 s settle timer, so
    /// users can log a point whenever they feel the need. Motion is allowed but
    /// flagged: a reading taken while moving is still stored to the visible trace,
    /// but is NEVER folded into calibration (it doesn't touch the offset or the
    /// calibration buffer), so a bumpy reading can't corrupt the live value.
    @discardableResult
    func measureNow(stationSLP: Double? = nil, observedAt: Date? = nil) async -> ManualMeasurement {
        // Keep the latest station SLP fresh so calibration bootstrap works even before
        // the passive calibration path has run (e.g. right after first launch).
        if let stationSLP {
            lastMetarSLP = stationSLP
            lastMetarObsTime = observedAt
        }

        // Sample the barometer for a few seconds. Whether the reading is usable is
        // decided by the barometer's *own steadiness*, not the coarse activity
        // classifier: hand tremor that trips CMMotionActivity doesn't move the phone
        // enough to change the pressure (~0.7 m of altitude ≈ 0.08 hPa). Only a
        // genuinely noisy sample — real vertical movement (stairs, elevator, a car) —
        // counts as "moving". Falls back to the gate only if too few samples arrived.
        guard let stats = await sampleAltimeterOnce(seconds: 3) else {
            return ManualMeasurement(slp: nil, rawHPa: nil,
                                     hadMotion: !gate.isStationary, recorded: false)
        }
        let steady = stats.count >= 2 ? stats.spread < Self.steadySpreadHPa
                                      : gate.isStationary
        let moving = !steady

        let raw = stats.mean
        let now = Date()

        // Bootstrap calibration from this very reading when we're still but not yet
        // calibrated: prefer the latest station SLP (full precision); fall back to
        // GPS altitude + ISA reduction (approximate) so a deliberate tap always
        // produces a value rather than silently doing nothing.
        if model.offset == nil, !moving {
            if let metar = lastMetarSLP {
                model.add(CalibrationState.make(metarSLP: metar, phonePressureHPa: raw,
                                                at: now, obsTime: lastMetarObsTime))
                provisionalOffset = nil
                syncOutputs()
                saveModel()
                Task { await updateReferenceAltitude() }
            } else if provisionalOffset == nil, let fix = await sampleAltitude() {
                provisionalOffset = PressureAltitude.standardSLP(rawHPa: raw,
                                                                 altitudeM: fix.meters) - raw
            }
        }

        let calibratedSLP = model.slpEquivalent(for: raw, at: now)
        let slp = calibratedSLP ?? provisionalOffset.map { raw + $0 }

        var recorded = false
        if let slp {
            // Log deliberate taps (force past the downsample throttle) — but only
            // METAR-calibrated values enter the persisted history; the GPS bootstrap
            // drives the live display without contaminating the log.
            if calibratedSLP != nil, history.record(slp: slp, at: now, force: true) {
                saveHistory()
                recorded = true
            }
            // Feed calibration ONLY when still — a moving reading is excluded.
            if !moving {
                buffer.add(BarometerSample(date: now, stationPressureHPa: raw,
                                           slpEquivalent: slp, trusted: true))
            }
        }
        refreshDerivedState()
        return ManualMeasurement(slp: slp, rawHPa: raw, hadMotion: moving, recorded: recorded)
    }

    /// Background one-shot recalibration for BGAppRefreshTask. Unlike the live path
    /// (which needs a 120 s motion settle) this confirms stationarity from recent
    /// *historical* activity, takes a brief altimeter sample, and folds it into the
    /// calibration model. No-op if the sensor is unavailable or the device wasn't
    /// recently still. Does its own start/stop — independent of the live session.
    func recalibrateInBackground(metarSLP: Double, observedAt: Date? = nil) async {
        lastMetarSLP = metarSLP
        lastMetarObsTime = observedAt
        if let observedAt, model.containsObservation(observedAt) { return }
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        guard await wasRecentlyStationary() else { return }
        guard let stats = await sampleAltimeterOnce() else { return }
        let pressure = stats.mean
        let now = Date()
        model.add(CalibrationState.make(metarSLP: metarSLP, phonePressureHPa: pressure,
                                        at: now, obsTime: observedAt))
        syncOutputs()
        saveModel()
        if let slp = model.slpEquivalent(for: pressure, at: now), history.record(slp: slp, at: now) {
            saveHistory()
        }
    }

    // MARK: - Testing helpers (Debug builds only)

    #if DEBUG
    /// Seed the persisted phone-SLP history with ~48 h of points based on the real
    /// observed station series (offset slightly to mimic a calibrated phone; the
    /// stretch older than the observed data is synthesized with a gentle wave). Lets
    /// the Sensor-vs-Station overlay show a full trace across all its windows without
    /// waiting to accumulate live readings.
    func loadSampleHistory(observed: [(Date, Double)], now: Date = Date()) {
        var seeded = PressureHistory()
        let start = now.addingTimeInterval(-48 * 3600)
        let offset = 0.25  // phone reads a touch off the station
        let real = observed.filter { $0.0 >= start && $0.0 <= now }.sorted { $0.0 < $1.0 }
        let anchorVal = real.first?.1 ?? real.last?.1 ?? 1018.0
        let anchorDate = real.first?.0 ?? now

        // Synthesize the window older than the earliest real observation.
        var t = start
        while t < anchorDate {
            let hrs = t.timeIntervalSince(start) / 3600.0
            let wave = 2.0 * sin(2 * .pi * hrs / 26.0 - 0.5) + 0.4 * sin(2 * .pi * hrs / 12.0)
            seeded.record(slp: anchorVal + wave + offset, at: t, force: true)
            t = t.addingTimeInterval(20 * 60)
        }
        // Real observed points as the recent phone trace (offset + a touch of jitter).
        for (d, v) in real {
            let jitter = 0.04 * sin(d.timeIntervalSince(start) / 600.0)
            seeded.record(slp: v + offset + jitter, at: d, force: true)
        }

        objectWillChange.send()
        history = seeded
        saveHistory()
        refreshDerivedState()
    }

    /// Wipe the persisted phone-SLP history (testing).
    func clearHistory() {
        objectWillChange.send()
        history = PressureHistory()
        saveHistory()
        refreshDerivedState()
    }
    #endif

    // MARK: - Private

    /// Peak-to-peak pressure (hPa) below which a short sample is treated as physically
    /// stable. A phone in the hand is typically < 0.02; real vertical movement (stairs,
    /// elevator, a car) blows well past this. ≈ 0.10 hPa ≈ 0.8 m of altitude noise —
    /// generous enough to tolerate hand-hold jitter, tight enough to reject real motion.
    static let steadySpreadHPa: Double = 0.10

    /// Trust an already-resting phone immediately at start-up: if recent history says
    /// it's been still, the barometer is already settled, so skip the post-motion
    /// settle wait and go straight to .stationary. No-op once a live event has moved us.
    private func seedStationarityIfResting() async {
        guard gate.isMoving else { return }
        guard await wasRecentlyStationary(window: 90) else { return }
        guard gate.isMoving else { return }  // re-check after the await
        gate.state = .stationary
        motionState = .stationary
        refreshDerivedState()
    }

    // MARK: - Altitude sensing (fused absolute altitude → GPS fallback)

    struct AltitudeFix {
        let meters: Double    // MSL
        let accuracy: Double  // 1σ vertical, meters
    }

    /// Reject fixes worse than this — ±8 m ≈ ±1 hPa, the useful floor.
    private static let maxAltitudeAccuracy: Double = 8.0

    /// Best available altitude: CMAltimeter's *absolute altitude* first (fuses
    /// GPS + barometer + Wi-Fi + map data; meter-class on iPhone 12+), falling back
    /// to a raw GPS vertical fix. nil when neither meets the accuracy gate — better
    /// no bridge than a wrong one.
    private func sampleAltitude() async -> AltitudeFix? {
        if CMAltimeter.isAbsoluteAltitudeAvailable(),
           let fix = await sampleAbsoluteAltitude(),
           fix.accuracy <= Self.maxAltitudeAccuracy {
            return fix
        }
        guard let loc = await altitudeLocation.requestLocation(),
              loc.verticalAccuracy > 0,
              loc.verticalAccuracy <= Self.maxAltitudeAccuracy else { return nil }
        return AltitudeFix(meters: loc.altitude, accuracy: loc.verticalAccuracy)
    }

    /// One-shot read of the fused absolute-altitude stream (short timeout).
    private func sampleAbsoluteAltitude(timeout: Double = 4) async -> AltitudeFix? {
        let alt = CMAltimeter()
        let latch = OneShotGate()
        return await withCheckedContinuation { cont in
            alt.startAbsoluteAltitudeUpdates(to: operationQueue) { data, _ in
                guard let data else { return }
                let fix = AltitudeFix(meters: data.altitude, accuracy: data.accuracy)
                Task { @MainActor in
                    guard latch.claim() else { return }
                    alt.stopAbsoluteAltitudeUpdates()
                    cont.resume(returning: fix)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                Task { @MainActor in
                    guard latch.claim() else { return }
                    alt.stopAbsoluteAltitudeUpdates()
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Re-stamp the calibration's altitude datum (call after adding a METAR point).
    private func updateReferenceAltitude() async {
        guard let fix = await sampleAltitude() else { return }
        referenceAltitudeM = fix.meters
        saveReferenceAltitude()
    }

    /// The altitude bridge: on coming to rest, compare current altitude against the
    /// calibration's datum; if the device moved vertically, shift the offsets by
    /// Δh × 0.118 hPa/m instead of serving wrong values until the next METAR
    /// exposes the jump. METAR remains truth — the next point lands on the shifted
    /// offsets with no jump, and full precision resumes seamlessly.
    private func bridgeForAltitudeChangeIfNeeded() async {
        guard !bridgeInFlight else { return }
        bridgeInFlight = true
        defer { bridgeInFlight = false }

        guard gate.isStationary, model.offset != nil else { return }
        guard let ref = referenceAltitudeM else {
            // Calibrated before this feature existed — capture a datum so the
            // NEXT move can bridge.
            await updateReferenceAltitude()
            return
        }
        guard let fix = await sampleAltitude() else { return }
        let dh = fix.meters - ref
        guard abs(dh) >= Self.minBridgeMeters else { return }

        model.shiftOffsets(by: dh * PressureAltitude.hPaPerMeter)
        referenceAltitudeM = fix.meters
        saveReferenceAltitude()
        lastResetWasAltitude = false
        syncOutputs()
        saveModel()
        refreshDerivedState()
    }

    /// GPS bootstrap: before the first METAR calibration, derive an approximate
    /// offset from altitude + ISA reduction so the app shows a local reading
    /// immediately. Superseded (cleared) by the first real calibration point.
    private func bootstrapFromGPSIfNeeded() async {
        guard model.offset == nil, provisionalOffset == nil, gate.isStationary else { return }
        guard let stats = await sampleAltimeterOnce(seconds: 2) else { return }
        guard let fix = await sampleAltitude() else { return }
        provisionalOffset = PressureAltitude.standardSLP(rawHPa: stats.mean,
                                                         altitudeM: fix.meters) - stats.mean
        refreshDerivedState()
    }

    private func loadReferenceAltitude() {
        referenceAltitudeM = AppConfig.sharedDefaults.object(forKey: Self.refAltitudeKey) as? Double
    }

    private func saveReferenceAltitude() {
        AppConfig.sharedDefaults.set(referenceAltitudeM, forKey: Self.refAltitudeKey)
    }

    /// True if the most recent classified motion activity in the last `window`
    /// seconds was stationary. Background-safe substitute for the live settle timer.
    private func wasRecentlyStationary(window: TimeInterval = 300) async -> Bool {
        guard CMMotionActivityManager.isActivityAvailable() else { return false }
        let manager = CMMotionActivityManager()
        let end = Date()
        let start = end.addingTimeInterval(-window)
        let activities: [CMMotionActivity] = await withCheckedContinuation { cont in
            manager.queryActivityStarting(from: start, to: end, to: operationQueue) { acts, _ in
                cont.resume(returning: acts ?? [])
            }
        }
        return activities.last?.stationary ?? false
    }

    /// Briefly stream the altimeter (~`seconds`) and return the mean station pressure
    /// plus its peak-to-peak spread and sample count, or nil if no samples arrived.
    /// Independent of the live session.
    private func sampleAltimeterOnce(seconds: Double = 3) async -> SampleStats? {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return nil }
        let alt = CMAltimeter()
        let acc = CaptureAccumulator()
        alt.startRelativeAltitudeUpdates(to: operationQueue) { data, error in
            guard let data, error == nil else { return }
            let hPa = data.pressure.doubleValue * 10.0
            Task { @MainActor in acc.add(hPa) }
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        alt.stopRelativeAltitudeUpdates()
        return acc.stats
    }

    private func loadModel() {
        guard let data = AppConfig.sharedDefaults.data(forKey: Self.storeKey),
              var stored = try? JSONDecoder().decode(CalibrationModel.self, from: data)
        else { return }
        stored.prune(now: Date())
        model = stored
        syncOutputs()
    }

    private func saveModel() {
        if let data = try? JSONEncoder().encode(model) {
            AppConfig.sharedDefaults.set(data, forKey: Self.storeKey)
        }
    }

    private func loadHistory() {
        guard let data = AppConfig.sharedDefaults.data(forKey: Self.historyStoreKey),
              var stored = try? JSONDecoder().decode(PressureHistory.self, from: data)
        else { return }
        stored.prune(now: Date())
        history = stored
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            AppConfig.sharedDefaults.set(data, forKey: Self.historyStoreKey)
        }
    }

    private func syncOutputs() {
        offsetHPa = model.offset
        calibratedAt = model.calibratedAt
        driftPerHour = model.driftPerHour
    }

    private func startAltimeter() {
        let alt = CMAltimeter()
        altimeter = alt
        alt.startRelativeAltitudeUpdates(to: operationQueue) { [weak self] data, error in
            guard let data, error == nil else { return }
            let hPa = data.pressure.doubleValue * 10.0  // kPa → hPa
            Task { @MainActor [weak self] in self?.handlePressure(hPa) }
        }
    }

    private func startActivityMonitor() {
        let mgr = CMMotionActivityManager()
        activityManager = mgr
        mgr.startActivityUpdates(to: operationQueue) { [weak self] activity in
            guard let activity else { return }
            Task { @MainActor [weak self] in self?.handleActivity(activity) }
        }
    }

    private func handleActivity(_ activity: CMMotionActivity) {
        let wasStationary = gate.isStationary
        gate.process(stationaryActivity: activity.stationary, at: activity.startDate)
        motionState = gate.state

        // Stationary → moving: the classifier detects motion late, so samples inside
        // its lag window may be contaminated — untrust just those ~90 s, not the
        // whole hour of provably-still data (checking the app shouldn't destroy the
        // very trend it displays).
        if wasStationary && !gate.isStationary {
            buffer.untrustRecent(since: Date().addingTimeInterval(-Self.retroactiveUntrustSeconds))
        }

        // Came to rest → check whether we changed altitude while moving and shift
        // the calibration accordingly (instead of serving wrong values until the
        // next METAR exposes the jump).
        if !wasStationary && gate.isStationary {
            Task { await bridgeForAltitudeChangeIfNeeded() }
        }

        scheduleSettleCheckIfNeeded()
    }

    private func handlePressure(_ pressureHPa: Double) {
        let now = Date()
        let stationary = gate.isStationary
        // Trust matrix: classifier-stationary → trust everything, even fast changes
        // (a pressure jump on a resting phone is REAL WEATHER — the event Barry
        // exists to catch). Classifier-moving → let the pressure stream vouch for
        // itself; only "moving AND pressure changing fast" is truly unknowable
        // (can't split altitude from weather) and gets discarded.
        let trusted = stationary || buffer.isCleanWhileMoving(candidateHPa: pressureHPa, at: now)
        let calibratedSLP = trusted ? model.slpEquivalent(for: pressureHPa, at: now) : nil
        // The GPS bootstrap drives the live value too, but is kept out of the
        // persisted history — only METAR-calibrated points are logged.
        let slpEquiv = calibratedSLP
            ?? (trusted ? provisionalOffset.map { pressureHPa + $0 } : nil)
        buffer.add(BarometerSample(
            date: now,
            stationPressureHPa: pressureHPa,
            slpEquivalent: slpEquiv,
            trusted: trusted,
            stationary: stationary
        ))
        // Feed the persisted long-horizon log only with trusted, calibrated readings.
        // record() downsamples internally; persist only when a point was actually stored.
        if let slp = calibratedSLP, history.record(slp: slp, at: now) {
            saveHistory()
        }
        refreshDerivedState()
    }

    private func backfillCalibration() {
        for i in buffer.samples.indices where buffer.samples[i].trusted {
            buffer.samples[i].slpEquivalent = model.slpEquivalent(
                for: buffer.samples[i].stationPressureHPa, at: buffer.samples[i].date)
        }
    }

    private func refreshDerivedState() {
        // Live value tracks TRUST (which includes carried-clean data), not the raw
        // classifier state — handling the phone no longer blanks the reading. The
        // most recent sample must itself be trusted so a stale value can't linger
        // through an elevator ride.
        if model.offset != nil || provisionalOffset != nil,
           let latest = buffer.samples.last, latest.trusted {
            latestLocalSLP = effectiveSLP(for: latest.stationPressureHPa, at: latest.date)
        } else {
            latestLocalSLP = nil
        }
        microTrend = buffer.microTrend()
    }

    /// After the gate enters .settling, kick a main-thread wakeup after the settle
    /// deadline so the transition fires even if CMMotionActivity updates are sparse.
    private func scheduleSettleCheckIfNeeded() {
        guard case .settling(let until) = gate.state else { return }
        let delay = until.timeIntervalSinceNow + 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            guard let self else { return }
            let wasStationary = self.gate.isStationary
            self.gate.process(stationaryActivity: true, at: Date())
            self.motionState = self.gate.state
            if !wasStationary && self.gate.isStationary {
                Task { await self.bridgeForAltitudeChangeIfNeeded() }
            }
        }
    }
}

/// Summary of a short one-shot altimeter capture.
struct SampleStats {
    let mean: Double     // mean station pressure (hPa)
    let spread: Double   // peak-to-peak over the sample (hPa) — a stillness proxy
    let count: Int
}

/// Main-actor once-only latch for continuation-based one-shot sensor reads
/// (callback vs. timeout race — exactly one side may resume).
@MainActor
private final class OneShotGate {
    private var claimed = false
    /// Returns true exactly once.
    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Main-actor sample collector for one-shot altimeter reads.
@MainActor
private final class CaptureAccumulator {
    private var values: [Double] = []
    func add(_ v: Double) { values.append(v) }
    var mean: Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
    var stats: SampleStats? {
        guard let mean, let lo = values.min(), let hi = values.max() else { return nil }
        return SampleStats(mean: mean, spread: hi - lo, count: values.count)
    }
}
