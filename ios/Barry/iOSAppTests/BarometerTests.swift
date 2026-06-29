//  BarometerTests.swift
//  BarryTests
//
//  §4.5.7 synthetic test cases for the phone barometer enrichment logic.
//  All tests operate on the pure value types (CalibrationState, MotionGate,
//  SampleBuffer) — no Core Motion hardware required.

import Foundation
import Testing
@testable import Barry

struct BarometerTests {

    // MARK: §4.5.7 Test 1 — Datum correction
    //
    // Phone station pressure 990 hPa + METAR SLP 1014 → offset = +24.
    // Subsequent phone reading 989 → phone_slp_equiv = 1013.

    @Test func datumCorrection() {
        let cal = CalibrationState.make(metarSLP: 1014, phonePressureHPa: 990)
        #expect(cal.offset == 24.0)
        #expect(cal.slpEquivalent(for: 989) == 1013.0)
    }

    // MARK: §4.5.7 Test 2 — Elevator spike rejected
    //
    // Stationary baseline; a −4 hPa step over 30 s is flagged as vertical motion
    // (device goes moving). Those samples must be untrusted and must NOT produce
    // a falling_fast micro-trend.

    @Test func elevatorSpikeRejected() {
        var gate = MotionGate(state: .stationary)
        var buffer = SampleBuffer()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let cal = CalibrationState.make(metarSLP: 1014, phonePressureHPa: 990, at: t0)

        // Five stationary baseline samples.
        for i in 0..<5 {
            let p = 990.0
            buffer.add(BarometerSample(
                date: t0.addingTimeInterval(Double(i) * 60),
                stationPressureHPa: p,
                slpEquivalent: cal.slpEquivalent(for: p),
                trusted: gate.isStationary
            ))
        }

        // Elevator: motion detected, gate flips to moving.
        gate.process(stationaryActivity: false, at: t0.addingTimeInterval(300))
        #expect(gate.isMoving)

        // Mark existing buffer samples untrusted (mirrors BarometerManager behaviour).
        for i in buffer.samples.indices { buffer.samples[i].trusted = false }

        // Spike samples added during motion — must be untrusted.
        for i in 6..<10 {
            let spikedPressure = 986.0  // −4 hPa, like ascending a few floors
            buffer.add(BarometerSample(
                date: t0.addingTimeInterval(Double(i) * 30),
                stationPressureHPa: spikedPressure,
                slpEquivalent: nil,   // no calibration while moving
                trusted: gate.isStationary
            ))
        }

        let trusted = buffer.trustedSamples()
        #expect(trusted.isEmpty, "No trusted samples should remain after motion transition")

        let trend = buffer.microTrend()
        #expect(trend == nil, "Elevator spike must not produce a micro-trend")
    }

    // MARK: §4.5.7 Test 3 — Drive then stop
    //
    // Automotive activity → no recalibration during drive → stationary detected
    // → settling state set → settle deadline elapsed → stationary again.

    @Test func driveThenStop() {
        var gate = MotionGate(state: .stationary)
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // Start moving (driving).
        gate.process(stationaryActivity: false, at: t0)
        #expect(gate.isMoving, "Gate must be moving after non-stationary activity")

        // Stop the car — stationary activity detected.
        let tStop = t0.addingTimeInterval(20 * 60)
        gate.process(stationaryActivity: true, at: tStop)
        // Must be in .settling, not yet .stationary.
        if case .settling(let until) = gate.state {
            #expect(until > tStop, "Settle deadline must be in the future")
        } else {
            Issue.record("Expected .settling state immediately after stopping")
        }

        // Simulate time passing: activity update after settle deadline.
        let tAfterSettle = tStop.addingTimeInterval(MotionGate.settleSeconds + 10)
        gate.process(stationaryActivity: true, at: tAfterSettle)
        #expect(gate.isStationary, "Gate must be stationary after settle period elapses")
    }

    // MARK: §4.5.7 Test 4 — Uncalibrated mode
    //
    // Without a calibration applied, slpEquivalent is nil on all samples.
    // microTrend() must return nil — no absolute-axis value exposed.

