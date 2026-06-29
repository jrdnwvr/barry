//  BarometerTests.swift
//  BarryTests
//
//  §4.5.7 synthetic test cases for the phone barometer enrichment logic.
//  All tests operate on the pure value types (CalibrationState, MotionGate,
//  SampleBuffer) — no Core Motion hardware required.

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
}
