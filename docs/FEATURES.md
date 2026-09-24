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
- Rules: the saved reading is used only if its station matches. The same
  cold start runs on the watch (`watch.page.offline`).

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
- Rules: the rail skips chart, forecast and radar. The radar column follows
  the Radar card's visibility.

## Home: the hero

For: everyone. Fixed at the top; not a card.

### home.hero.stationRow
- Seen: an airplane icon, "KLUK · Cincinnati/Lunken…", a chevron. The
  menu lists saved locations and "Follow on lock screen".
- Lives: `HeroView.swift` › `StatusRow`.
- Data: `pressure.station`, `pressure.name`, `SavedLocationsStore`.

### home.hero.freshness
- Seen: one short word on the right of the station row: "Local · now",
  "Local · carried", "Local · Nm ago" when a sensor reading is shown;
  otherwise "Calibrating…", "Settling…", "Paused"; otherwise "METAR Nm
  ago"; or "saved HH:MM" for a reading from disk, orange once the refresh
  behind it has failed.
- Rules: once a local reading shows, the label reports its trust tier and
  age, never the raw motion classifier. The "refreshed HH:MM" second line
  went in the 2026-09-24 thinning.

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

### home.hero.sourceLine
- Seen: one quiet caption under the number, and none for the plain
  sea-level reading: "Altimeter setting · sea level 30.24" at the field, or
  "Phone sensor · station 29.92 · +0.04" when the phone's reading is the
  headline.
- Lives: `HeroView.sourceLine`.
- Rules: the altimeter shows when an airport is selected or the device is
  within 3 NM (`PressureStore.isAtAirport`); it is never blended with the
  phone's calibration, and the phone never headlines at an airport. This
  line replaced the ALTIMETER and LOCAL capsules and the tap-to-compare
  (2026-09-24).
- For: P E B.

### home.hero.microTrend
- Seen: "sensor ↓ 0.03 inHg in last 42 min", orange with "falling faster
  than the station shows" when the sensor is sharper. Sits with the
  reasoning under the verdict, so it rolls up with it.
- Data: `BarometerManager.microTrend` (60 min buffer, 3 trusted points over
  5 min), `tendency.delta3h`.
- Rules: only when the phone is the headline. Sharper means the local 3 h
  rate exceeds the METAR's by 0.7 hPa with the same sign.
- For: E B.

### home.hero.tendencyBadge
- Seen: trend arrow, signed 3 h change, "3h", tinted by class.
- Data: `pressure.tendency`. Classes: rising fast at +1.5, rising at +0.5,
  steady, falling at −0.5, falling moderately at −1.5, falling fast at
  −3.0 hPa per 3 h. Intensity maps 1.5 to 4.0 onto 0 to 1.
- Tests: `TendencyParityTests` against the Python fixture.
- Rules: mirrored by hand in `backend/app/tendency.py`.

### home.hero.verdict and home.hero.supportingLine
- Seen: the verdict in headline type beside a bar in the tendency colour,
  then one grey line: what agrees or disagrees with it, or failing that
  the rate ("0.03 inHg per hour, front pace", silent under 1.5 hPa per 3 h,
  "storm pace" at 3.0), with "Low confidence." on the end when the caveats
  say so or confidence is under 0.5. A tap on the verdict or the bar rolls
  the line up.
- Lives: `HeroView.wordsBlock`, `supportingLine`, `rateContext`, `honestyNote`.
- Data: `/combined.verdict`, `reading.explanation.summary`, `reading.rate3h`,
  `reading.caveats`, `reading.confidence`.
- Settings: `heroWordsExpanded` true.
- Rules: the reason for low confidence is deliberately not shown. The
  chevron and the separate rate and confidence lines went in the
  2026-09-24 thinning.

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
| 10 | `sources` | (the page footer) | not a card since 2026-09-24 | always, at the foot of the page |

### home.cardMenu
- Seen: a long press on a card opens its menu: the card's own options,
  then "Hide card". Wind: Runway, Auto, Compass only. Forecast: Summary,
  Changes, Hourly, Chart. Conditions: boundary layer above ground or sea
  level. Here: "Backcountry estimates" (only after the one-time disclaimer
  has been accepted in Settings). Lightning, TAF and Sensor have Hide card
  alone. No gear or other chrome on the cards.
