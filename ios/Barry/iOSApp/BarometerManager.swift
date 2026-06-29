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

    var points: [CalibrationState] = []

    /// Robust offset = mean of retained per-point offsets. nil when empty.
    var offset: Double? {
        guard !points.isEmpty else { return nil }
        return points.map(\.offset).reduce(0, +) / Double(points.count)
    }

    var calibratedAt: Date? { points.last?.calibratedAt }

    /// Offset slope in hPa/hour (least-squares over the retained points). nil until
    /// there are ≥3 points spanning real time — that's "sensor drift".
    var driftPerHour: Double? {
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
        return sxy / sxx
    }

    func slpEquivalent(for stationPressureHPa: Double) -> Double? {
        offset.map { stationPressureHPa + $0 }
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

    private var gate = MotionGate()
    private var buffer = SampleBuffer()
    private var altimeter: CMAltimeter?
    private var activityManager: CMMotionActivityManager?
    private let operationQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.wide-stack.barry.barometer"
        return q
    }()

    var isCalibrated: Bool { offsetHPa != nil }

    /// Calibrated + trusted SLP trace for the last ~60 min (drives the chart overlay).
    var phoneTrace: [(Date, Double)] { buffer.phoneTrace() }

    init() { loadModel() }

    // MARK: Lifecycle

    func start() {
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
        guard gate.isStationary, let latest = buffer.samples.last else { return }
        let point = CalibrationState.make(metarSLP: metarSLP, phonePressureHPa: latest.stationPressureHPa)
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
        syncOutputs()
        saveModel()
        refreshDerivedState()
        if let slp = lastMetarSLP { attemptCalibration(metarSLP: slp) }
    }

    // MARK: - Private

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
        let trusted = gate.isStationary
        let slpEquiv = trusted ? model.slpEquivalent(for: pressureHPa) : nil
        buffer.add(BarometerSample(
            date: Date(),
            stationPressureHPa: pressureHPa,
            slpEquivalent: slpEquiv,
            trusted: trusted
        ))
        refreshDerivedState()
    }

    private func backfillCalibration() {
        for i in buffer.samples.indices where buffer.samples[i].trusted {
            buffer.samples[i].slpEquivalent = model.slpEquivalent(for: buffer.samples[i].stationPressureHPa)
        }
    }

    private func refreshDerivedState() {
        if gate.isStationary,
           model.offset != nil,
           let latest = buffer.samples.last(where: { $0.trusted }) {
            latestLocalSLP = model.slpEquivalent(for: latest.stationPressureHPa)
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
