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
        #expect(m.offset == 24.5, "Robust offset (median; = mean for 2 points)")
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
        // 13h later — the first point is older than the 12h window and is pruned.
        m.add(CalibrationState.make(metarSLP: 1014, phonePressureHPa: 990,
                                    at: t.addingTimeInterval(13 * 3600)))
        #expect(m.points.count == 1, "Points older than the retention window are dropped")
    }

    @Test func offsetIsMedianNotMean() {
        var m = CalibrationModel()
        let t = Date(timeIntervalSince1970: 1_000_000)
        // Two agreeing points + one 4-hPa outlier (inside the 5-hPa jump gate, so
        // it's retained). Median ignores it; a mean would be dragged ~1.3 hPa.
        m.add(CalibrationState.make(metarSLP: 1014, phonePressureHPa: 990, at: t))          // +24.0
        m.add(CalibrationState.make(metarSLP: 1014.2, phonePressureHPa: 990,
                                    at: t.addingTimeInterval(3600)))                        // +24.2
        m.add(CalibrationState.make(metarSLP: 1018, phonePressureHPa: 990,
                                    at: t.addingTimeInterval(7200)))                        // +28.0 outlier
        #expect(abs((m.offset ?? 0) - 24.2) < 1e-9, "Median resists a single outlier point")
    }

    @Test func modelTracksObservationDedupe() {
        var m = CalibrationModel()
        let t = Date(timeIntervalSince1970: 1_000_000)
        let obs = t.addingTimeInterval(-600)
        m.add(CalibrationState.make(metarSLP: 1014, phonePressureHPa: 990, at: t, obsTime: obs))
        #expect(m.containsObservation(obs), "The paired obs is remembered")
        #expect(!m.containsObservation(obs.addingTimeInterval(3600)),
                "A new obs is not falsely deduped")
    }

    @Test func averageAroundObsTimePairsLikeWithLike() {
        var b = SampleBuffer()
        let t = Date(timeIntervalSince1970: 1_000_000)
        // Pressure fell 0.6 hPa between the obs (at t) and "now" (t+30 min).
        b.add(BarometerSample(date: t, stationPressureHPa: 1000.0,
                              slpEquivalent: nil, trusted: true, stationary: true))
        b.add(BarometerSample(date: t.addingTimeInterval(1800), stationPressureHPa: 999.4,
                              slpEquivalent: nil, trusted: true, stationary: true))
        // Around the obs time → the reading taken THEN, not the newer one.
        #expect(b.averageStationPressure(around: t) == 1000.0)
        // No samples near a much older obs → falls back to the trailing average.
        #expect(b.averageStationPressure(around: t.addingTimeInterval(-7200)) != nil)
    }

    // MARK: - Range analysis (drag-select a chart window)

    private func series(hours: Int, stepMin: Double = 60,
                        f: (Double) -> Double) -> [(Date, Double)] {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let n = Int(Double(hours) * 60 / stepMin)
        return (0...n).map { i in
            let h = Double(i) * stepMin / 60
            return (t0.addingTimeInterval(h * 3600), f(h))
        }
    }

    @Test func tideDayReadsAsBreathing() {
        // ±1.2 hPa semidiurnal wave, no net change, over 24 h.
        let pts = series(hours: 24) { 1015 + 1.2 * sin($0 / 12 * 2 * .pi) }
        let a = RangeAnalysis.analyze(points: pts, forecastStartsAt: nil)
        #expect(a?.title == "The atmosphere breathing")
        #expect(abs(a?.netHPa ?? 9) < 0.3)
    }

    @Test func flatDayReadsAsCalm() {
        let pts = series(hours: 20) { 1018 + 0.2 * sin($0) }
        let a = RangeAnalysis.analyze(points: pts, forecastStartsAt: nil)
        #expect(a?.title == "Dead calm")
    }

    @Test func vShapeReadsAsTrough() {
        // Fall 4 hPa to an interior low, then recover.
        let pts = series(hours: 12) { h in 1015 - 4 * exp(-pow((h - 6) / 2.2, 2)) }
        let a = RangeAnalysis.analyze(points: pts, forecastStartsAt: nil)
        #expect(a?.title == "A trough passed")
    }

    @Test func sustainedDropReadsAsFall() {
        let pts = series(hours: 6) { 1015 - 0.6 * $0 }  // −3.6 over 6 h (−1.8/3h)
        let a = RangeAnalysis.analyze(points: pts, forecastStartsAt: nil)
        #expect(a?.title == "A steady fall")
        #expect((a?.steepest3hHPa ?? 0) < 0)
    }

    @Test func tinyWindowIsHonestlyShort() {
        let pts = series(hours: 1, stepMin: 30) { 1015 - $0 }
        let a = RangeAnalysis.analyze(points: pts, forecastStartsAt: nil)
        #expect(a?.title == "Too short to read")
    }

    @Test func forecastPortionIsFlagged() {
        let pts = series(hours: 10) { 1015 - 0.4 * $0 }
        let boundary = pts[4].0  // "now" sits inside the window
        let a = RangeAnalysis.analyze(points: pts, forecastStartsAt: boundary)
        #expect(a?.includesForecast == true)
    }

    // MARK: - Carried-clean physics gating (trusting data while classifier says moving)

    @Test func carriedFlatPressureIsClean() {
        var b = SampleBuffer()
        let t = Date(timeIntervalSince1970: 1_000_000)
        // Hand-carried around one floor: raw wobbles ±0.02 hPa.
        for i in 0..<6 {
            b.add(BarometerSample(date: t.addingTimeInterval(Double(i) * 20),
                                  stationPressureHPa: 1000.0 + 0.02 * Double(i % 2),
                                  slpEquivalent: nil, trusted: false, stationary: false))
        }
        #expect(b.isCleanWhileMoving(candidateHPa: 1000.03, at: t.addingTimeInterval(120)),
                "Weather-plausible pressure while moving is trusted")
    }

    @Test func elevatorRateRejectedWhileMoving() {
        var b = SampleBuffer()
        let t = Date(timeIntervalSince1970: 1_000_000)
        // Elevator: ~1 m/s = 0.12 hPa/s — unmistakable vs weather.
        for i in 0..<6 {
            b.add(BarometerSample(date: t.addingTimeInterval(Double(i) * 20),
                                  stationPressureHPa: 1000.0 - 2.4 * Double(i),
                                  slpEquivalent: nil, trusted: false, stationary: false))
        }
        #expect(!b.isCleanWhileMoving(candidateHPa: 1000.0 - 2.4 * 6,
                                      at: t.addingTimeInterval(120)),
                "Elevator-rate pressure change is rejected")
    }

    @Test func slowRampCaughtByLongWindow() {
        var b = SampleBuffer()
        let t = Date(timeIntervalSince1970: 1_000_000)
        // Gentle sustained climb: +0.04 hPa per 30 s stays inside each short window
        // (spread ≈ 0.16 ≤ 0.25) but accumulates 0.8 hPa over 10 min.
        for i in 0..<20 {
            b.add(BarometerSample(date: t.addingTimeInterval(Double(i) * 30),
                                  stationPressureHPa: 1000.0 + 0.04 * Double(i),
                                  slpEquivalent: nil, trusted: false, stationary: false))
        }
        #expect(!b.isCleanWhileMoving(candidateHPa: 1000.8, at: t.addingTimeInterval(600)),
                "A slow ramp must be caught by the long accumulation window")
    }

    @Test func coldBufferIsNotClean() {
        let b = SampleBuffer()
        #expect(!b.isCleanWhileMoving(candidateHPa: 1000.0, at: Date()),
                "No recent context proves nothing — stay conservative")
    }

    @Test func untrustRecentIsScoped() {
        var b = SampleBuffer()
        let t = Date(timeIntervalSince1970: 1_000_000)
        b.add(BarometerSample(date: t, stationPressureHPa: 1000.0,
                              slpEquivalent: 1013.0, trusted: true))
        b.add(BarometerSample(date: t.addingTimeInterval(540), stationPressureHPa: 1000.1,
                              slpEquivalent: 1013.1, trusted: true))
        // Motion detected at t+600 → only the classifier-lag window is suspect.
        b.untrustRecent(since: t.addingTimeInterval(600 - 90))
        #expect(b.samples[0].trusted, "Old, provably-still data survives")
        #expect(!b.samples[1].trusted && !b.samples[1].stationary,
                "Data inside the lag window is demoted from both tiers")
    }

    @Test func calibrationAverageUsesOnlyStationaryGrade() {
        var b = SampleBuffer()
        let t = Date(timeIntervalSince1970: 1_000_000)
        b.add(BarometerSample(date: t, stationPressureHPa: 1000.0,
                              slpEquivalent: nil, trusted: true, stationary: true))
        // Carried-clean sample: display-trusted, but NOT calibration-grade.
        b.add(BarometerSample(date: t.addingTimeInterval(60), stationPressureHPa: 1010.0,
                              slpEquivalent: nil, trusted: true, stationary: false))
        #expect(b.averageStationPressure() == 1000.0,
                "Carried samples must never feed the calibration offset")
    }

    // MARK: - Altitude bridge (GPS-referenced offset shifting)

    @Test func shiftOffsetsMovesAllPointsUniformly() {
        var m = CalibrationModel()
        let t = Date(timeIntervalSince1970: 1_000_000)
        m.add(CalibrationState(offset: 10.0, calibratedAt: t))
        m.add(CalibrationState(offset: 10.4, calibratedAt: t.addingTimeInterval(600)))
        // Climb 20 m → raw pressure drops ~2.36 hPa → offset must grow to match.
        m.shiftOffsets(by: 20 * PressureAltitude.hPaPerMeter)
        #expect(abs((m.offset ?? 0) - (10.2 + 2.36)) < 0.01,
                "Mean offset shifts by Δh × hPa/m")
    }

    @Test func shiftOffsetsPreservesDrift() {
        var m = CalibrationModel()
        let t = Date(timeIntervalSince1970: 1_000_000)
        // 0.5 hPa/h drift across 3 points.
        for i in 0..<3 {
            m.add(CalibrationState(offset: 10.0 + 0.5 * Double(i),
                                   calibratedAt: t.addingTimeInterval(Double(i) * 3600)))
        }
        let before = m.driftPerHour
        m.shiftOffsets(by: 2.4)
        #expect(before != nil && m.driftPerHour != nil)
        #expect(abs((m.driftPerHour ?? 0) - (before ?? 0)) < 1e-9,
                "A uniform shift must not change the drift slope")
    }

    @Test func standardAtmosphereReduction() {
        // At sea level the reduction is the identity.
        #expect(abs(PressureAltitude.standardSLP(rawHPa: 1013.25, altitudeM: 0) - 1013.25) < 1e-9)
        // At 200 m, SLP ≈ raw + ~23.6 hPa (0.118 hPa/m regime).
        let slp = PressureAltitude.standardSLP(rawHPa: 990.0, altitudeM: 200)
        #expect(abs(slp - (990.0 + 200 * PressureAltitude.hPaPerMeter)) < 0.5,
                "ISA reduction should agree with the linear rate for small heights, got \(slp)")
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
        // 20 samples × 30s = 9.5 min span; at a 1-min floor that's the first point
        // plus one roughly every other sample.
        #expect(stored == h.entries.count, "record() return value matches stored count")
        #expect(h.entries.count >= 8 && h.entries.count <= 11,
                "9.5 min at a 1-min floor stores ~10 points, got \(h.entries.count)")
    }

    @Test func historyThrottlesTooSoonAndOutOfOrder() {
        var h = PressureHistory()
        let t = Date(timeIntervalSince1970: 1_000_000)
        let first = h.record(slp: 1013.0, at: t)
        let tooSoon = h.record(slp: 1013.1, at: t.addingTimeInterval(30))
        let outOfOrder = h.record(slp: 1012.0, at: t.addingTimeInterval(-300))
        #expect(first, "First point always stores")
        #expect(!tooSoon, "A point 30s later is throttled (< 1 min)")
        #expect(!outOfOrder, "An out-of-order (earlier) timestamp is ignored")
        #expect(h.entries.count == 1)

        let later = h.record(slp: 1014.0, at: t.addingTimeInterval(90))
        #expect(later, "A point past the 1-min floor stores")
        #expect(h.entries.count == 2)

        // `force` bypasses the downsample throttle but not the ordering guard.
        let forced = h.record(slp: 1014.5, at: t.addingTimeInterval(100), force: true)
        let forcedOutOfOrder = h.record(slp: 1011.0, at: t.addingTimeInterval(50), force: true)
        #expect(forced, "A forced (manual) point stores even within the 1-min floor")
        #expect(!forcedOutOfOrder, "force does not override the out-of-order guard")
        #expect(h.entries.count == 3)
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