- Lives: `ContentView.cardMenu`; `HomeCard.hasMenu`.
- Settings: the same keys as Settings › Cards and screens, which keeps its
  rows so the options stay findable.
- Rules: the chart (drag to select) and the radar map (pan and pinch)
  have no menu, so their gestures keep working; the sources line is not a
  card. A hidden card comes back from Settings › Cards.
- Tests: none; UI tests do not long-press.

### settings.cards
- Seen: Settings › Cards: one row per card with its title, a switch and a
  drag handle. No presets (the "Set up for" choice replaced them), no card
  descriptions, no footer, no Live Activity switch; thinned 2026-09-24.
- Tests: none.

### settings.audience (Set up for)
- Seen: the first row in Settings, "Set up for": Flying, Soaring, Drones,
  On the water, Everyday, Weather watching. Onboarding asks the same thing
  on its second page, "What will you use Barry for?", as six rows with an
  icon each. Choosing one writes a bundle of existing settings; everything
  stays editable afterwards.
- Lives: `HomeLayout.swift` › `Audience` (`layout`, `windUnit`,
  `runwayWinds`, `aloftCeilingFt`, `alertLevel`, `radarLayers`, `apply`).
- Settings: `audience` (unset until chosen; Settings shows Flying).
- The bundles:

| | Cards shown, in order | Wind | Runway winds | Aloft ceiling | Alert on | Radar opens with |
|---|---|---|---|---|---|---|
| Flying | lightning, chart, conditions, wind, Here, forecast, radar | knots | auto | 18,000 | fast | radar, fronts, station barbs, lightning |
| Soaring | lightning, chart, conditions, forecast, radar, wind, Here | knots | auto | 12,000 | fast | radar, wind, lightning |
| Drones | lightning, wind, forecast, chart, radar, conditions | knots | compass | 6,000 | fast | radar, wind, lightning |
| On the water | lightning, chart, wind, forecast, radar | knots | compass | 6,000 | fast | radar, isobars, wind, fronts, lightning |
| Everyday | lightning, chart, forecast, radar, sensor | mph in the US, else km/h | compass | 12,000 | moderate | radar, lightning |
| Weather watching | lightning, chart, radar, forecast, conditions, sensor | mph in the US, else km/h | compass | 12,000 | fast | radar, isobars, troughs, fronts, lightning |

- Rules: the sources footer and the chart always show. The pressure,
  temperature and alert switches are not touched; onboarding's own pages
  and Settings set those.
