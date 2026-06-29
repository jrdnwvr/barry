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

import CoreMotion
import Foundation
import SwiftUI

// MARK: - BarometerSample

struct BarometerSample: Equatable {
    let date: Date
    let stationPressureHPa: Double  // raw phone reading (kPa × 10), NOT SLP
    var slpEquivalent: Double?      // set after calibration against a METAR
    var trusted: Bool               // false while moving / uncalibrated
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

    /// A sudden jump of this magnitude means the user changed altitude, not the weather.
    static let maxOffsetJump: Double = 5.0

    func slpEquivalent(for stationPressureHPa: Double) -> Double {
        stationPressureHPa + offset
    }

    static func make(metarSLP: Double, phonePressureHPa: Double, at date: Date = Date()) -> CalibrationState {
        CalibrationState(offset: metarSLP - phonePressureHPa, calibratedAt: date)
    }
}

func isAltitudeJump(from existing: CalibrationState, to incoming: CalibrationState) -> Bool {
    abs(incoming.offset - existing.offset) > CalibrationState.maxOffsetJump
}

// MARK: - CalibrationModel (multi-point, persistable)

/// Keeps the last few calibration points (~6h) and derives a robust offset by
/// averaging them — so one noisy METAR can't yank the live reading — plus a drift
/// estimate (how fast the offset is wandering, i.e. sensor drift). Pure + Codable
/// so it persists across launches and is unit-testable.
struct CalibrationModel: Equatable, Codable {
    static let maxPoints = 8
    static let maxAgeSeconds: Double = 6 * 3600
    static let maxOffsetJump = CalibrationState.maxOffsetJump
    /// Cap how far past the last calibration the drift trend is extrapolated.
    static let maxExtrapolationHours: Double = 2.0
    /// Clamp the drift-projected offset to within this of the flat mean (safety).
    static let maxDriftDeviation: Double = 2.0

    var points: [CalibrationState] = []

    /// Robust offset = mean of retained per-point offsets. nil when empty.
    var offset: Double? {
        guard !points.isEmpty else { return nil }
        return points.map(\.offset).reduce(0, +) / Double(points.count)
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

    static let settleSeconds: Double = 120.0

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

    var samples: [BarometerSample] = []

    mutating func add(_ sample: BarometerSample) {
        let cutoff = sample.date.addingTimeInterval(-Self.maxAgeSeconds)
        samples = samples.filter { $0.date >= cutoff }
        samples.append(sample)
    }

    func trustedSamples() -> [BarometerSample] {
        samples.filter { $0.trusted && $0.slpEquivalent != nil }
    }

    /// Mean raw station pressure over the last `windowSeconds` of stationary
    /// (trusted) samples. Calibrating against this average instead of a single
    /// reading removes sensor jitter from the offset. Falls back to the latest
    /// stationary sample (then the latest sample) if the window is empty; nil only
    /// when there are no samples at all.
    func averageStationPressure(windowSeconds: Double = 300) -> Double? {
        guard let last = samples.last else { return nil }
        let start = last.date.addingTimeInterval(-windowSeconds)
        let win = samples.filter { $0.trusted && $0.date >= start }
        guard !win.isEmpty else {
            return (samples.last(where: { $0.trusted }) ?? last).stationPressureHPa
        }
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

    private var model = CalibrationModel()
    private var lastMetarSLP: Double?
    private static let storeKey = "barometer.calibration.v1"

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

    /// Calibrated + trusted SLP trace for the last ~60 min (drives the chart overlay).
    var phoneTrace: [(Date, Double)] { buffer.phoneTrace() }

    /// Persisted calibrated SLP trace over the last ~48 h (drives the Task 3 overlay).
    var phoneHistoryTrace: [(Date, Double)] { history.trace() }

    init() {
        loadModel()
        loadHistory()
    }

    // MARK: Lifecycle

    func start() {
        guard altimeter == nil else { return }  // already running — idempotent
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        isAvailable = true
        startAltimeter()
        if CMMotionActivityManager.isActivityAvailable() {
            startActivityMonitor()
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
    func attemptCalibration(metarSLP: Double) {
        lastMetarSLP = metarSLP
        guard gate.isStationary, let phonePressure = buffer.averageStationPressure() else { return }
        let point = CalibrationState.make(metarSLP: metarSLP, phonePressureHPa: phonePressure)
        let didReset = model.add(point)
        lastResetWasAltitude = didReset
        if didReset {
            // Altitude changed between METAR cycles; discard the stale local trace too.
            buffer = SampleBuffer()
        }
        syncOutputs()
        backfillCalibration()
        saveModel()
        refreshDerivedState()
    }

    /// Manual hard reset: forget the offset history and recalibrate from scratch
    /// against the most recent METAR (if known and we're stationary).
    func recalibrate() {
        model = CalibrationModel()
        lastResetWasAltitude = false
        buffer = SampleBuffer()
        history = PressureHistory()
        syncOutputs()
        saveModel()
        saveHistory()
        refreshDerivedState()
        if let slp = lastMetarSLP { attemptCalibration(metarSLP: slp) }
    }

    /// Background one-shot recalibration for BGAppRefreshTask. Unlike the live path
    /// (which needs a 120 s motion settle) this confirms stationarity from recent
    /// *historical* activity, takes a brief altimeter sample, and folds it into the
    /// calibration model. No-op if the sensor is unavailable or the device wasn't
    /// recently still. Does its own start/stop — independent of the live session.
    func recalibrateInBackground(metarSLP: Double) async {
        lastMetarSLP = metarSLP
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        guard await wasRecentlyStationary() else { return }
        guard let pressure = await sampleAltimeterOnce() else { return }
        let now = Date()
        model.add(CalibrationState.make(metarSLP: metarSLP, phonePressureHPa: pressure, at: now))
        syncOutputs()
        saveModel()
        if let slp = model.slpEquivalent(for: pressure, at: now), history.record(slp: slp, at: now) {
            saveHistory()
        }
    }

    // MARK: - Private

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

    /// Briefly stream the altimeter (~`seconds`) and return the mean station
    /// pressure (hPa), or nil if no samples arrived. Independent of the live session.
    private func sampleAltimeterOnce(seconds: Double = 3) async -> Double? {
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
        return acc.mean
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

        // When transitioning stationary → moving, retroactively untrust the buffer.
        if wasStationary && !gate.isStationary {
            for i in buffer.samples.indices { buffer.samples[i].trusted = false }
        }

        scheduleSettleCheckIfNeeded()
    }

    private func handlePressure(_ pressureHPa: Double) {
        let now = Date()
        let trusted = gate.isStationary
        let slpEquiv = trusted ? model.slpEquivalent(for: pressureHPa, at: now) : nil
        buffer.add(BarometerSample(
            date: now,
            stationPressureHPa: pressureHPa,
            slpEquivalent: slpEquiv,
            trusted: trusted
        ))
        // Feed the persisted long-horizon log only with trusted, calibrated readings.
        // record() downsamples internally; persist only when a point was actually stored.
        if let slp = slpEquiv, history.record(slp: slp, at: now) {
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
        if gate.isStationary,
           model.offset != nil,
           let latest = buffer.samples.last(where: { $0.trusted }) {
            latestLocalSLP = model.slpEquivalent(for: latest.stationPressureHPa, at: latest.date)
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
            self.gate.process(stationaryActivity: true, at: Date())
            self.motionState = self.gate.state
        }
    }
}

/// Main-actor sample collector for the background one-shot altimeter read.
@MainActor
private final class CaptureAccumulator {
    private var values: [Double] = []
    func add(_ v: Double) { values.append(v) }
    var mean: Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
}
