# Barry feature registry

Every user-facing feature in Barry, what it does, where it lives in the code,
what data it reads, what settings change it, and what tests cover it. Written
2026-09-24 from a full read of the sources. This is the reference for people
and for agents working on the app. If a feature is not in here, it is not a
feature yet.

## How to use this document

- **Slugs.** Every entry has a stable dotted name like `radar.layer.wind` or
  `settings.units.pressure`. Use the slug in commit messages, roadmap items,
  test names and conversations, so a feature can be found again.
- **Fields.** Seen: what the user sees and can do. Lives: file and the type or
  function. Data: the backend route or response field, sensor, or local
  computation. Settings: the stored key, default and options. Tests: what
  covers it. Rules: things a maintainer must know, taken from code comments.
  For: which audiences it serves (see the legend).
- **Keeping it current.** A change that adds, removes or changes a
  user-facing feature updates this file in the same commit. New settings keys
  go in the Settings table. New routes go in the Backend table. Found a
  defect? Add it to Known defects with the date, and remove it when fixed.
- **Audiences.** P pilots (general aviation). S soaring and free flight
  (gliders, paragliders, hang gliders, balloons). D drone operators. M marine
  (sailors, boaters). E everyday users, including people who feel pressure
  changes. W weather watchers. B backcountry, off the grid.
- **Companion docs.** CLAUDE.md is the architecture and status note.
  docs/ROADMAP.md holds the ranked improvement list. docs/NOAA.md is the data
  plan. docs/TESTING.md is the test inventory. docs/REVIEW.md holds the
  periodic ten-thousand-foot reviews; the first is 2026-09-24.

## The shape of the app

Barry has one idea at the centre and three rings around it.

- **The centre** is the pressure tendency: the rate of change of barometric
  pressure over three hours, classified into six bands, worded as a verdict,
  and explained. It lives on the phone's hero, the watch face, the lock
  screen and the home screen widgets.
- **Ring one, the field.** What the chosen airport reports and forecasts:
  category, wind on the runways, TAF, density altitude, boundary layer,
  clouds, lightning nearby. Cards on the main page, widgets, the METAR
  complication.
- **Ring two, the sky.** Two full-screen tools: the radar (rain, pressure
  field, isobars, fronts, wind at six altitudes, stations, lightning) and
  Aloft (the column of clouds, temperatures and winds above the field).
- **Ring three, the sensors.** The phone's and the watch's barometers,
  calibrated against the station, so the tendency keeps working off the
  field and off the grid.

Surfaces: iPhone main page (cards, reorderable), iPad dashboard (three
columns in landscape), the radar screen, the Aloft screen, Settings,
onboarding, notifications, Live Activity, home and lock screen widgets, the
watch app, and five complication kinds. The backend is a FastAPI cache on
Tower; the app never talks to a weather source directly except for radar
tiles.

## App shell

### app.launch.gate
- Seen: first run is the onboarding flow as the root view; after that the
  main page. Nothing (station lookup, location prompt) starts until the
  user is through.
- Lives: `iOSApp/BarryApp.swift`.
- Settings: `hasOnboarded` false.
- Rules: launch also migrates alert keys, starts MetricKit, sets the
  notification delegate, sizes `URLCache` (16 MB memory, 200 MB disk). The
  `-uitest` argument gives a known state (onboarded, KLUK, sensor and
  alerts off).

### app.state.loading, app.state.error, app.state.noReports, app.state.coldStartStale
- Seen: "Reading the barometer…"; an error with Try again; "STATION isn't
  reporting weather" with advice to pick a reporting airport or save the
  spot as a place; at launch the last saved reading with "saved HH:MM,
  refreshing" or, in orange, "saved HH:MM, can't refresh".
- Lives: `ContentView.swift` › `content`, `ErrorStateView`; `PressureStore.init`;
  `CombinedStore`.
- Rules: the saved reading is used only if its station matches.

### app.refresh
- Seen: pull to refresh; a silent refresh every 300 s in front and on
  return to the foreground.
- Data: `/combined` then `/front`. Silent refreshes use the patient session
  (15 s per request, 45 s total, waits for connectivity) and keep the old
  reading on failure. Every call sends `tz`.

### home.metarStrip
- Seen: station ID, flight category in colour, the METAR in shorthand
  ("27011G18KT 10SM BKN045"), and the Settings gear. Once there is data the
  navigation bar hides and a Barry mark sits at the foot of the page.
- Lives: `ContentView.swift` › `MetarStrip`.
- Data: `/combined.pressure.current`.
- For: P.

### home.ipad.dashboard
- Seen: on a regular-width screen everything at once: the METAR strip, a
  340 pt card rail, the chart, the forecast card and the radar. Three
  columns when wider than tall and at least 1000 pt; otherwise two.
- Lives: `ContentView.dashboard`, `glanceRail`, `radarColumn`.
- Rules: the rail skips chart, forecast and radar. The radar column always
  shows, even when the Radar card is hidden.

## Home: the hero

For: everyone. Fixed at the top; not a card.

### home.hero.stationRow
- Seen: an airplane icon, "KLUK · Cincinnati/Lunken…", a chevron. The
  menu lists saved locations and "Follow on lock screen".
- Lives: `HeroView.swift` › `StatusRow`.
- Data: `pressure.station`, `pressure.name`, `SavedLocationsStore`.

### home.hero.freshness
- Seen: "Local · now", "Local · carried", "Local · Nm ago" when a sensor
  reading is shown; otherwise "Calibrating…", "Settling…", "Paused"; or
  "METAR Nm ago" over "refreshed HH:MM".
- Rules: once a local reading shows, the label reports its trust tier and
  age, never the raw motion classifier.

### home.hero.value
- Seen: the big number with its unit. inHg shows 3 decimals for a live
  reading and 2 for METAR; hPa 1 and 0.
- Data: at an airport the altimeter setting; otherwise the local reading if
  eligible; otherwise sea-level pressure.
- Settings: `pressureUnit`.
- Rules: a local reading counts only when the sensor is on, the selection
  is My location, the barometer is calibrated or provisional, the reading
  is at least as new as the METAR or under an hour old, and under 2 h old.
- Tests: `CardRenderTests` (render).

### home.hero.altimeterTag
- Seen: a blue ALTIMETER capsule and "as reported at KLUK · sea level
  30.24".
- Rules: shown when an airport is selected or the device is within 3 NM
  (`PressureStore.isAtAirport`). The altimeter is never blended with the
  phone's calibration; LOCAL never shows at an airport.
- For: P.

