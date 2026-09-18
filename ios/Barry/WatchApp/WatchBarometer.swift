//  WatchBarometer.swift
//  Barry — watchOS
//
//  The watch's own barometer, for the wearer whose phone is out of reach:
//  a cellular watch at a strip with no station. Foreground only, which is
//  what watchOS allows without a workout session.
//
//  Same engine as the phone (Shared/BarometerEngine.swift): the sensor is
//  tied to the station's altimeter setting, one calibration point per
//  report, median offset with drift, an altitude bridge when the wrist comes
//  to rest somewhere else. What differs is the motion gate. A wrist is never
//  still, but only vertical movement changes the pressure, so the gate is
//  the barometer's own steadiness over the last 20 s: a walk on flat ground
//  passes, stairs and a climbing aircraft fail.

import CoreLocation
import CoreMotion
import Foundation
import SwiftUI

@MainActor
final class WatchBarometer: ObservableObject {
    /// True on watches with a barometer (Series 3 and later); false in the simulator.
    @Published private(set) var isAvailable = false
    /// Calibrated local altimeter-setting equivalent from the newest steady sample.
    @Published private(set) var latestLocalAltim: Double?
    @Published private(set) var isSteady = false
    @Published private(set) var offsetHPa: Double?
    @Published private(set) var calibratedAt: Date?
    @Published private(set) var microTrend: MicroTrend?
    /// GPS-altitude bootstrap before the first station calibration.
    @Published private(set) var provisionalOffset: Double?

    var isCalibrated: Bool { offsetHPa != nil }
    var isProvisional: Bool { offsetHPa == nil && provisionalOffset != nil }

    /// The newest trusted, calibrated sample and when it was taken.
    var lastLocalReading: (altim: Double, at: Date)? {
        guard let s = buffer.samples.last(where: { $0.trusted && $0.calibrated != nil }),
              let v = s.calibrated else { return nil }
        return (v, s.date)
    }

    /// Peak-to-peak spread over the steadiness window below which the wrist
    /// counts as vertically still. 0.10 hPa is about 0.8 m of height.
    static let steadySpreadHPa = 0.10
    static let steadyWindow: TimeInterval = 20
    static let steadyMinSamples = 5
    /// Ignore altitude changes inside GPS noise.
    private static let minBridgeMeters: Double = 4.0
    private static let maxAltitudeAccuracy: Double = 8.0

    private static let storeKey = "watch.barometer.calibration.v1"
    private static let refAltitudeKey = "watch.barometer.refAltitude.v1"

