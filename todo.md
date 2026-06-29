# Barry — local barometer vs METAR flow

Work tracker for the local-sensor / METAR provenance + calibration features.
Building in the working tree (not committing per-change). Build after each phase.

## Phase 1 — Calibration engine (persistence + multi-point) ✅
- [x] `CalibrationModel` keeps last N points (~6h) and derives a robust (mean) offset
- [x] Drift detection: slope of offset vs time → `driftPerHour`
- [x] Altitude-jump reset (large deviation from robust offset)
- [x] Persist the calibration model across launches (App Group UserDefaults)
- [x] Expose `calibratedAt`, `offsetHPa`, `driftPerHour`, `lastResetWasAltitude`
- [x] Extended `BarometerTests` for the new model (4 new tests)

## Phase 2 — Provenance on the value (the core ask) ✅
- [x] Live reading: extra precision (inHg 3dp / hPa 0.1) + `LOCAL` pill, orange
- [x] METAR: coarser precision (inHg 2dp / hPa 0) + existing age caption
- [x] Tap the value to compare: "station 29.92 · phone −0.04"

## Phase 3 — Calibration transparency & control ✅
- [x] Freshness line: "calibrated 12m ago vs KLUK"
- [x] Stale handling: > ~75 min dims the live value + orange "calibration stale"
- [x] Manual "Recalibrate" button (calls `barometer.recalibrate()`)
- [x] Altitude-change note when calibration resets
- [x] Bonus: drift surfaced when ≥ 0.3 hPa/h

## Phase 4 — Micro-trend as the lead signal ✅
- [x] Local micro-trend highlighted (orange) when sharper than the 3h METAR tendency
- [x] "falling/rising faster than the station shows" clause

## Phase 5 — Chart integration ✅
- [x] Divergence band: shaded gap between last METAR baseline and the live trace

## Phase 6 — Notifications (rapid local fall)  — DEFERRED (user chose to skip)
- [ ] Local notification when the micro-trend crosses the rapid-fall threshold
- Revisit decision when picked up: foreground/active-only (easy, no entitlement)
  vs. true background monitoring via the `location` background mode
  (battery + App Store justification, keeps CMAltimeter alive).

## Notes / decisions
- Base sensor reading is station pressure (kPa×10 → hPa); SLP-equivalent = +offset.
- Persisted store: calibration model only (sparse, ~hourly). The 60-min micro-trend
  sample buffer stays session-scoped.