### home.hero.localCompare and home.hero.microTrend
- Seen: an orange LOCAL capsule, "tap to compare" ("station 29.92 · phone
  −0.04"); "sensor ↓ 0.03 inHg in last 42 min", orange with "falling faster
  than the station shows" when the sensor is sharper.
- Data: `BarometerManager.microTrend` (60 min buffer, 3 trusted points over
  5 min), `tendency.delta3h`.
- Rules: sharper means the local 3 h rate exceeds the METAR's by 0.7 hPa
  with the same sign.
- For: E B.

### home.hero.tendencyBadge
- Seen: trend arrow, signed 3 h change, "3h", tinted by class.
- Data: `pressure.tendency`. Classes: rising fast at +1.5, rising at +0.5,
  steady, falling at −0.5, falling moderately at −1.5, falling fast at
  −3.0 hPa per 3 h. Intensity maps 1.5 to 4.0 onto 0 to 1.
- Tests: `TendencyParityTests` against the Python fixture.
- Rules: mirrored by hand in `backend/app/tendency.py`.

### home.hero.verdict, home.hero.rateContext, home.hero.explanation, home.hero.honestyNote, home.hero.wordsCollapse
- Seen: the verdict in headline type with a colour bar; "0.03 inHg per
  hour, front pace" (silent under 1.5 hPa per 3 h, "storm pace" at 3.0);
  one grey line saying what agrees or disagrees; "Low confidence." when the
  caveats say so or confidence is under 0.5; tap to collapse the supporting
  lines.
- Data: `/combined.verdict`, `reading.rate3h`, `reading.explanation.summary`,
  `reading.caveats`, `reading.confidence`.
- Settings: `heroWordsExpanded` true.
- Rules: the reason for low confidence is deliberately not shown.

### home.hero.lightningLine
- Seen: "Thunderstorm at the field since 3:10 PM, moving east." in red or
  orange, only when there is no Lightning card.
- Data: `current.lightning`.

### home.hero.guide
- Seen: an info button opens `sheet.pressureGuide`: what each movement
  suggests, why fast changes hint at wind, terms (front, trough, ridge,
  front edge, gust front, tendency), sources.
- Lives: `PressureGuideView.swift`.
- For: E W.

## Home: the cards

Lives: `HomeLayout.swift` › `HomeCard`, `HomeLayoutStore`, `HomeLayoutView`;
rendered by `ContentView.glanceCards`. Stored as `homeLayout.v1` (order and
hidden). A card shows only when it is not hidden and has something to say.

| Order | ID | Title | On by default | Shows only when |
|---|---|---|---|---|
| 1 | `lightning` | Lightning nearby | yes | `lightningNearby` exists |
| 2 | `chart` | Trend chart | yes, cannot hide | phone layout |
| 3 | `taf` | TAF timeline | no | the station has a TAF |
| 4 | `rainWind` | Forecast | yes | phone layout, 2 or more hours |
| 5 | `conditions` | Conditions | yes | density altitude, boundary layer, fog or storm present |
| 6 | `strip` | Here (off-field) | yes | not at an airport |
| 7 | `wind` | Wind | yes | the METAR has wind |
| 8 | `radar` | Radar | yes | phone layout, station has coordinates |
| 9 | `sensor` | Sensor vs station | yes | sensor on and My location |
| 10 | `sources` | Data sources | yes | always |

### settings.homeScreen.layout
- Seen: Settings › Home screen: three presets (Pilot, Weather, Everything),
  one row per card with a switch and a drag handle, and the Live Activity
  toggle. "A card still only appears when it has something to show."
- Presets: Pilot hides sensor and TAF; Weather hides wind, Here and TAF;
  Everything shows all.
- Tests: none.

### card.lightning
- Seen: a tinted card: "Lightning 12 mi to the west" (or "at the field"
  under 3 mi), then "13 min ago, moving toward you, here around 4:10 PM ·
  98 flashes within 100 mi". Opens the radar.
- Lives: `LightningBanner.swift`.
- Data: `/combined.lightningNearby`.
- For: P M E.

### card.chart
- Seen: the pressure curve, solid observed and dashed forecast, colour
  deepening with rate of change; min and max dots; a now rule; the phone's
  own trace in orange; a fit band when the trend is ragged; thunder spans;
  a feature pin (trough, ridge, front edge, past trough); tap to read a
  point; drag to select a range with snapping handles; preset chips
  (Around the trough, Last 3 h, Since midnight, Next 6 h); a floating
  analysis card ("A trough passed", net, swing, steepest); a legend; a
  caveat line when the forecast is stale or missing.
- Lives: `PressureChartView.swift`; `Shared/RangeAnalysis.swift`;
  `ForecastCaveatView.swift`.
- Data: `pressure.series`, `forecast.hourly`, `reading.feature`,
  `reading.steadiness`, `BarometerManager.phoneHistoryTrace` (48 h).
- Settings: `chartWindow` hours6 (−6 to +6) or hours48 (−24 to +48).
- Tests: `BarometerTests` covers RangeAnalysis; nothing covers gestures.
- Rules: slope is fit over ±1.5 h; the dashes are deliberate because real
  fronts arrive sharper than the model; range selection snaps to the half
  hour; windows of 14 h or more have the tide removed; iOS 18 uses a
  horizontal-only drag so the page still scrolls.
- For: everyone; the analysis card is for W E.

### card.taf
- Seen: one sentence ("VFR until 2 AM, then MVFR, LIFR by 4 AM") over a
  24 h strip of category runs, night shaded, TEMPO and PROB hatched,
  sunrise and sunset marked, a bust noted first when the METAR disagrees.
- Lives: `TafTimelineCard.swift`; `Shared/TafTimeline.swift`, `TafStrip.swift`.
- Data: `/combined.taf`, `forecast.sun`, `current.fltCat`.
- Tests: `TafTimelineTests`, `CardRenderTests`.
- For: P.

### card.rainWind (the forecast card)
- Seen: one of four styles. Chart (default): chips for rain, wind and
  temperature, a 12 h chart with rain bars, wind line and gust band,
  temperature line with H and L, tap for a readout. Summary: two or three
  sentences naming each change over four colour bands, drag to read.
  Changes: a timeline of what changes and when. Hourly: 24 columns with
  temperature, wind, rain and sky.
- Lives: `ForecastCards.swift`, `ConfirmationOverlayView.swift`,
  `ShortTermForecast.swift`.
- Data: `forecast.hourly`, `current` wind and temperature.
- Settings: `forecastCardStyle` chart; `forecastCard.hidden`; `windUnit`;
  `temperatureUnit`.
- Tests: `CardRenderTests` (every style), `ShortTermForecastTests`.
- Rules: rain likely at 30%; a wind shift is 60° over two hours with wind
  at least 9 km/h; a build is a rise of 15 km/h to at least 28; a front is
  a 2.5 °C drop after the shift. "All four are here for testing; the list
  will be cut after that."
- For: everyone.

### card.conditions
- Seen: density altitude with the field elevation and a humidity note, and
  a trend; clouds with the category, the layer list, a 12 h trend, and a
  tap to Aloft; the boundary layer top (AGL or MSL) with a trend; the ride
  sentence ("Bumpy below 4,200 ft, strong thermals"); storms (at the
  field, in the area, likely, possible) with distance, motion and timing;
  fog (likely, possible, overnight); the "Clouds and winds aloft" row.
- Lives: `FieldConditionsView.swift`.
- Data: `/combined.conditions`, `current.clouds`, `forecast.hourly`.
- Settings: `boundaryLayerReference` agl.
- Tests: the Aloft UI test taps the row; nothing tests the logic.
- Rules: the card exists only with density altitude, boundary layer, fog
  or storm content; clouds alone do not count. The ride note says "for
  advisement only, not a replacement for PIREPs".
- For: P S D.

### card.strip (Here, off-field) and Backcountry
- Seen: "Here" with the nearest station, its distance, direction, height
  difference and age. With Backcountry on: an estimated altimeter setting
  with a ± and a "rough" flag, the sources line (sensor, station, model),
  "Set 30.02, panel should read about 1,240 ft", density altitude and
  model wind, and an info sheet with the 14 CFR 91.121 disclaimer.
- Lives: `Backcountry.swift` › `StripCard`, `StripEstimate`.
- Data: the phone sensor (calibrated, under 2 h old), `current.altim`, the
  model's sea-level pressure adjusted by the station's offset, GPS or fused
  altitude.
- Settings: `backcountryEnabled` false (one-time disclaimer),
  `backcountryUsePhoneSensor` true, `backcountryUseWatchSensor` true.
- Rules: never shown at an airport. Sensor wins, then station. Rough means
  the sources disagree by more than 1.7 hPa or the station is over 50 NM
  away. Density altitude uses the FAA rule of thumb.
- For: B P.

### card.wind
- Seen: with runway data, the runway dial: the best runway to its true
  heading, the wind barb, "9 kt crosswind from the left, 12 kt headwind",
  gust note, a 12 h outlook ("crosswind peaks 11 kt around 3 PM; Rwy 03
  better after 6 PM"), All runways to expand. Without runways: the rose,
  "Wind from 240° at 12 kt, gusts 18", building or shifting outlook.
- Lives: `RunwayWindsView.swift`; `Shared/RunwayMath.swift`, `RunwayWindDial.swift`.
- Data: `/combined.runways`, `current` wind, `forecast.hourly` wind.
- Settings: `runwayWindsMode` auto (always, auto, compass).
- Tests: `RunwayMathTests`, `CardRenderTests`.
- Rules: parallels collapse to the number; Barry has no basis for choosing
  between them. Calm is under 1 kt.
- For: P D M.

### card.sensor and sensor.detail
- Seen: "Sensor vs Station" with the gap, and a detail screen: the phone's
  line against METAR dots over 3, 6 or 12 h, Measure now, calibration
  status ("Calibrated 12m ago against KLUK"), a drift note, Recalibrate
  now.
- Lives: `SensorComparisonView.swift`; `BarometerManager.swift`.
- Rules: only with the sensor on and My location. Recalibrate also wipes
  the 48 h phone history.
- For: E B W.

### card.sources
- Seen: the station and its source, "Forecast · Open-Meteo.com (CC-BY
  4.0)", and the update time.
- Lives: `ContentView.swift` › `DataSourceFootnote`.
- Rules: the comment says the credit is required, yet the card can be
  hidden. See Known defects.

## Sensors

### sensor.barometer (the phone)
- Seen: nothing directly; it feeds the hero's LOCAL value, the freshness
  line, the micro trend, the chart trace, the Sensor card and the Here
  card.
- Lives: `BarometerManager.swift` (Core Motion glue); `Shared/BarometerEngine.swift`
  (pure model); `Shared/PressureHistory.swift`.
- Settings: `phoneBarometerEnabled` false; stores `barometer.calibration.v2`,
  `barometer.history.v2`, `barometer.refAltitude.v1`.
- Rules: runs only in the foreground with the setting on. Motion gate:
  moving, settling (45 s), stationary. Still samples are trusted; a
  pressure jump on a resting phone is real weather. Moving samples are
  trusted only when carried clean (spread at most 0.25 hPa over 120 s and
  0.5 over 600 s). Calibration is the median of up to 12 points over 12 h
  of station altimeter minus raw pressure, one point per METAR, with a
  least-squares drift clamped to ±2 hPa; a jump over 5 hPa means the
  phone changed elevation and resets the history. An altitude bridge
  shifts offsets by the hypsometric amount when the phone moves at least
  4 m vertically. A GPS bootstrap gives a provisional value before the
  first calibration. History is one reading a minute for 48 h.
- Tests: `BarometerTests`, extensive.
- For: E B W.

### sensor.calibration.trigger
- Rules: each new `/combined` calibrates only when the selection is My
  location; a remote station's value would corrupt the offset. See Known
  defects for the background path.

## Saved locations

### locations.kinds and locations.select
- Seen: "My location" is always first and cannot be deleted; airports by
  ICAO (deduplicated); places by coordinate with a label. Select from
  Settings › Locations or the hero's station menu; swipe to delete.
- Lives: `Shared/SavedLocations.swift`; `SettingsView.swift` locations
  section; `ContentView.loadForCurrentMode`.
- Data: My location: a km-accuracy fix, `/stations/nearest`, then
  `/combined?station=`. Place: `/stations/nearest` for the coordinate, then
  `/combined` with lat and lon. Airport: `/combined?station=ICAO`.
- Settings: `savedLocations.v1`, `savedLocations.selected.v1`, `homeStation`.
- Rules: My location is the only physical selection. It alone enables the
  LOCAL reading, calibration, the Sensor card, the chart trace and the
  Here card's altitude. "At airport" (selected, or within 3 NM) drives the
  altimeter headline, the home barb on the map, the Auto runway mode and
  hides the Here card. Legacy keys are migrated once.
- Tests: none.

### settings.locations.addAirport and settings.locations.addPlace
- Seen: live search from two characters via `/stations/search`; Add checks
  the station with `/combined`, refuses one with no reports, and saves the
  canonical ID (I67 becomes KI67). Places geocode with CLGeocoder.

## Alerts and background

Lives: `StormAlerter.swift`, `BackgroundRefresh.swift`. All alerts are local
notifications posted only from the background refresh, never from a
foreground load. Each has a latch date and a cooldown.

| Slug | Trigger | Text | Cooldown | Switch |
|---|---|---|---|---|
| `alert.pressure.fallingFast` | class falling fast (−3.0 hPa per 3 h) | "Pressure dropping fast", the change, the place, the verdict | 3 h | `pressureAlertsEnabled` |
| `alert.pressure.risingFast` | class rising fast (+1.5) | "Pressure rising sharply" | 3 h | `pressureAlertsEnabled` |
| `alert.storm.lightning` | lightning reported within 30 min, within 25 mi, and heading this way or within 10 mi | "Lightning nearby", distance, direction, ETA | 1 h | `stormAlertsEnabled` |
| `alert.storm.observed` | storm risk observed within 10 mi | "Thunderstorms at PLACE" | 1 h | `stormAlertsEnabled` |
| `alert.storm.forecast` | storm risk likely, starting within 3 h | "Thunderstorms likely" with the window | 6 h | `stormAlertsEnabled` |
| `alert.test` | Settings › Send a test alert | samples at +3 and +5 s | none | either |

- Rules: lightning beats a forecast storm; one storm alert per check; a
  pressure and a storm alert can fire together. Front statuses must never
  feed notifications. The migration turns pressure alerts on for anyone
  who had the old single storms switch.
- Tests: `AlertTests` (decisions); the latch is untested.
- For: E M P.

### bg.refresh
- Rules: task `me.wvr.barry.refresh`, earliest 15 min out (a floor, not a
  schedule), scheduled only when the sensor or an alert switch is on. Each
  run loads, recalibrates in the background if the sensor is on, evaluates
  alerts, syncs the Live Activity, reschedules.

### diagnostics.metrickit
- Rules: MetricKit daily payloads go to `/diagnostics`; nothing identifies
  the phone. This is the only telemetry. There is no usage data.

## Onboarding

Lives: `OnboardingView.swift`. Paged; Skip on every page finishes with
defaults and nothing turned on.

1. `onboarding.idea`: "It's the change, not the number", a sample verdict.
2. `onboarding.where`: "Where are you flying?" Use my location (one fix,
   `/stations/nearest`) or Pick an airport (search). The location prompt
   fires here, never cold on the dashboard.
3. `onboarding.units`: pressure, wind and temperature pickers, seeded by
   region: inHg and °F in the US, hPa and °C elsewhere, knots everywhere.
4. `onboarding.sensor`: only on devices with a barometer; "Turn on local
   readings" or "Not right now".
5. `onboarding.alerts`: pressure changes, storms, lock screen; "Turn on"
   asks for permission.

Tests: none.

## Radar

For: P W M S D. The radar is a pushed screen (`radar.screen`) and a card on
the main page (`radar.embed`). Both draw the same layers from the same
stored keys, but each has its own model, so they fetch separately.

### radar.screen
- Seen: full-bleed map titled "Radar", key button top right, altitude rail
  and recenter bottom right, a card at the bottom with the chips, timeline,
  notes and attribution. Opens from the home radar card's expand button,
  the iPad radar column, the lightning banner, and the `-uitest-radar`
  launch argument.
- Lives: `iOSApp/RadarView.swift` › `RadarScreen`, `RadarPanel(embedded: false)`.
- Data: station coordinates from `/combined.pressure`.

### radar.embed
- Seen: a 440 pt card on the phone, or the radar column on the iPad. Layers
  button reveals the chip bar (not persisted). No altitude rail.
- Lives: `RadarView.swift` › `RadarPanel(embedded: true)`.
- Rules: the phone card is inactive while off screen (a GeometryReader
  check, because iOS 17 has no scroll visibility callback); the loop and
  the streaks stop. The iPad column is always active.

### radar.state
- Seen: "Loading radar…", or "Couldn't load radar. Check your connection."
  with Try again. Depends only on `/radar/frames`.

### radar.map.base
- Seen: muted Apple map, no points of interest, no compass, a red pin on the
  station, opening span 3.2°, minimum camera distance 60 km.
- Lives: `RadarMapView.swift` › `makeUIView`, `updateUIView`.
- Rules: when the station coordinate changes the pin moves and the map
  glides. `radar.button.recenter` glides back to 3.2° on the station.

### radar.attribution
- Seen: "Radar RainViewer · NOAA NEXRAD · Lightning NOAA GOES · Wind
  Open-Meteo · Fronts NWS WPC · Stations AWC". Must stay on screen.

### radar.layers (the model)
- Chip order: Radar, Pressure, Change, Isobars, Wind, Fronts, Troughs,
  Stations, Lightning, then More.
- Exclusive: Pressure and Change share `radarField`. Barbs or Speeds for
  stations. Flow or Arrows for wind. Everything else stacks.
- Draw order, bottom to top: basemap; radar tiles then the pressure overlay
  (shading, isobars, isallobars, change H/L); Apple labels; fronts then
  lightning; annotations (home pin and WPC centres required, station barbs
  and METAR bolts high, speed labels and arrows low); the Metal wind view;
  SwiftUI controls.
- The key lists only what is on: radar swatches, the pressure or change
  ramp, isobars, wind, fronts, stations, troughs (only when Fronts is off),
  lightning, station lightning, sources.
- Rules: new radar frames added after a reload stack above the pressure
  overlay. Lightning dims the radar to 0.55 and, with Stations off, adds
  METAR bolt markers. The timeline shows only when Radar is on.

### radar.layer.radar
- Seen: rain echoes in Barry's palette, crossfading between frames. Chip
  "Radar".
- Lives: `RadarMapView.swift` › `RadarTileOverlay`, `Coordinator`;
  `RadarPalette.swift`.
- Data: `/radar/frames` (host, 7 past frames, up to 3 nowcast). Tiles from
  RainViewer at `/512/{z}/{x}/{y}/2/0_1.png` (Universal Blue, unsmoothed,
  snow on), native zoom 7, ancestors cropped and upscaled beyond it.
- Settings: `radarShowRadar` true.
- Rules: alpha 0.75 full, 0.55 dimmed under Lightning, 0.02 for hidden
  frames so their tiles stay warm, 0 while the map moves. Crossfade 0.3 s.
  Palette: transparent below 5 dBZ, blues to 45, orange 45 to 50, red 55 to
  60, magenta 60 to 65, pale above. Tiles are repainted from RainViewer's
  colours; snow pixels pass through. Tile caches are sized in bytes (48 MB
  repainted, 24 MB source); `URLCache.shared` is 200 MB on disk; one ring of
  tiles is prefetched after each settle; in-flight requests are shared.
- Tests: `RadarPaletteTests`; the UI test keeps Radar on.

### radar.timeline
- Seen: a slider over every frame, the Now pill, the loop button, and the
  frame time ("8:20 PM · 20m ago", "· nowcast" in orange, "· model +2h" in
  purple).
- Lives: `RadarView.swift` › `radarControls`; `RadarModel.swift`.
- Settings: `radarAutoplay` true ("Play the last hour" or "Hold on the
  latest", in Settings › Radar).
- Rules: the loop steps every 0.55 s from the oldest frame to now and dwells
  three ticks on the newest. Nowcast frames are never looped, only scrubbed
  to. Scrubbing pauses. Nothing refreshes the frame list while the screen
  stays open; it loads on appear and on Try again.
- Tests: the UI test checks Now, scrub and loop selection states.

### radar.timeline.modelFrames (parked)
- Hourly HRRR frames from Iowa Mesonet tiles after the nowcast. Off behind
  `RadarModel.modelFramesEnabled = false`; while false the app makes no IEM
  or `/radar/hrrr` requests.

### radar.field.pressure
- Seen: sea-level pressure shading, purple low to orange high, stretched over
  the region's own range. Chip "Pressure".
- Lives: `PressureFieldOverlay.swift` › `PressureFieldRenderer`.
- Data: `/radar/pressure` › `pressureGrid`, from the server's METAR table.
- Settings: `radarField = "pressure"`.
- Rules: opacity 0.30 with Radar on, 0.42 without; edges feathered 8%.
- For: W P M.

### radar.field.change
- Seen: three-hour change shading (red falling, blue rising), isallobars
  (amber, solid rises, dashed falls, every whole hPa) and H/L marks of the
  change extremes. Chip "Change".
- Data: `/radar/pressure` › `tendencyGrid`, `isallobars`, `tendencyExtrema`;
  the server needs 3.5 h of history.
- Settings: `radarField = "change"`.
- Rules: these H/L marks are change extremes, not WPC centres.
- For: W P M E.

### radar.layer.isobars
- Seen: indigo lines with unit-labelled knockouts ("1012 hPa", "29.88 inHg")
  every 4 hPa. Chip "Isobars".
- Lives: `PressureFieldRenderer.drawLine`, `levelText`.
- Data: `/radar/pressure` › `isobars`.
- Settings: `radarIsobars` false; `radarIsobarsSplit` migration gives
  isobars to anyone who had Pressure on.
- Tests: `PressureLabelTests`.

### radar.layer.wind
- Seen: grey streaks drifting with the wind (Flow) or arrows (Arrows).
  Chip "Wind".
- Lives: `WindFlowView.swift` + `WindFlow.metal`; `RadarMapView.syncArrows`.
- Data: `/radar/field` (7 by 5 points per region; boundary layer and CAPE
  fields present but unused on the map).
- Settings: `radarWindArrows` true (the Wind chip; historical name),
  `radarWindStyle` "flow" or "arrows".
- Rules: particles scale with view area (70 to 240), 30 fps cap, CPU
  simulation and one Metal draw call, anchored to the ground so pans need
  nothing, respawn after a big zoom, a new grid bends existing streaks.
  Arrows under 6 km/h are dropped. `radar.note.windCalm` says "Wind under
  3 kt across the map." at the surface when nothing draws.
- Tests: the UI test turns Wind on.
- For: P S D M W.

### radar.rail.altitude
- Seen: a vertical rail, highest stop on top: SFC, 2.5k, 5k, 10k, 14k, 18k.
  Tap or drag. Full screen only, while Wind is on. `radar.note.altitude`
  says "Wind at about N ft. Other layers stay at the surface."
- Lives: `RadarView.swift` › `altitudeRail`; `RadarModel.swift` › `WindAltitude`.
- Data: `/radar/field/levels` once per region, all levels in one call
  (925, 850, 700, 600, 500 hPa).
- Settings: capped by `aloftCeilingFt` (stops up to `max(5000, ceiling)`).
- Rules: the streak ramp changes per stop (35 km/h at the surface to 130 at
  18k). The level is not remembered between opens. Other layers stay at the
  surface; the key's wind text still says 10 m wind.
- Tests: the UI test drags the rail and checks the note.
- For: P S.

### radar.layer.fronts
- Seen: the WPC surface chart: cold blue triangles, warm red half-discs,
  stationary alternating, occluded purple, weak fronts dashed; H and L
  pressure centres with values. Chip "Fronts".
- Lives: `FrontsOverlay.swift` › `FrontFieldRenderer`, `FrontGlyphs`,
  `PressureCenterView`.
- Data: `/fronts`, fetched once per open, not tied to the region.
- Settings: `radarFronts` true; More sheet toggles `radarFrontLines`,
  `radarFrontPips`, `radarFrontWeak`, `radarFrontCenters` (all true).
- Rules: only the analysis frame is drawn. The 12 to 48 h progs arrive and
  are unused, because a map with its own clock read tomorrow's front as
  today's. Pips sit on the left of travel. The key and the map share
  `FrontGlyphs` so they cannot disagree. Centre values read `pressureUnit`
  once when built.
- For: W P M.

### radar.layer.troughs
- Seen: dashed orange-brown WPC trough lines. Chip "Troughs".
- Settings: `radarTroughs` true.
- Rules: see Known defects. Draws nothing unless Fronts and Front lines are
  also on.

### radar.layer.stations
- Seen: METAR wind barbs or speed pills tinted by flight category, a
  lightning badge when the METAR reports it, station IDs when zoomed in
  (span under 2.2°). Tap opens the station sheet. Chip "Stations".
- Lives: `StationLayer.swift`.
- Data: `/metars?half=` from the server's bulk table, thinned to 350.
- Settings: `radarStations` "off", "barbs" or "speeds";
  `radarStationStyleLast` "barbs".
- Tests: none of the glyphs.
- For: P W.

### radar.home.marker
- Seen: the chosen station as its own barb or speed pill with a blue halo
  when it is an airport or the user is within 3 NM; otherwise a red pin plus
  the user's dot.
- Lives: `RadarMapView.syncHome`; built by `ContentView.homeMarker`.

### radar.sheet.station
- Seen: ID, category, age, name, wind, visibility, ceiling, temperature and
  dew point (in the temperature unit), altimeter, weather, the raw METAR.
- Lives: `RadarSheets.swift` › `StationDetailSheet`.
- Rules: the altimeter here is always inHg regardless of `pressureUnit`.

### radar.layer.lightning
- Seen: GOES flash dots coloured by age (white new, lavender, violet, dim
  purple), a white arrival pulse on new cells, violet cluster outlines,
  METAR bolt markers when Stations is off, the radar dimmed. Chip
  "Lightning". `radar.note.lightningCoverage` says "Lightning feed catching
  up." when the feed is stale.
- Lives: `LightningOverlay.swift`; `LightningMarkerView` in `StationLayer.swift`.
- Data: `/lightning` (0.02° cells, 20 min window, clusters, coverage),
  refetched every 60 s, on a move over 1.5°, and on region change. The
  client sends no `half`, so the server's ±3° box applies: at continental
  zoom only the box around the centre shows flashes.
- Settings: `radarStorms` true.
- Rules: a quiet day draws nothing. The 60 s ticker runs while the embed
  is off screen.
- For: P M E W.

### radar.sheet.key
- Seen: a key listing only the layers that are on, plus sources.
- Lives: `RadarSheets.swift` › `RadarKeySheet`.

### radar.sheet.more
- Seen: "Map options": four front toggles, Flow or Arrows, Barbs or Speeds,
  each with a caption.
- Lives: `RadarSheets.swift` › `RadarMoreSheet`.

### radar.region.debounce
- Rules: each pan or zoom records the region; per layer only the last
  request within 0.7 s is sent. Wind, levels and pressure reuse their data
  while the zoom ratio is 0.8 to 1.25 and the centre is within 20% of the
  span; stations while 0.6 to 1.6 and within half the box; lightning until
  a move over 1.5°.

## Aloft

For: P S D. The column of clouds, temperatures and winds above the field.

### aloft.entry
- Seen: opens from the conditions card's Clouds row and its last row,
  "Clouds and winds aloft", and the `-uitest-aloft` launch argument.
- Lives: `ContentView.aloftScreen` › `AloftView.swift` › `AloftScreen`.
- Data: `/aloft?lat&lon`: 25 hourly columns, levels 1000 to 400 hPa in feet
  and knots, cloud layers, freezing level, boundary layer.
- Rules: loads once; no retry. The `stale` flag from the server is not
  decoded. With no conditions block the ground is 0 ft MSL.

### aloft.navbar and aloft.menu.ceiling
- Seen: custom bar with Back, "Aloft", station and name, and a ceiling menu
  (6,000 / 12,000 / 18,000 / 24,000 ft).
- Settings: `aloftCeilingFt` 18000, shared with Settings › Aloft and the
  radar rail's cap.

### aloft.scale
- Seen: the bottom 6,000 ft take 52% of the height; gridlines every
  2,000 ft; the 6k line is the scale break.
- Lives: `AloftMath.swift` › `AloftScale`.
- Tests: `AloftTests` (fractions, break, linear under 6k).

### aloft.layer.clouds, aloft.metarCeiling, aloft.layer.icing
- Seen: model cloud bands (dense fill at 70% cover) with cover, top and base;
  the METAR ceiling as a separate line with a pill like "BKN045 · METAR";
  the freezing level as a dotted rule with "0°C · 8,500 ft"; ICING tags on
  cloud between 0 and −20 °C.
- Rules: the METAR ceiling does not move with the scrubber. A band's base
  label hides within 22 pt of the METAR line.

### aloft.layer.temp and aloft.layer.wind
- Seen: temperature and dew point per level in the temperature unit; barbs
  with "230° / 25 kt".
- Lives: `AloftBarbView`, `WindBarb.marks` in `AloftMath.swift`.
- Tests: `AloftTests` barb marks and formats.

### aloft.layer.layer
- Seen: the boundary layer top as a dashed orange rule, chip "Layer", off by
  default. Always AGL; the main page's AGL/MSL setting does not apply here.
- Settings: part of `aloftLayers`.

### aloft.rows and aloft.sheet.level
- Seen: one row per level from the bottom up, dropped when within 18 pt of
  the row below; tap opens a sheet with temperature, dew point, spread,
  wind, cloud and an icing sentence.

### aloft.chips
- Seen: Clouds, Wind, Temp, Icing, Layer chips and a More menu ("Show every
  layer", "Clouds only").
- Settings: `aloftLayers` "clouds,wind,temp,icing".

### aloft.scrubber and aloft.animation
- Seen: a slider over the hours ("Now · 3:00 PM", "+N h · time"), haptic
  per hour, and the plot glides between hours over 0.35 s.
- Tests: the UI test opens Aloft, toggles each chip, scrubs, picks a
  ceiling and comes back.
- Rules: that test leaves `aloftCeilingFt` at 12000 in the simulator, and
  it runs before the radar test, so the rail then stops at 10k.

### aloft.footer
- Seen: "Levels Open-Meteo · ceiling AWC · elevation OurAirports".

## Watch app

For: P E B. The watch fetches for itself; the phone only tells it which
station and which mode.

### watch.sync
- Lives: `iOSApp/WatchSync.swift` › `WatchSync.send`; `WatchApp/PhoneSync.swift`.
- Data: five keys pushed from the phone: `homeStation`, `airportSelected`,
  `selectionPhysical`, `backcountryEnabled`, `watchBarometerEnabled`.
- Rules: latest wins; unchanged payloads are skipped; held until the watch
  is reachable. Sent after every load, every 300 s refresh, a saved
  location change, and the Backcountry switches. App Groups are local to
  each device, so units and layouts do not cross.

### watch.page.main
- Seen: station title with a gear, the trend glyph coloured by class and
  intensity, the headline pressure, "altimeter ·" or "sensor ·" then the
  3 h change, the 6 h chart, the verdict, "METAR N min ago". An "altimeter
  here X est." line in Backcountry mode off an airport.
- Lives: `WatchApp/WatchContentView.swift` › `loaded`.
- Data: `/combined?station=&tz=` (no coordinates; `/front` is phone only).
- Rules: the headline is the altimeter setting at an airport (selected, or
  within 3 NM), otherwise sea-level pressure, otherwise the calibrated
  sensor with an orange dot. The sensor counts only if calibrated (or
  rough) and newer than the METAR or under an hour old. Refresh on open,
  and on foreground when older than 3 min.

### watch.page.offline
- Seen: the last snapshot (glyph, pressure, verdict, "as of") while loading
  or after a failure, with Retry.

### watch.chart.6h
- Seen: six hours observed coloured by slope, six hours of dashed model, a
  now line, an orange dot, hour ticks every 3 h, two labels. Y range at
  least 3 hPa.
- Lives: `WatchChart6h`.

### watch.station.selfResolve
- Rules: a cellular watch without its phone and set to "My location" finds
  its own nearest station via `/stations/nearest`.

### watch.barometer
- Seen: nothing directly; it feeds the headline and the snapshot.
- Lives: `WatchApp/WatchBarometer.swift`; shared engine
  `Shared/BarometerEngine.swift`.
- Rules: foreground only. Steady means a spread of at most 0.10 hPa over
  20 s with 5 samples. Calibrates one point per METAR while steady; a rough
  setting from altitude after 3 s; offsets shift with height changes over
  4 m; altitude accepted at 8 m accuracy or better. Keys
  `watch.barometer.calibration.v1`, `watch.barometer.refAltitude.v1`.
  The snapshot takes the sensor value only when fully calibrated, at most
  once a minute, and the complication uses it for two hours.
- Tests: `BarometerTests` covers the shared engine, nothing the watch glue.

### watch.settings
- Seen: a Watch barometer switch, "Set altimeter by hand" (a crown picker,
  27.50 to 31.50 inHg or 930 to 1070 hPa, enabled only while steady), and a
  pressure unit picker.
- Lives: `WatchApp/WatchSettingsView.swift`.
- Settings: `pressureUnit` inHg (watch's own copy), `watchBarometerEnabled`
  false.
- Rules: see Known defects; the phone overwrites the barometer switch.

## Complications

For: P E M. All in `WatchComplication/`, all on `TendencyProvider`, all
reading the watch's `pressureUnit`.

| Slug | Family | Renders |
|---|---|---|
| `complication.trend.circular` | circular | gauge filled to intensity when falling, trend glyph, class tint, grey when stale |
| `complication.trend.corner` | corner | RISING FAST to FALLING FAST or STALE around the edge, pressure inside |
| `complication.trend.inline` | inline | glyph, pressure, unit, flight category |
| `complication.dial.circular` | circular | a −4 to +4 hPa dial; the needle is the expected change over the next 3 h |
| `complication.graph.rectangular` | rectangular | pressure, glyph, "−1.6 · 3h", a 12 h sparkline with a dashed 2 h tail |
| `complication.metar.rectangular` | rectangular | station, category, pressure; trend and change; wind, visibility, ceiling in METAR shorthand |

- Glyph rule (`TendencySnapshot.trendSymbolName`): trough passing, recovery,
  approaching trough, ridge peak, rapid fall, rapid rise and front knee each
  have a symbol; otherwise the class's own.
- `complication.provider`: returns the cached snapshot at once and asks for
  +20 min; refreshes in the background when 15 min old; without a snapshot
  waits 5 s then retries in 2 min. Stale after 2 h. Never blocks on the
  network, because a slow fetch leaves the slot grey for good.
- Tests: `SnapshotStalenessTests`, `TendencyParityTests`.

## Phone widgets and Live Activity

For: P E. Lives in `PhoneWidget/`. Two providers: `TendencyProvider` (the
snapshot) and `CombinedProvider` (the last `/combined` saved to the App
Group by the app; answers at once, refreshes when 15 min old, waits 8 s only
when there is no file). The app nudges WidgetKit after every load.

| Slug | Kind and family | Shows |
|---|---|---|
| `widget.trend.lock.circular` | Pressure Trend, lock circular | intensity ring when falling, glyph, pressure |
| `widget.trend.lock.inline` | lock inline | glyph and pressure |
| `widget.trend.lock.rectangular` | lock rectangular | glyph, class, pressure and change |
| `widget.trend.small` | Pressure Trend, small | glyph, station, pressure, change, verdict |
| `widget.trend.medium` | Pressure Trend with the curve, medium | the small row plus a 12 h sparkline and a lightning line when strikes are within 100 mi |
| `widget.taf.medium` | TAF, medium | the TAF sentence over the 24 h category strip |
| `widget.taf.lock.rectangular` / `.inline` | TAF, lock | station and the sentence |
| `widget.field.small` / `.medium` | Field, small and medium | category, wind, altimeter, ceiling, visibility, density altitude, age; medium adds temperature, dew point, elevation, sea level |
| `widget.runway.small` | Runway Winds, small | the runway dial for the best runway, following `runwayWindsMode` |

- Rules: missing fields are left out, never dashes. Past two hours the
  widget says "as of" and goes grey. The lightning line never shows an empty
  state.
- Tests: `TafTimelineTests`, `RunwayMathTests`, `CardRenderTests`; nothing
  tests the providers.

### liveactivity.pressure
- Seen: a lock screen banner and Dynamic Island with glyph, pressure, change,
  an event label and the verdict. Events, first match wins: lightning
  within 30 mi, falling fast, rising fast, front passing (from the station's
  own interpreter, never `/front`), or Follow (six hours, from the hero).
- Lives: `Shared/PressureActivity.swift`, `iOSApp/LiveActivityManager.swift`,
  `PhoneWidget/PressureActivityWidget.swift`.
- Settings: `liveActivityEnabled` false, switchable in Settings › Alerts,
  the home layout editor, and onboarding. `liveActivity.followUntil`.
- Rules: starts only in the foreground, no push; stale after 2 h; ends 15
  min after the event clears; after 90 min without an update it greys.
- Tests: none.

## Backend

Every client call goes through `Shared/BarryAPI.swift`. Per-client limit 60
requests a minute (`BARRY_RATE_PER_MIN`), 429 with Retry-After 30. Upstream
budgets: 30 AWC calls a minute, 100 Open-Meteo calls a minute; spent budgets
answer 503 with Retry-After 30. A remembered upstream failure answers 503
with Retry-After 60. Every response carries `X-Request-Id`.

| Route | Parameters | Returns | Upstream | Cache and rounding | Used by |
|---|---|---|---|---|---|
| `GET /combined` | `station`, `lat`, `lon`, `tz` | pressure (series, current, tendency), forecast, reading (trend, feature, confidence, explanation), conditions, runways, taf, lightningNearby, verdict | AWC METAR (Open-Meteo surface pressure as fallback), Open-Meteo forecast, AWC TAF, OurAirports runways, GLM flashes, bulk METAR lightning | pressure 12 min per station; forecast 30 min per 0.1° cell; TAF 30 min | the phone and watch (`PressureStore`), complications, widgets, the airport check in Settings |
| `GET /pressure/{station}` | `hours` | pressure only | as above | one key per station, whole day | nobody now |
| `GET /forecast` | `lat`, `lon` | hourly, sun, `stale` | Open-Meteo, 2 days | 30 min per 0.1° cell; last good re-served 12 h when upstream fails | inside `/combined` |
| `GET /front` | `station`, `lat`, `lon` | status, headline, bearing, eta, nearestFront | bulk METAR history (7.5 h) or an AWC box, forecast, `/fronts` | 15 min per station and 0.1° | the phone's front banner only |
| `GET /fronts` | none | WPC analysis plus 12 to 48 h progs | IEM AFOS (CODSUS, CODSRP) | 30 min, one entry | the radar |
| `GET /radar/hrrr` | none | run time | IEM tile probe | 10 min | nobody (parked) |
| `GET /metars` | `lat`, `lon`, `half` | stations with wind, category, visibility, ceiling, altimeter, lightning, raw | bulk table (AWC box fallback) | 2 min; centre 0.2°, half 0.5°; 350 stations | the radar station layer |
| `GET /radar/pressure` | `lat`, `lon`, spans | isobars, isallobars, grids, extrema | bulk table and history, no upstream | 5 min; centre 0.1°, spans 0.5°; two builds at a time | the radar pressure layers |
| `GET /lightning` | `lat`, `lon`, `half` | 0.02° cells, clusters, window 1200 s, coverage | GLM store | 60 s; centre 0.2°, half 0.5° | the radar lightning layer |
| `GET /radar/frames` | none | host and frames | RainViewer | 2 min | the radar |
| `GET /aloft` | `lat`, `lon` | 25 hourly columns, `stale` | Open-Meteo pressure levels | 1 h per 0.1° cell; last good 12 h | Aloft |
| `GET /radar/field` | `lat`, `lon`, spans | 35 points of wind, boundary layer, CAPE | Open-Meteo multi-point | 10 min; centre 0.05°, spans 0.5° | the radar wind layer |
| `GET /radar/field/levels` | same | 35 points at five levels | Open-Meteo multi-point | 30 min, same rounding | the altitude rail |
| `GET /stations/search` | `q`, `limit` | id and name matches, METAR stations only | AWC directory | directory 24 h | Settings, onboarding |
| `GET /stations/nearest` | `lat`, `lon` | station, name, distance | bulk table, AWC box, built-in table | 10 min per 0.2° | My location, the watch alone, onboarding |
| `GET /healthz` | `strict` | status, problems, cycle counts | none | none | Docker, monitors |
| `POST /diagnostics` | header `X-Barry-Kind` | 202 | none | 30 a minute, 1 MiB | MetricKit reports |
| `GET /metrics` | none | Prometheus text | none | box only | the server |
| `GET /privacy`, `/support` | none | static pages | none | none | App Store URLs |

Rules from the code: three-letter IDs are retried with a K prefix. The
precise point never leaves the server; only the 0.1° cell goes upstream.
Front statuses must never feed notifications. Absent lightning means
nothing reported, never no lightning. The extras on `/combined` (forecast,
TAF, explanation, conditions, lightning, track record) can each fail
without blocking the response.

### Scheduler and health
- Refresh loop every 600 s: the AWC bulk METAR table (history snapshot every
  25 min, kept 9.5 h), the station directory, the track log to disk, the
  registry to disk, then batched METAR calls for watched stations (50 per
  call).
- Lightning loop every 60 s: GOES-19 east of 106 W and GOES-18 west of it,
  20 minutes kept. `BARRY_GLM=0` disables.
- Unhealthy (503, autoheal restarts): a loop exited or stalled (refresh
  1800 s, lightning 600 s). Degraded (200, or 503 with `strict`): the
  lightning feed or the bulk table is stale.
- Tests: `backend/tests`, 300 tests; `test_property` reads the app's own
  OpenAPI document.

## Settings keys

All in `AppConfig.sharedDefaults`, the App Group suite, which is local to
each device (the watch keeps its own copies).

| Key | Default | Options and notes | Set from |
|---|---|---|---|
| `hasOnboarded` | false | | launch, onboarding |
| `pressureUnit` | inHg | hPa, inHg; onboarding seeds hPa outside the US | Settings, onboarding, watch Settings (its own copy) |
| `windUnit` | mph | kmh, mph, knots; onboarding seeds knots; barbs and Aloft are always knots | Settings, onboarding |
| `temperatureUnit` | celsius | celsius, fahrenheit; onboarding seeds °F in the US | Settings, onboarding |
| `phoneBarometerEnabled` | false | starts or stops the barometer at once | Settings, onboarding |
| `pressureAlertsEnabled` | false | migrated once from the storms key | Settings, onboarding |
| `stormAlertsEnabled` | false | the historical single switch | Settings, onboarding |
| `alerts.migrated.v2` | false | migration guard | StormAlerter |
| `alert.latch.*` | unset | cooldown dates for the four alert kinds | StormAlerter |
| `liveActivityEnabled` | false | | Settings › Alerts, Home screen page, onboarding |
| `liveActivity.followUntil` | unset | now + 6 h | the hero menu |
| `runwayWindsMode` | auto | always, auto, compass | Settings |
| `boundaryLayerReference` | agl | agl, msl; main page only | Settings |
| `forecastCardStyle` | chart | summary, changes, hourly, chart | Settings |
| `forecastCard.hidden` | "" | comma list of wind, temp | the chart-style forecast card |
| `chartWindow` | hours6 | hours6, hours48 | the trend chart |
| `heroWordsExpanded` | true | | the hero |
| `homeLayout.v1` | `HomeLayout.initial` | JSON order and hidden | Home screen page |
| `backcountryEnabled` | false | one-time disclaimer; also sent to the watch | Settings |
| `backcountryAcknowledged` | false | | the disclaimer sheet |
| `backcountryUsePhoneSensor` | true | | Settings |
| `backcountryUseWatchSensor` | true | sent to the watch as `watchBarometerEnabled` | Settings |
| `backcountryRangeNM` | unused | defined, never read | |
| `radarShowRadar` | true | Radar chip | radar |
| `radarField` | off | off, pressure, change | radar |
| `radarIsobars` | false | | radar |
| `radarIsobarsSplit` | false | one-time migration flag | radar |
| `radarTroughs` | true | | radar |
| `radarWindArrows` | true | the Wind chip, historical name | radar |
| `radarWindStyle` | flow | flow, arrows | radar More sheet |
| `radarFronts` | true | | radar |
| `radarFrontLines`, `radarFrontPips`, `radarFrontWeak`, `radarFrontCenters` | true | | radar More sheet |
| `radarStations` | off | off, barbs, speeds | radar |
| `radarStationStyleLast` | barbs | style restored when the chip turns on | radar More sheet |
| `radarStorms` | true | Lightning chip | radar |
| `radarAutoplay` | true | play the last hour, or hold on the latest | Settings › Radar |
| `aloftCeilingFt` | 18000 | 6000, 12000, 18000, 24000; also caps the radar rail | Settings › Aloft, the Aloft menu |
| `aloftLayers` | clouds,wind,temp,icing | adds layer | Aloft chips |
| `savedLocations.v1` | My location | JSON list | Settings, onboarding |
| `savedLocations.selected.v1` | first entry | UUID | Settings, the hero menu |
| `homeStation` | unset, then the snapshot's, then KLUK | also the watch sync key | onboarding, PressureStore |
| `barometer.calibration.v2`, `barometer.history.v2`, `barometer.refAltitude.v1` | none | the phone barometer's model, 48 h history, altitude datum | BarometerManager |
| `watch.barometer.calibration.v1`, `watch.barometer.refAltitude.v1` | none | the watch barometer | WatchBarometer |
| `watchBarometerEnabled` | false | watch Settings switch; overwritten by the phone sync | watch, PhoneSync |
| `tendency.snapshot.v1` | none | the complication and lock widget snapshot | SnapshotStore |
| `airportSelected`, `selectionPhysical` | false | watch sync keys, not phone settings | PhoneSync |
| `locationMode`, `placeLabel`, `placeLat`, `placeLon` | legacy | read once for migration | |

Not a key: `combined.json` in the App Group container holds the last
`/combined` payload for the widgets and the cold start.

## Look and voice

Barry is made by a hobbyist for hobbyists, and it should look and read that
way. The public voice rule (short, calm, no em dashes, no exclamation
marks, nothing that reads as generated) applies to layout as much as to
words. Signs that a screen has drifted: a caption under every control, a
pill label on every line, a note explaining every empty state, chips where
a sentence would do, and no white space. When adding a feature, prefer one
sentence over three labels, and nothing over a caption that restates the
control. docs/REVIEW.md lists the places that need thinning as of
2026-09-24.

## Parked and hidden

- `radar.timeline.modelFrames`: HRRR forecast radar, off behind
  `modelFramesEnabled = false`.
- `home.verdict.trackRecord`: built and hidden until the score is defined
  against what Barry claims (see ROADMAP D6).
- `FrontMorph`: front progs blended onto the radar clock, unused.
- `ComplicationView.rectangular`: unused since the family was dropped.
- `docs/ROUTES.md`: a design draft for `/glance` and `/route`; neither
  route exists.

## Known defects (found during the 2026-09-24 inventory)

Main page, alerts and sensors:
- Background calibration ignores the selection: `BackgroundRefresh.run`
  recalibrates whenever the sensor is on, while the foreground path
  calibrates only for My location. A selected remote airport can feed the
  phone's calibration, which is the corruption the foreground comment
  warns about.
- The observed-storm alert posts `storm.detail` as-is, so the `{eta}`
  placeholder the Conditions card substitutes can appear in a notification.
- Lightning alerts abbreviate the direction ("to the w of KLUK"); every
  other surface spells it out, and `AlertTests` expects the abbreviation.
- The Data sources card can be hidden, which removes the CC BY credit its
  own comment says is required.
- Alerts never fire while the app is open; only background refreshes
  check them.
- The iPad dashboard shows the radar column even when the Radar card is
  hidden.
- The Conditions card does not count clouds as content, so a station with
  clouds only gets no card.
- Calibration does not run on the first payload shown (`onChange` without
  `initial`).
- The front watch UI (`FrontBanner`, `FrontDetailView`, `FrontCompass`) is
  referenced by nothing; `/front` is fetched after every load and read only
  for the complication snapshot, and the watch never receives it.
- Stale comments: the hero header (calibration controls moved), the phone
  trace (60 min, actually 48 h), the Settings header (three modes),
  the 48h chart window is really −24 to +48.

Radar and Aloft:
- The Troughs chip draws nothing unless Fronts is also on and Front lines is
  on: `RadarPanel.frontStyle` passes `lines: false, pips: false` and
  `FrontGlyphs.draw` returns early on that.
- Key and options texts disagree with the code: the nowcast is "the last
  two" frames in the key but up to three from the server; the Wind key says
  10 m wind at every rail stop; the More sheet says wind under 3 kt is not
  drawn, which is true only for Arrows; the lightning window is 20 min on
  the server, 20 in the key, 15 in the `BarryAPI` comment and 900 s in the
  Swift default.

Watch, complications and widgets:
- The 3 h change is shown in hPa beside an inHg label on the small and
  rectangular lock widgets and on `ComplicationView.rectangular`; the Graph
  and METAR complications show hPa numbers with no unit. The watch page,
  the medium trend widget and the Live Activity convert correctly.
- The lock screen and small Pressure Trend widgets use sea-level pressure
  (`currentPressureHPa`) and ignore the airport rule and the sensor; every
  other surface uses `displayPressureHPa`.
- The phone overwrites the watch's barometer switch on every sync, so a
  value set on the watch reverts.
- Complications can lag a station change until the watch app has run.
- A background Live Activity update can change the event label while the
  activity's kind stays the old one.

Backend:
- Three fallback paths call AWC outside the budget gate: the cold-start
  `/front` query, `_station_obs_bbox`, `_nearest_via_bbox`.
- `/combined` looks up runways with the ID the client typed, not the
  corrected station.
- `/radar/field` does not cache failures, so a failing upstream is retried
  on every request up to the budget.
- `/stations/search` accepts one character but returns nothing under two.

Docs that disagree with the code:
- CLAUDE.md says the bulk METAR table refreshes every 5 min (code: 600 s)
  and that flashes are held 15 min (code: 20). The complication bundle ID
  in CLAUDE.md is stale. The `/radar/pressure` docstring says isallobars at
  ±1/2/3 hPa (code: every whole hPa, no cap). WIDGETS.md under-describes the
  small Field widget.

## Document log

- 2026-09-24: first version, from a full read of the sources by three
  sweeps (main page; radar and Aloft; watch, widgets and backend).