    private var model = CalibrationModel()
    private var buffer = SampleBuffer()
    private var recent: [(Date, Double)] = []
    private var altimeter: CMAltimeter?
    private var lastStationAltim: Double?
    private var lastStationTempC: Double?
    private var lastObsTime: Date?
    private var referenceAltitudeM: Double?
    private var bridgeInFlight = false
    private lazy var altitudeLocation = LocationManager(desiredAccuracy: kCLLocationAccuracyBest)
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "me.wvr.barry.watch.barometer"
        return q
    }()

    init() {
        loadModel()
        referenceAltitudeM = AppConfig.sharedDefaults.object(forKey: Self.refAltitudeKey) as? Double
    }

    // MARK: Lifecycle

    func start() {
        guard altimeter == nil, CMAltimeter.isRelativeAltitudeAvailable() else { return }
        isAvailable = true
        let alt = CMAltimeter()
        altimeter = alt
        alt.startRelativeAltitudeUpdates(to: queue) { [weak self] data, error in
            guard let data, error == nil else { return }
            let hPa = data.pressure.doubleValue * 10.0   // kPa to hPa
            Task { @MainActor [weak self] in self?.handlePressure(hPa) }
        }
        Task {
            await bridgeForAltitudeChangeIfNeeded()
            await bootstrapFromAltitudeIfNeeded()
        }
    }

    func stop() {
        altimeter?.stopRelativeAltitudeUpdates()
        altimeter = nil
        isAvailable = false
        isSteady = false
        recent.removeAll()
    }

    // MARK: Samples

    private func handlePressure(_ hPa: Double) {
        let now = Date()
        recent.append((now, hPa))
        let cutoff = now.addingTimeInterval(-Self.steadyWindow)
        recent.removeAll { $0.0 < cutoff }
        let values = recent.map(\.1)
        let steady = values.count >= Self.steadyMinSamples
            && (values.max()! - values.min()!) <= Self.steadySpreadHPa
        isSteady = steady

        let calibrated = steady ? model.calibrated(for: hPa, at: now) : nil
        let value = calibrated ?? (steady ? provisionalOffset.map { hPa + $0 } : nil)
        buffer.add(BarometerSample(date: now, stationPressureHPa: hPa, calibrated: value,
                                   trusted: steady, stationary: steady))
        latestLocalAltim = value
        microTrend = buffer.microTrend()
    }

    // MARK: Calibration

    /// Call with each fresh report from the station the wearer is physically
    /// at. One point per observation; needs a steady wrist.
    func attemptCalibration(stationAltim: Double, tempC: Double?, observedAt: Date?) {
        lastStationAltim = stationAltim
        lastStationTempC = tempC ?? lastStationTempC
        lastObsTime = observedAt
        if let observedAt, model.containsObservation(observedAt) { return }
        guard isSteady else { return }
        let raw = observedAt.map { buffer.averageStationPressure(around: $0) }
            ?? buffer.averageStationPressure()
        guard let raw else { return }
        let didReset = model.add(CalibrationState.make(stationAltim: stationAltim, phonePressureHPa: raw,
                                                       obsTime: observedAt))
        if didReset { buffer = SampleBuffer() }
        provisionalOffset = nil
        syncOutputs()
        saveModel()
        Task { await updateReferenceAltitude() }
    }

    /// A setting the pilot heard on the radio or read off another source.
    /// Seeds the model like a report would, stamped now.
    func calibrate(manualAltim: Double) {
        guard let raw = buffer.averageStationPressure() else { return }
        model.add(CalibrationState.make(stationAltim: manualAltim, phonePressureHPa: raw, at: Date()))
        provisionalOffset = nil
        syncOutputs()
        saveModel()
        Task { await updateReferenceAltitude() }
    }

    func reset() {
        model = CalibrationModel()
        buffer = SampleBuffer()
        provisionalOffset = nil
        latestLocalAltim = nil
        syncOutputs()
        saveModel()
    }

    private func syncOutputs() {
        offsetHPa = model.offset
        calibratedAt = model.calibratedAt
    }

    // MARK: Altitude

    private struct AltitudeFix { let meters: Double; let accuracy: Double }

    private func sampleAltitude() async -> AltitudeFix? {
        if CMAltimeter.isAbsoluteAltitudeAvailable(), let fix = await sampleAbsoluteAltitude(),
           fix.accuracy <= Self.maxAltitudeAccuracy {
            return fix
        }
        guard let loc = await altitudeLocation.requestLocation(),
              loc.verticalAccuracy > 0, loc.verticalAccuracy <= Self.maxAltitudeAccuracy else { return nil }
        return AltitudeFix(meters: loc.altitude, accuracy: loc.verticalAccuracy)
    }

    private func sampleAbsoluteAltitude(timeout: Double = 4) async -> AltitudeFix? {
        let alt = CMAltimeter()
        let latch = WatchOneShot()
        return await withCheckedContinuation { cont in
            alt.startAbsoluteAltitudeUpdates(to: queue) { data, _ in
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

    private func updateReferenceAltitude() async {
        guard let fix = await sampleAltitude() else { return }
        referenceAltitudeM = fix.meters
        AppConfig.sharedDefaults.set(referenceAltitudeM, forKey: Self.refAltitudeKey)
    }

    /// On opening: if the watch is somewhere else vertically than where it
    /// was calibrated, shift the offsets by the height change times the lapse
    /// rate of the air the station last reported.
    private func bridgeForAltitudeChangeIfNeeded() async {
        guard !bridgeInFlight, model.offset != nil else { return }
        bridgeInFlight = true
        defer { bridgeInFlight = false }
        guard let ref = referenceAltitudeM else { await updateReferenceAltitude(); return }
        guard let fix = await sampleAltitude() else { return }
        let dh = fix.meters - ref
        guard abs(dh) >= Self.minBridgeMeters else { return }
        let p = recent.last?.1 ?? 1000.0
        model.shiftOffsets(by: dh * PressureAltitude.lapseHPaPerMeter(pressureHPa: p, tempC: lastStationTempC))
        referenceAltitudeM = fix.meters
        AppConfig.sharedDefaults.set(referenceAltitudeM, forKey: Self.refAltitudeKey)
        syncOutputs()
        saveModel()
    }

    /// Before any station calibration, a rough setting from altitude alone.
    private func bootstrapFromAltitudeIfNeeded() async {
        guard model.offset == nil, provisionalOffset == nil else { return }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard let raw = recent.last?.1, let fix = await sampleAltitude() else { return }
        provisionalOffset = PressureAltitude.altimeterSetting(rawHPa: raw, altitudeM: fix.meters) - raw
    }

    // MARK: Persistence

    private func loadModel() {
        guard let data = AppConfig.sharedDefaults.data(forKey: Self.storeKey),
              var stored = try? JSONDecoder().decode(CalibrationModel.self, from: data) else { return }
        stored.prune(now: Date())
        model = stored
        syncOutputs()
    }

    private func saveModel() {
        if let data = try? JSONEncoder().encode(model) {
            AppConfig.sharedDefaults.set(data, forKey: Self.storeKey)
        }
    }
}

/// First caller wins; the rest are no-ops.
@MainActor
private final class WatchOneShot {
    private var taken = false
    func claim() -> Bool {
        if taken { return false }
        taken = true
        return true
    }
}