- Tests: `AudienceTests` (every layout has every card once; the bundles'
  key choices).

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
  analysis card ("A trough passed", net, swing, steepest); a caveat line
  ("Dashed line is forecast.", orange when the forecast is stale or
  missing). The legend row ("deeper = faster change · tap or drag to
  read") went in the 2026-09-24 thinning.
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
- Seen: groups separated by space, each a title row and at most one grey
  line: density altitude with the field elevation, a humidity note and a
  trend; clouds with the category and a chevron (the way into Aloft), the
  layer list and a 12 h trend when the cover changes by 40 points; the
  boundary layer top (AGL or MSL) with the ride sentence ("Bumpy below
  4,200 ft, strong thermals."), where the top is headed, and in daylight
  the cloud base by the spread ("Cumulus base about 4,800 ft AGL.", or
  "Blue thermals; cloud base would be 4,800 ft AGL." when the layer tops
  out below 85% of it), all on the same line; storms (at the field, in the area, likely, possible) with
  distance, motion and timing; fog (likely, possible, overnight).
  Thinned 2026-09-24: no dividers, no separate "Clouds and winds aloft"
  row, no ride info button, no "Cover holds near 60%" line.
- Lives: `FieldConditionsView.swift`.
- Data: `/combined.conditions`, `current.clouds`, `forecast.hourly`.
- Settings: `boundaryLayerReference` agl.
- Tests: the Aloft UI test taps the Clouds row (`conditions.clouds`);
  `CloudBaseTests` covers the spread rule (`Shared/Models.swift` ›
  `CloudBase`: 400 ft per °C of spread, nothing under 1 °C or over
  15,000 ft). Night comes from `SunTimes.isNight`, shared with the hourly
  forecast card.
- Rules: the card exists only with density altitude, boundary layer, fog,
  storm or cloud content. The Clouds row always shows while there is a
  way into Aloft, "No report" when the station says nothing about the sky.
- For: P S D. The cloud base is the soaring line (review 2026-09-24).

### card.strip (Here, off-field) and Backcountry
- Seen: "Here" with the nearest station, its distance, direction, height
  difference and age. With Backcountry on: an estimated altimeter setting
  with a ± and a "rough" flag, the sources line (sensor, station, model),
  "Set 30.02, panel should read about 1,240 ft", density altitude and
  model wind, and an info sheet ("About the estimate") with each source's
  value and the 14 CFR 91.121 disclaimer. The "est." capsule beside the
  title went on 2026-09-24; the altimeter line keeps its own "est.".
- Lives: `Backcountry.swift` › `StripCard`, `StripEstimate`.
- Data: the phone sensor (calibrated, under 2 h old), `current.altim`, the
  model's sea-level pressure adjusted by the station's offset, GPS or fused
  altitude.
- Settings: `backcountryEnabled` false (one-time disclaimer). One switch
  since 2026-09-24: the estimates use the phone sensor whenever the live
  phone sensor is on, and the phone asks the watch to turn its barometer
  on with Backcountry (the watch's own switch still wins). The old
  "Use phone sensor" and "Use watch sensor" switches and their keys are
  retired.
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
- Set up for drones (`audience` = drone): one more line, "At 260 ft: 12 kt
  now, 20 kt by 5 PM.", from the model's 80 m wind (`forecast.hourly.wind80m`),
  the peak over the next six hours when it is at least 3 kt more
  (`RunwayWindsView.swift` › `DroneWind`). It reports; no limit is
  applied. Tests: `DroneWindTests`.
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

### home.footer (was card.sources)
- Seen: at the foot of the page, the Barry mark and under it one quiet
  line: "KLUK aviationweather.gov · forecast Open-Meteo.com (CC BY 4.0) ·
  radar RainViewer, NOAA NEXRAD · lightning NOAA GOES · fronts NWS WPC".
- Lives: `ContentView.glanceCards` footer, `DataSourceFootnote`.
- Rules: it carries the forecast data's required credit and RainViewer's,
  so it is not a card and cannot be hidden or moved. The `.sources` case
  stays in `HomeCard` so stored layouts still decode; it draws nothing and
  the Cards editor leaves it out. The "Updated" time went with the card.

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

### settings.screen
- Seen: one short list, no footers (thinned 2026-09-24): a first group with
  Set up for, Live phone sensor, Cards and Backcountry; Alerts (pressure changes with
  an "Alert on" picker under it while on, storms, each with a one-line
  subtitle; "Quiet hours" while either is on; the permission warning when
  denied; Send a test alert; Lock screen); Units (three segmented
  pickers); "Cards and screens" with one row each for the Wind card, the
  Forecast card, how the Radar opens, the Aloft ceiling and the Boundary
  layer reference, the value on the right; Locations.
- Lives: `SettingsView.swift`.
- Rules: the per-mode footers (`RunwayWindsMode.footer`,
  `ForecastCardStyle.footer`) were deleted with the footers they fed.

### settings.locations.addAirport and settings.locations.addPlace
- Seen: live search from two characters via `/stations/search`; Add checks
  the station with `/combined`, refuses one with no reports, and saves the
  canonical ID (I67 becomes KI67). Places geocode with CLGeocoder.

## Alerts and background

Lives: `StormAlerter.swift`, `BackgroundRefresh.swift`, `BarryApp.swift`. All
alerts are local notifications, checked after every fresh reading (the
app's own loads and the background refresh). Each has a latch date and a
cooldown.

| Slug | Trigger | Text | Cooldown | Switch |
|---|---|---|---|---|
| `alert.pressure.fall` | the 3 h change at or past the level's fall: fast −3.0, moderate −1.5, small −1.0 hPa | "Pressure dropping fast" from −3.0, else "Pressure falling"; the change, the place, the verdict | 3 h | `pressureAlertsEnabled`, `pressureAlertLevel` |
| `alert.pressure.rise` | at or past the level's rise: fast and moderate +1.5, small +1.0 | "Pressure rising sharply" from +1.5, else "Pressure rising" | 3 h | `pressureAlertsEnabled`, `pressureAlertLevel` |
| `alert.storm.lightning` | lightning reported within 30 min, within 25 mi, and heading this way or within 10 mi | "Lightning nearby", distance, direction, ETA | 1 h | `stormAlertsEnabled` |
| `alert.storm.observed` | storm risk observed within 10 mi | "Thunderstorms at PLACE" | 1 h | `stormAlertsEnabled` |
| `alert.storm.forecast` | storm risk likely, starting within 3 h | "Thunderstorms likely" with the window | 6 h | `stormAlertsEnabled` |
| `alert.test` | Settings › Send a test alert | samples at +3 and +5 s | none | either |

- Rules: evaluated after every fresh reading, foreground and background;
  the latches stop repeats. Lightning beats a forecast storm; one storm
  alert per check; a pressure and a storm alert can fire together. Front
  statuses must never feed notifications. Directions are spelled out and
  the storm sentence's `{eta}` slot is filled, as on the card. The migration turns pressure alerts on for anyone
  who had the old single storms switch.
- Quiet hours (`alertsQuietHours`: off, 10 PM to 7 AM, 11 PM to 6 AM,
  9 PM to 8 AM): alerts in the window arrive with no sound and at the
  passive interruption level, waiting in Notification Center; nothing is
  dropped. The fall and rise latches keep their pre-level names
  (`pressure.falling_fast`, `pressure.rising_fast`) so an update did not
  reset cooldowns.
- Tests: `AlertTests` (decisions, levels, quiet window across midnight);
  the latch is untested.
- For: E M P.

### bg.refresh
- Rules: task `me.wvr.barry.refresh`, earliest 15 min out (a floor, not a
  schedule), scheduled only when the sensor or an alert switch is on. Each
  run loads, recalibrates in the background if the sensor is on and the
  selection is My location (the same rule as the foreground), evaluates
  alerts, syncs the Live Activity, reschedules.

### diagnostics.metrickit
- Rules: MetricKit daily payloads go to `/diagnostics`; nothing identifies
  the phone. This is the only telemetry. There is no usage data.

## Onboarding

Lives: `OnboardingView.swift`. Paged; Skip on every page finishes with
defaults and nothing turned on.

1. `onboarding.idea`: "It's the change, not the number", a sample verdict.
2. `onboarding.use`: "What will you use Barry for?", six rows
   (`onboarding.use.<audience>`); a tap applies that bundle
   (`settings.audience`) and moves on.
3. `onboarding.where`: "Where are you flying?" (or "on the water", or
   "Where should Barry watch?" for everyday and weather). Use my location
   (one fix, `/stations/nearest`) or Pick an airport (search). The
   location prompt fires here, never cold on the dashboard.
4. `onboarding.units`: pressure, wind and temperature pickers, seeded by
   region (inHg and °F in the US, hPa and °C elsewhere) and wind by the
   audience (knots when none was chosen).
5. `onboarding.sensor`: only on devices with a barometer; "Turn on local
   readings" or "Not right now".
6. `onboarding.alerts`: pressure changes, storms, lock screen; "Turn on"
   asks for permission. The "Checked in the background" caption went on
   2026-09-24.

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

### radar.credit
- Seen: nothing on the map itself since 2026-09-24. The sources paragraph
  in the key sheet and a line on the Data sources card ("Radar ·
  RainViewer, NOAA NEXRAD · lightning NOAA GOES · fronts NWS WPC") carry
  the credit RainViewer asks for; that card cannot be hidden.

### radar.layers (the model)
- The chip bar sits behind the Layers button (`radar.layers`, top right
  beside the key) on the full screen and the embed alike; whether it is
  open is not remembered, the layers are. With Radar off and the bar
  closed the bottom card disappears and the map has the whole screen.
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
  stays open; it loads on appear and on Try again. Under the frame time
  there is at most one note (`radar.note`): the wind altitude first, then a
  stale lightning feed, then a calm map with Wind on; usually none.
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
  Arrows under 6 km/h are dropped. The one note line says "Wind under 3 kt
  across the map." at the surface when nothing draws.
- Tests: the UI test turns Wind on.
- For: P S D M W.

### radar.rail.altitude
- Seen: a vertical rail, highest stop on top: SFC, 2.5k, 5k, 10k, 14k, 18k.
  Tap or drag. Full screen only, while Wind is on. The note line
  (`radar.altitudeNote`) says "Wind at about N ft. Other layers stay at the
  surface."
- Lives: `RadarView.swift` › `altitudeRail`; `RadarModel.swift` › `WindAltitude`.
- Data: `/radar/field/levels` once per region, all levels in one call
  (925, 850, 700, 600, 500 hPa).
- Settings: capped by `aloftCeilingFt` (stops up to `max(5000, ceiling)`).
- Rules: the streak ramp changes per stop (35 km/h at the surface to 130 at
  18k). The level is not remembered between opens. Other layers stay at the
  surface; the key's wind text names the level.
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
- Rules: draws on its own; the Fronts chip's line toggle does not apply to
  troughs (the renderer forces the line for `.trof`).

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
- Buoys (`radarBuoys`, off; "Buoys and coastal stations" in Map options,
  on in the "On the water" set and preset): NOAA's buoys and C-MAN
  stations join the slice (`/metars?buoys=1`), drawn in teal instead of a
  flight category. Their sheet shows wind, waves ("3.9 ft every 6 s"),
  sea-level pressure in the chosen unit with the buoy's own 3 h change,
  air and dew point, water temperature, and the NDBC row as the raw line.
  For: M.

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
  "Lightning". The note line says "Lightning feed catching up." when the
  feed is stale.
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
- Seen: "Map options": layer sets first (Flying, Wind, On the water,
  Weather, Just the radar; one tap sets every chip and closes the sheet),
  then four front toggles, Flow or Arrows, Barbs or Speeds, each with a
  caption.
- Lives: `RadarSheets.swift` › `RadarMoreSheet`; the sets are
  `Audience.RadarLayers` (`HomeLayout.swift`), the same bundles "Set up
  for" opens the radar with, written by `RadarLayers.apply()`.
- Tests: `AudienceTests.justTheRadarIsJustTheRadar`.

### radar.region.debounce
- Rules: each pan or zoom records the region; per layer only the last
  request within 0.7 s is sent. Wind, levels and pressure reuse their data
  while the zoom ratio is 0.8 to 1.25 and the centre is within 20% of the
  span; stations while 0.6 to 1.6 and within half the box; lightning until
  a move over 1.5°.

## Aloft

For: P S D. The column of clouds, temperatures and winds above the field.

### aloft.entry
- Seen: opens from the conditions card's Clouds row and the
  `-uitest-aloft` launch argument.
- Lives: `ContentView.aloftScreen` › `AloftView.swift` › `AloftScreen`.
- Data: `/aloft?lat&lon`: 25 hourly columns, levels 1000 to 400 hPa in feet
  and knots, cloud layers, freezing level, boundary layer.
- Rules: loads once; no retry. The `stale` flag from the server is not
  decoded. With no conditions block the ground is 0 ft MSL.

### aloft.navbar and aloft.menu.ceiling
- Seen: custom bar with Back, "Aloft", station and name, a Layers button
  (`aloft.layers`) and a ceiling menu (6,000 / 12,000 / 18,000 /
  24,000 ft). No header row over the column since 2026-09-24.
- Settings: `aloftCeilingFt` 18000, shared with Settings › Aloft and the
  radar rail's cap.

### aloft.scale
- Seen: the bottom 6,000 ft take 52% of the height; gridlines every
  2,000 ft; the 6k line is the scale break.
- Lives: `AloftMath.swift` › `AloftScale`.
- Tests: `AloftTests` (fractions, break, linear under 6k).

### aloft.layer.clouds, aloft.metarCeiling, aloft.layer.icing
- Seen: model cloud bands (dense fill at 70% cover) with cover, top and base;
  the METAR ceiling as a separate line labelled "BKN045 reported"; the
  freezing level as a dotted rule labelled "0°C · 8,500 ft"; the word
  "icing" on cloud between 0 and −20 °C. Labels are plain words in the
  line's colour (`AloftLabel`), not pills.
- Rules: the METAR ceiling does not move with the scrubber. A band's base
  label hides within 22 pt of the METAR line.

### aloft.layer.temp and aloft.layer.wind
- Seen: temperature over dew point per level the way a METAR writes them
  ("14/9", the dew point quieter), in the temperature unit; barbs with
  "230° / 25 kt". The numbers sit on a knockout, so the boundary layer
  and freezing lines pass behind them instead of through them.
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
- Seen: behind the Layers button in the bar: Clouds, Wind, Temp, Icing,
  Layer chips and a More menu ("Show every layer", "Clouds only"). Whether
  the row is open is not remembered.
- Settings: `aloftLayers` "clouds,wind,temp,icing".

### aloft.scrubber and aloft.animation
- Seen: a slider over the hours ("Now · 3:00 PM", "+N h · time"), haptic
  per hour, and the plot glides between hours over 0.35 s. The fixed
  "+24 h" end label went in the 2026-09-24 thinning.
- Tests: the UI test opens Aloft, toggles each chip, scrubs, picks a
  ceiling and comes back.
- Rules: that test leaves `aloftCeilingFt` at 12000 in the simulator, and
  it runs before the radar test, so the rail then stops at 10k.

### aloft.credit
- Seen: nothing on the screen since 2026-09-24. Open-Meteo's credit is on
  the Data sources card, which cannot be hidden. The surface band reads
  "KLUK · 483 ft" and "27011KT · 20°/15°" without a "METAR" prefix.

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
- Seen: since 2026-09-24 the watch opens on its last full page (chart,
  verdict and all) saved on the watch itself (`CombinedStore`), with "as
  of h:mm · METAR 3 h 10 min ago" at the foot, orange once the refresh
  behind it has failed. Only with no saved page does it fall back to the
  last snapshot (glyph, pressure, verdict) or Retry.
- Rules: the saved page is used only for the same station. It refreshes
  quietly behind the saved reading on open.

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
- Rules: the phone's "use watch sensor" value is applied only when it
  changes (`sync.watchSensor.lastFromPhone`), so a switch flipped on the
  wrist survives the phone re-sending its context at launch.

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
- Settings: `liveActivityEnabled` false, switchable in Settings › Alerts
  and onboarding. `liveActivity.followUntil`.
- Rules: starts only in the foreground, no push; stale after 2 h; ends 15
  min after the event clears, or when the event changes kind (a new one
  starts at the next foreground sync); after 90 min without an update it
  greys.
- Tests: none.

## Backend

Every client call goes through `Shared/BarryAPI.swift`. Per-client limit 60
requests a minute (`BARRY_RATE_PER_MIN`), 429 with Retry-After 30. Upstream
budgets: 30 AWC calls a minute, Open-Meteo in its own weighted units (a call per location, more for over ten variables): 500 a minute and 9,000 a UTC day (`OMBudget`, `barry_openmeteo_calls_today` on /metrics); spent budgets
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
| `GET /metars` | `lat`, `lon`, `half`, `buoys` | stations with wind, category, visibility, ceiling, altimeter, lightning, raw; with `buoys=1` also NDBC buoys and coastal stations (`kind` "buoy", waves, water temperature, pressure and its 3 h change) | bulk table (AWC box fallback); NDBC `latest_obs.txt` | 2 min; centre 0.2°, half 0.5°; 350 stations plus up to 120 buoys nearest first; NDBC once per 10 min for everyone, failures remembered 60 s and never block the stations | the radar station layer |
| `GET /radar/pressure` | `lat`, `lon`, spans | isobars, isallobars, grids, extrema | bulk table and history, no upstream | 5 min; centre 0.1°, spans 0.5°; two builds at a time | the radar pressure layers |
| `GET /lightning` | `lat`, `lon`, `half` | 0.02° cells, clusters, window 1200 s, coverage | GLM store | 60 s; centre 0.2°, half 0.5° | the radar lightning layer |
| `GET /radar/frames` | none | host and frames | RainViewer | 2 min | the radar |
| `GET /aloft` | `lat`, `lon` | 25 hourly columns, `stale` | Open-Meteo pressure levels | 1 h per 0.1° cell; last good 12 h | Aloft |
| `GET /radar/field` | `lat`, `lon`, spans | 35 points of wind, boundary layer, CAPE | Open-Meteo multi-point (35 weighted calls) | until five past the next hour, at least 10 min; centre 0.05°, spans 0.5°; last good copy for 6 h when the budget is spent or the model fails | the radar wind layer |
| `GET /radar/field/levels` | same | 35 points at five levels | Open-Meteo multi-point (35 weighted calls) | same hold and last good copy as `/radar/field` | the altitude rail |
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
- Tests: `backend/tests`, 304 tests; `test_property` reads the app's own
  OpenAPI document.

## Settings keys

All in `AppConfig.sharedDefaults`, the App Group suite, which is local to
each device (the watch keeps its own copies).

| Key | Default | Options and notes | Set from |
|---|---|---|---|
| `hasOnboarded` | false | | launch, onboarding |
| `audience` | unset | pilot, soaring, drone, marine, everyday, weather; writes a bundle of the keys below | onboarding, Settings › Set up for |
| `pressureUnit` | inHg | hPa, inHg; onboarding seeds hPa outside the US | Settings, onboarding, watch Settings (its own copy) |
| `windUnit` | mph | kmh, mph, knots; onboarding seeds knots; barbs and Aloft are always knots | Settings, onboarding |
| `temperatureUnit` | celsius | celsius, fahrenheit; onboarding seeds °F in the US | Settings, onboarding |
| `phoneBarometerEnabled` | false | starts or stops the barometer at once | Settings, onboarding |
| `pressureAlertsEnabled` | false | migrated once from the storms key | Settings, onboarding |
| `stormAlertsEnabled` | false | the historical single switch | Settings, onboarding |
| `alerts.migrated.v2` | false | migration guard | StormAlerter |
| `pressureAlertLevel` | fast | fast, moderate, small (hPa per 3 h to alert on) | Settings › Alerts |
| `alertsQuietHours` | off | off, 22-7, 23-6, 21-8 (local hours; alerts arrive silently) | Settings › Alerts |
| `alert.latch.*` | unset | cooldown dates for the four alert kinds | StormAlerter |
| `liveActivityEnabled` | false | | Settings › Alerts, onboarding |
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
| `backcountryUsePhoneSensor`, `backcountryUseWatchSensor` | retired | removed 2026-09-24; Backcountry is one switch, sent to the watch as `watchBarometerEnabled` | |
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
| `radarBuoys` | false | buoys and coastal stations in the station layer | radar Map options, the water set and preset |
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
| `sync.watchSensor.lastFromPhone` | unset | the last "use watch sensor" value the phone sent; the watch applies a new value only when it changes | PhoneSync |
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

## Known defects and limitations

Found during the 2026-09-24 inventory; the code fixes landed the same day
(commit after 33a2b50). What remains is either a limitation of the platform
or a design choice recorded so nobody re-reports it.

- **Complications can lag a station change** until the watch app has run.
  WatchConnectivity delivers the phone's context only to a running watch
  app, which then reloads and rewrites the snapshot the complication reads.
  Nothing on the phone side can shorten that.
- **The front watch UI** (`FrontBanner`, `FrontDetailView`, `FrontCompass`
  in `FrontWatchView.swift`) is parked: referenced by nothing, `/front` is
  still fetched after every load for the complication snapshot's front
  arrow, which only the unused rectangular view of the trend complication
  draws. The DEBUG "Show sample front watch" button has no visible effect.
- **The Aloft UI test leaves `aloftCeilingFt` at 12000** in the simulator
  and runs before the radar test, so the rail then stops at 10k. Harmless
  for the test; reset the key if a hands-on check needs 18k.
- **The chart's 48h window is −24 h to +48 h.** The name stays; the label
  matches what pilots asked for.

Fixed on 2026-09-24 (kept here for one release so testers' reports can be
matched): the Troughs chip needing Fronts; the change shown in hPa beside an
inHg label on the lock widgets and the Graph and METAR complications; the
lock widgets ignoring the airport rule; background calibration for a remote
station; the `{eta}` placeholder in the observed-storm alert; abbreviated
directions in lightning alerts; the hideable Data sources card; alerts only
firing from background refreshes; the iPad radar column ignoring a hidden
Radar card; the Conditions card ignoring clouds; the first payload skipping
calibration; the phone overwriting the watch's barometer switch; a
background Live Activity update changing the label under the old kind; the
key and options texts that disagreed with the code; three AWC calls outside
the budget gate; runways looked up by the typed ID; `/radar/field` not
caching failures; `/stations/search` accepting one character.

## Document log

- 2026-09-24: first version, from a full read of the sources by three
  sweeps (main page; radar and Aloft; watch, widgets and backend). The
  defects the read found were fixed the same day; see Known defects. The
  hand-made thinning pass started the same evening with the hero and the
  radar card (docs/REVIEW.md).
