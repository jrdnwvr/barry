# Off-field pressure: watch barometer, the local model, rural use

Written 2026-09-18. Companion to ROADMAP section H.

## 1. What exists today

- The phone streams `CMAltimeter` at 1 Hz while the app is in front. A motion
  gate (activity classifier + 45 s settle) decides which samples are
  calibration grade; a physics check (pressure spread over 2 and 10 min)
  keeps hand-carried samples usable for display.
- Calibration: `offset = station value − phone raw`, one point per METAR
  observation, up to 12 points over 12 h, median offset, least-squares drift
  with capped extrapolation. A 5 hPa jump resets history as an altitude
  change; smaller moves are bridged with absolute altitude × 0.118 hPa/m.
- The station value is `current.slp ?? series.last.pressure`, and
  `pressure` is `slp ?? altim`. So at KLUK the phone is calibrated to
  sea-level pressure and at KI67 (no SLP in its METAR) to the altimeter
  setting, without the code knowing which.
- The watch app has no sensor code at all.

## 2. Watch barometer: integration plan

Status 2026-09-18: W1 through W8 built (`WatchApp/WatchBarometer.swift`,
`PhoneSync`/`WatchSync` carry `selectionPhysical`, `ManualAltimeterView`).
Untested on a real watch; the simulator has no barometer.

The case it serves: a cellular watch with no phone in range, at a strip with
no station. Everything below keeps the sensor foreground-only, which is what
watchOS allows without a workout session.

**W1. Share the engine.** Move `BarometerEngine.swift` (pure value types:
samples, calibration model, motion gate, buffer, altitude helpers) from
`iOSApp/` to `Shared/`. No code change; the watch target picks it up. The
iOS tests keep covering it.

**W2. `WatchBarometer`** (watchOS only, ~150 lines). Streams
`startRelativeAltitudeUpdates` while the app is active (watchOS delivers a
sample every 1 to 2.5 s). No activity classifier on the wrist: the gate is the
barometer's own steadiness, the same 0.10 hPa peak-to-peak test the phone's
"Measure now" uses, over a 20 s window. A wrist swinging while walking on flat
ground passes; stairs, an elevator, a climbing aircraft fail. Uses the shared
`CalibrationModel`, persisted in the watch's own App Group store (its sensor,
its bias, its history).

**W3. Calibrate only when physically at the station.** The phone's rule is
"selection is My location". The watch needs the same knowledge: add
`isPhysical` to the WatchConnectivity context (true for My location, false for
a saved airport or place). Calibrate when `isPhysical` or the 3 NM rule holds,
against the station's altimeter setting (see M1), paired at the observation
time exactly as the phone does.

**W4. Altitude bridge on the wrist.** `CMAltimeter.isAbsoluteAltitudeAvailable`
is true on watches with GPS (SE and Series 6 onward, watchOS 8+). Same
bridge as the phone: stamp the datum at calibration, shift offsets by
Δh × lapse when the watch comes to rest somewhere else. Where absolute
altitude is unavailable, fall back to CoreLocation's vertical fix with the
same 8 m accuracy gate.

**W5. Station resolution without the phone.** When `WCSession.isReachable` is
false and the synced selection is My location, the watch resolves the nearest
station from its own position (`PressureStore.resolveStationFromLocation`
already exists and is unused on the watch). With the phone reachable, keep
following the phone.

**W6. Show it.** Headline follows the phone's rule: at an airport the field's
altimeter setting; elsewhere the local sensor when calibrated and fresh, with
the live dot; otherwise the station value. A second line off-field:
"altimeter here ≈ 29.94" with the age of the calibration. The snapshot gains
`localAltimeterHPa` so the complication can show the same number until it
goes stale (2 h, same rule as everything else).

**W7. Plumbing.** `NSMotionUsageDescription` in the watch Info.plist. Settings
toggle on the watch, off by default, mirroring the phone's. A "Measure now"
button on the watch page for a deliberate reading.

**W8. Manual entry as the floor.** A pilot with a reported setting from a
radio or a phone call can type it. It seeds the calibration the same way a
METAR does, marked "manual" and expiring after 3 h. This is the feature that
works with no data at all.

Order: W1, W3 (context field, phone side), W2 + W4, W6 + W7, W5, W8. About a
day and a half. Nothing here needs the backend.

## 3. The local pressure model: what to change

Status 2026-09-18: M1 and M2 done (calibration to the altimeter setting,
lapse from the reported temperature). M3 to M5 open.