    @Test func uncalibratedModeNoMicroTrend() {
        var buffer = SampleBuffer()
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // Add 10 stationary samples but with no slpEquivalent (uncalibrated).
        for i in 0..<10 {
            buffer.add(BarometerSample(
                date: t0.addingTimeInterval(Double(i) * 60),
                stationPressureHPa: 990.0,
                slpEquivalent: nil,  // ← uncalibrated
                trusted: true
            ))
        }

        #expect(buffer.trustedSamples().isEmpty,
                "trustedSamples() filters out samples without slpEquivalent")
        #expect(buffer.microTrend() == nil,
                "No micro-trend without calibration")
        #expect(buffer.phoneTrace().isEmpty,
                "phoneTrace() must be empty when uncalibrated")
    }

    // MARK: §4.5.7 Test 5 — Real local fall
    //
    // Stationary + calibrated; −0.8 hPa over 40 min of trusted samples.
    // microTrend() must report the genuine local fall.

    @Test func realLocalFallSurfaces() {
        var buffer = SampleBuffer()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let cal = CalibrationState.make(metarSLP: 1014, phonePressureHPa: 990, at: t0)

        // 9 samples over 40 min, pressure falling 0.1 hPa per step (−0.8 total).
        for i in 0...8 {
            let phonePressure = 990.0 - Double(i) * 0.1
            buffer.add(BarometerSample(
                date: t0.addingTimeInterval(Double(i) * 5 * 60),  // every 5 min
                stationPressureHPa: phonePressure,
                slpEquivalent: cal.slpEquivalent(for: phonePressure),
                trusted: true
            ))
        }

        let trend = buffer.microTrend()
        #expect(trend != nil, "A real local fall must produce a micro-trend")
        #expect((trend?.deltaHPa ?? 0) < -0.5,
                "Micro-trend delta should reflect the ~0.8 hPa fall")
        #expect((trend?.windowMinutes ?? 0) >= 5,
                "Window must be at least 5 min")
    }

    // MARK: - Calibration averaging (Task 5)

    @Test func averageStationPressureSmoothsJitter() {
        var buffer = SampleBuffer()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // Stationary samples jittering ±1 hPa around 1000 over 4 min → mean 1000.
        for (i, v) in [999.0, 1001.0, 1000.0, 1001.0, 999.0].enumerated() {
            buffer.add(BarometerSample(date: t0.addingTimeInterval(Double(i) * 60),
                                       stationPressureHPa: v, slpEquivalent: nil, trusted: true))
        }
        #expect(abs((buffer.averageStationPressure() ?? 0) - 1000.0) < 1e-9)
    }

    @Test func averageStationPressureExcludesOldAndMovingSamples() {
        var buffer = SampleBuffer()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // Stationary but 10 min before the latest → outside the 5-min window.
        buffer.add(BarometerSample(date: t0, stationPressureHPa: 950.0,
                                   slpEquivalent: nil, trusted: true))
        // Untrusted (moving) spike inside the window → excluded.
        buffer.add(BarometerSample(date: t0.addingTimeInterval(540), stationPressureHPa: 800.0,
                                   slpEquivalent: nil, trusted: false))
        // Two trusted samples inside the window → averaged (1000, 1002 → 1001).
        buffer.add(BarometerSample(date: t0.addingTimeInterval(560), stationPressureHPa: 1000.0,
                                   slpEquivalent: nil, trusted: true))
        buffer.add(BarometerSample(date: t0.addingTimeInterval(600), stationPressureHPa: 1002.0,
                                   slpEquivalent: nil, trusted: true))
        #expect(buffer.averageStationPressure() == 1001.0)
    }

    @Test func averageStationPressureNilWhenEmpty() {
        #expect(SampleBuffer().averageStationPressure() == nil)
    }

    // MARK: - Bonus: altitude-jump detection resets buffer

    @Test func altitudeJumpDetected() {
        let existing = CalibrationState.make(metarSLP: 1014, phonePressureHPa: 990)
        let afterElevator = CalibrationState.make(metarSLP: 1014, phonePressureHPa: 975)
        #expect(isAltitudeJump(from: existing, to: afterElevator),
                "A 15-hPa station-pressure shift should register as an altitude jump")

        let normalRecal = CalibrationState.make(metarSLP: 1014, phonePressureHPa: 989)
        #expect(!isAltitudeJump(from: existing, to: normalRecal),
                "A 1-hPa recalibration drift should not trigger an altitude jump")
    }

    // MARK: - CalibrationModel (multi-point, robust offset + drift)

    @Test func modelAveragesOffsets() {
        var m = CalibrationModel()
        let t = Date(timeIntervalSince1970: 1_000_000)
        m.add(CalibrationState.make(metarSLP: 1014, phonePressureHPa: 990, at: t))                    // +24
        m.add(CalibrationState.make(metarSLP: 1014, phonePressureHPa: 989,
                                    at: t.addingTimeInterval(3600)))                                  // +25
        #expect(m.offset == 24.5, "Robust offset is the mean of retained points")
        #expect(m.slpEquivalent(for: 990) == 1014.5)
    }

    @Test func modelAltitudeJumpResetsHistory() {
        var m = CalibrationModel()
        let t = Date(timeIntervalSince1970: 1_000_000)
        m.add(CalibrationState.make(metarSLP: 1014, phonePressureHPa: 990, at: t))                    // +24
        let didReset = m.add(CalibrationState.make(metarSLP: 1014, phonePressureHPa: 975,
                                                   at: t.addingTimeInterval(1800)))                   // +39
        #expect(didReset, "A 15-hPa offset jump should reset the model")
        #expect(m.points.count == 1)
        #expect(m.offset == 39.0)
    }

    @Test func modelDetectsDrift() {
        var m = CalibrationModel()
        let t = Date(timeIntervalSince1970: 1_000_000)
        // Offset climbing ~1 hPa/hr — slow sensor drift, not an altitude jump.
        m.add(CalibrationState.make(metarSLP: 1010, phonePressureHPa: 990, at: t))                    // +20
        m.add(CalibrationState.make(metarSLP: 1011, phonePressureHPa: 990,
                                    at: t.addingTimeInterval(3600)))                                  // +21
        m.add(CalibrationState.make(metarSLP: 1012, phonePressureHPa: 990,
                                    at: t.addingTimeInterval(7200)))                                  // +22
        #expect((m.driftPerHour ?? 0) > 0.9 && (m.driftPerHour ?? 0) < 1.1,
                "Drift slope should be ~1 hPa/hr")
    }

    // MARK: - Drift-projected offset (Task 4)

    @Test func offsetFallsBackToMeanWithoutDrift() {
        var m = CalibrationModel()
        let t = Date(timeIntervalSince1970: 1_000_000)
        m.add(CalibrationState.make(metarSLP: 1014, phonePressureHPa: 990, at: t))                    // +24
        m.add(CalibrationState.make(metarSLP: 1014, phonePressureHPa: 989,
                                    at: t.addingTimeInterval(3600)))                                  // +25
        // Only 2 points → no drift estimate → flat mean.
        #expect(m.offset(at: t.addingTimeInterval(7200)) == 24.5)
    }

    @Test func offsetProjectsDriftForward() {
        var m = CalibrationModel()
        let t = Date(timeIntervalSince1970: 1_000_000)
        m.add(CalibrationState.make(metarSLP: 1010, phonePressureHPa: 990, at: t))                    // +20
        m.add(CalibrationState.make(metarSLP: 1011, phonePressureHPa: 990,
                                    at: t.addingTimeInterval(3600)))                                  // +21
        m.add(CalibrationState.make(metarSLP: 1012, phonePressureHPa: 990,
                                    at: t.addingTimeInterval(7200)))                                  // +22  (slope ~1/h)
        // At the last point the trend value ≈ +22 (vs flat mean +21).
        #expect(abs((m.offset(at: t.addingTimeInterval(7200)) ?? 0) - 22.0) < 0.05)
        // 1h past the last point it keeps rising along the trend.
        #expect((m.offset(at: t.addingTimeInterval(7200 + 3600)) ?? 0) > 22.0)
    }

    @Test func offsetExtrapolationIsClamped() {
        var m = CalibrationModel()
        let t = Date(timeIntervalSince1970: 1_000_000)
        m.add(CalibrationState.make(metarSLP: 1010, phonePressureHPa: 990, at: t))                    // +20
        m.add(CalibrationState.make(metarSLP: 1013, phonePressureHPa: 990,
                                    at: t.addingTimeInterval(3600)))                                  // +23
        m.add(CalibrationState.make(metarSLP: 1016, phonePressureHPa: 990,
                                    at: t.addingTimeInterval(7200)))                                  // +26  (slope ~3/h)
        let mean = m.offset ?? 0  // 23
        // Far-future projection is clamped to mean ± maxDriftDeviation.
        let far = m.offset(at: t.addingTimeInterval(7200 + 100 * 3600)) ?? 0
        #expect(far <= mean + CalibrationModel.maxDriftDeviation + 1e-6)
    }

    @Test func modelPrunesOldPoints() {
        var m = CalibrationModel()
        let t = Date(timeIntervalSince1970: 1_000_000)
        m.add(CalibrationState.make(metarSLP: 1014, phonePressureHPa: 990, at: t))
        // 7h later — the first point is older than the 6h window and is pruned.
        m.add(CalibrationState.make(metarSLP: 1014, phonePressureHPa: 990,
                                    at: t.addingTimeInterval(7 * 3600)))
        #expect(m.points.count == 1, "Points older than 6h are dropped")
    }

    // MARK: - PressureHistory (persisted, downsampled long-horizon log — Task 2)

    @Test func historyDownsamplesRapidSamples() {
        var h = PressureHistory()
        let t = Date(timeIntervalSince1970: 1_000_000)
        // Trusted samples arrive every 30s; only points ≥ minSampleInterval apart store.
        var stored = 0
        for i in 0..<20 {
            if h.record(slp: 1013.0, at: t.addingTimeInterval(Double(i) * 30)) { stored += 1 }
        }
        // 20 samples × 30s = 9.5 min span; at a 2.5-min floor that's the first point
        // plus one roughly every 5 samples.
        #expect(stored == h.entries.count, "record() return value matches stored count")
        #expect(h.entries.count >= 3 && h.entries.count <= 5,
                "10 min at a 2.5-min floor stores ~4 points, got \(h.entries.count)")
    }

    @Test func historyThrottlesTooSoonAndOutOfOrder() {
        var h = PressureHistory()
        let t = Date(timeIntervalSince1970: 1_000_000)
        let first = h.record(slp: 1013.0, at: t)
        let tooSoon = h.record(slp: 1013.1, at: t.addingTimeInterval(60))
        let outOfOrder = h.record(slp: 1012.0, at: t.addingTimeInterval(-300))
        #expect(first, "First point always stores")
        #expect(!tooSoon, "A point 60s later is throttled (< 2.5 min)")
        #expect(!outOfOrder, "An out-of-order (earlier) timestamp is ignored")
        #expect(h.entries.count == 1)

        let later = h.record(slp: 1014.0, at: t.addingTimeInterval(200))
        #expect(later, "A point past the 2.5-min floor stores")
        #expect(h.entries.count == 2)
    }

    @Test func historyRetainsAboutFortyEightHours() {
        var h = PressureHistory()
        let t = Date(timeIntervalSince1970: 1_000_000)
        // One point every 30 min across 50 h — older-than-48h points get pruned.
        for i in 0..<100 {
            h.record(slp: 1013.0, at: t.addingTimeInterval(Double(i) * 30 * 60))
        }
        let newest = h.entries.last!.date
        let span = newest.timeIntervalSince(h.entries.first!.date)
        #expect(span <= PressureHistory.maxAgeSeconds,
                "Retained span must not exceed the 48h window")
        #expect(h.entries.allSatisfy {
            newest.timeIntervalSince($0.date) <= PressureHistory.maxAgeSeconds
        }, "No retained point is older than 48h relative to the newest")
    }

    @Test func historyTraceIsChronological() {
        var h = PressureHistory()
        let t = Date(timeIntervalSince1970: 1_000_000)
        h.record(slp: 1013.0, at: t)
        h.record(slp: 1012.5, at: t.addingTimeInterval(200))
        h.record(slp: 1012.0, at: t.addingTimeInterval(400))
        let trace = h.trace()
        #expect(trace.count == 3)
        #expect(trace.map(\.0) == h.entries.map(\.date), "Trace preserves order")
        #expect(trace.map(\.1) == [1013.0, 1012.5, 1012.0])
    }

    @Test func historyCodableRoundTrips() throws {
        var h = PressureHistory()
        let t = Date(timeIntervalSince1970: 1_000_000)
        h.record(slp: 1013.0, at: t)
        h.record(slp: 1012.0, at: t.addingTimeInterval(200))
        let data = try JSONEncoder().encode(h)
        let decoded = try JSONDecoder().decode(PressureHistory.self, from: data)
        #expect(decoded == h, "PressureHistory survives a Codable round-trip")
    }
}