**M1. Calibrate to the altimeter setting, not sea-level pressure.** Every
METAR carries an altimeter setting; only some carry SLP, and rural AWOS
often does not. The two differ by the temperature reduction (QFF vs QNH):
under 1 hPa at Ohio Valley elevations on a normal day, several hPa at
mountain fields in winter or summer. Today the offset silently mixes the
two depending on which station calibrated it, and the 5 hPa jump gate could
fire on a station change in extreme temperatures. Fix: `offset = altim −
raw` everywhere, and derive SLP for the trend headline by adding the
station's own `slp − altim` when it reports both. The pilot-facing number
becomes exactly what is dialed in. This is the one change that matters.

**M2. Lapse rate from the air, not a constant.** The bridge uses 0.118 hPa/m.
The real figure is p·g/(R·T): 0.120 at 15 °C, 0.114 at 30 °C, 0.131 at
−10 °C. A 100 m move at −10 °C is 1.3 hPa (0.04 inHg) off with the constant.
Compute it from the METAR temperature and the raw pressure. Ten lines.

**M3. Elevation term made explicit.** Store the sensor bias separately from
the elevation term: `bias = altim_at_station − ISA(raw, device elevation)`.
The bias is a property of the chip and drifts slowly; the elevation term is
recomputed from the current absolute altitude every time the device rests.
This replaces "shift all offsets by Δh" with a model that also survives a
move made while the app was closed and needs no 5 hPa jump heuristic. Keep
the jump gate as a sanity check only.

**M4. Accuracy the app can state.** Carry an uncertainty with the reading:
sensor noise (0.1 hPa), calibration spread (the median absolute deviation of
the retained points), altitude uncertainty × lapse, and drift × hours since
the last point, added in quadrature. Show it as ± in the user's unit and
downgrade the wording past 1 hPa. This is what lets the number be shown to a
pilot at all.

**M5. Two sensors, one answer.** When both phone and watch are calibrated and
at rest, the app takes the inverse-variance weighted mean and flags a
disagreement above 1.5 hPa (phone in a car with the windows up, watch in the
open). Redundancy is the gain; the improvement in the number itself is under
0.1 hPa.

**M6. Not worth doing.** Higher sample rates, Kalman filtering of the raw
stream, or temperature compensation of the chip. The MEMS sensor is already
quiet, and Apple compensates it. The error budget is elevation and
calibration distance, not the sensor.

## 4. Making the reading useful off-field and at rural strips

What a pilot at a private strip actually lacks, in order: an altimeter
setting, a way to check it, the wind and density altitude at the strip, and a
sense of what is coming. Barry can give all four with data it already has.

**R1. Lead with the altimeter setting and its source.** Off-field the
headline line reads like a briefing, not a barometer: "Altimeter 29.94 est."
with one line under it, "KI67 29.95, 12 NM, 20 min ago · model 29.93 ·
sensor 29.94". Three sources that agree earn "±0.02"; disagreement or a
distant station earns "rough". The sensor is the only source that does not
degrade with distance from a station, and the only one that works with no
signal, so it is the one to build the rural case on.

**R2. The field-elevation check.** The FAA fallback with no setting is to
set the altimeter to field elevation. Barry can close the loop: with the
estimated setting dialed, "your altimeter should read about 810 ft here",
from absolute altitude (±25 ft on a phone with a fix). A pilot who sees 900
ft knows the estimate is off before the wheels roll. Cheap, and it turns an
estimate into something checkable on the panel.

**R3. Calibrate at departure, use at destination.** The routine that makes
the sensor trustworthy: the phone calibrates at the home field before
departure (a reported setting, a real station), the offset drifts well under
0.5 hPa over a few hours, and at the strip the sensor reads the pressure
there directly. The app should say this plainly the first time the feature
is on: "Calibrated at KLUK 9:40 AM. Good for a few hours anywhere."

**R4. Strip conditions from the model.** Wind at the point from the model's
10 m wind, density altitude from the estimated setting, GPS elevation and
the model's 2 m temperature, and the ride estimate that already exists. All
marked "model" and paired with the nearest station's real numbers and
distance, so the pilot can weigh them.

**R5. Say how representative the station is.** Distance, and the elevation
difference between the station and the strip. A valley station 800 ft below
a ridge strip is not "nearby" for pressure or wind, and the app should say
"KXYZ is 1,200 ft lower" rather than let the number stand alone.

**R6. Work with no signal.** The watch and the phone keep the last combined
payload, the calibration, and the sensor. With nothing to fetch, Barry still
shows the local setting, the local trend since the last report, and the age
of everything. Rural fields are where signal fails; this is where the sensor
earns its place.

**R7. Back the ± with data before shipping.** ROADMAP H1: replay the bulk
history with each station hidden, estimate it from neighbors, and report the
error by distance and terrain. The disclaimer and the ± figures come from
that, and the same harness scores the sensor path once testers have logged a
few dozen readings at strips.

**R8. The words.** One line, always visible: "Estimated, advisory only." The
14 CFR 91.121 language lives one tap away and says to use a reported setting
within 100 NM when one exists.
