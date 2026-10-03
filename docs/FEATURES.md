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
  menu lists saved locations, "Follow on lock screen" and "Plan a route"
  (`card.route`).
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
| 2a | `fields` | Fields | yes | two or more airports saved |
| 2b | `route` | Route | yes | a route is set |
| 3 | `taf` | TAF timeline | no | the station has a TAF, or LAMP guidance |
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
  alone. Route: Reverse, Plan another, Clear route. No gear or other
  chrome on the cards.
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
| Flying | lightning, chart, fields, route, conditions, wind, Here, forecast, radar | knots | auto | 18,000 | fast | radar, fronts, station barbs, lightning |
| Soaring | lightning, chart, conditions, fields, route, forecast, radar, wind, Here | knots | auto | 12,000 | fast | radar, wind, lightning |
| Drones | lightning, wind, forecast, chart, radar, conditions | knots | compass | 6,000 | fast | radar, wind, lightning |
| On the water | lightning, chart, wind, forecast, radar | knots | compass | 6,000 | fast | radar, isobars, wind, fronts, lightning |
| Everyday | lightning, chart, forecast, radar, sensor | mph in the US, else km/h | compass | 12,000 | moderate | radar, lightning |
| Weather watching | lightning, chart, radar, forecast, conditions, sensor | mph in the US, else km/h | compass | 12,000 | fast | radar, isobars, troughs, fronts, lightning |

- Rules: the sources footer and the chart always show. The pressure,
  temperature and alert switches are not touched; onboarding's own pages
  and Settings set those.
- Tests: `AudienceTests` (every layout has every card once; the bundles'
  key choices).

### card.fields
- Seen: "Fields": every saved airport on its own line, the category dot,
  the ID, wind as "240@8" (with "G15" when gusting 3 kt over), the
  altimeter in the chosen unit, the trend arrow, and under it the first
  sentence of that field's verdict. The selected field's line is tinted;
  tap a line to switch to it. Shows only with two or more airports saved.
- Lives: `iOSApp/FieldsCard.swift`; `ContentView.homeCard(.fields)`.
- Data: `/glance?stations=KLUK,KI67&tz=` (up to eight), reloaded with the
  page.
- Rules: the verdict here is built without the forecast, so it can be
  plainer than the hero's. Places and My location are not listed. A long
  press on a line other than the selected one offers "Route to KI67",
  which sets a route from the current station (`card.route`).
- Tests: `FieldsCardTests`; backend `test_glance.py`.
- For: P S.

### card.route, route.screen and route.planner
- Hidden since 2026-10-02 behind `RouteSettings.enabled = false` (Jordan:
  unfinished, and what it would take to finish it unclear; hide it until
  it can be worked on, do not remove it). With it off nothing offers a
  route, the card is left out of the home layout and its settings list,
  the cruise speed setting is not shown, and a route already set is not
  drawn. The code, its tests and `/route` stay as they are; flipping the
  flag brings it all back.
- Seen: "KLUK → KDAY" and "49 NM · 29 min", then three lines: "Depart"
  with the category, wind as "050@9" and the altimeter; the way ("MVFR at
  KI69", "VFR along the line", "lightning 12 NM off the line", "cold
  front at 20 NM"); "Arrive 6:06 PM MVFR 85 min before sunset", with the
  TAF's TEMPO group in orange when one covers the arrival hour. Tap opens
  the route screen: a map with the two fields and the great-circle line,
  corridor stations coloured by category, and a list of them with
  distance along the line and wind; a footnote says the time is still air
  and the corridor is not an airway; Reverse and Clear route. The planner
  is a sheet titled "Plan a route" with From and To fields, the saved
  fields and the recent pairs to pick from.
- Lives: `iOSApp/RouteViews.swift` (`RouteSettings`, `RouteWords`,
  `RouteCard`, `RouteScreen`, `RoutePlannerSheet`);
  `ContentView.homeCard(.route)`.
- Starts from: the hero's station menu ("Plan a route", last item), a
  long press on a Fields line ("Route to"), and the Route card's own menu
  ("Plan another").
- Data: `/route?from&to&speedKt&tz`.
- Settings: `route.from`, `route.to`, `route.recent` (last five pairs),
  `cruiseSpeedKt` (Settings › Cards and screens, 60 to 200 kt).
- Rules: a route never changes the selected field; the hero and chart
  stay on it. Still air only, no alternate, one leg. The corridor is 15
  NM each side of the line; lightning counts within 30 NM. Arrival
  category comes from the destination's TAF at that hour, else LAMP's
  nearest hour (the screen's footnote then says "KI69 has no TAF;
  arrival by LAMP"), else its current report ("MVFR now"). The screen's map is a plain map, not the
  radar.
- Tests: `RouteWordsTests`; backend `test_route.py`.
- For: P S.

### card.lightning
- Seen: a tinted card: "Lightning 12 mi to the west" (or "at the field"
  under 3 mi), then "13 min ago, moving toward you, here around 4:10 PM ·
  98 flashes within 100 mi". Opens the radar.
- Lives: `LightningBanner.swift`.
- Data: `/combined.lightningNearby`.
- Rules: only credible GOES flashes count, here and on the map, the
  storm row, alerts and the route (`flashes.py`, since 2026-09-26): one
  flash is enough when the radar has 30 dBZ or more within about 10 km of
  it (a convective core); where the radar shows no storm or cannot see,
  it takes three flashes within 20 km over the 20 minutes. A pilot saw
  "lightning nearby" under a clear sky; on that day 22 of the 101 lone
  flashes inside radar coverage had no echo under them. Station reports
  (TS, VCTS, LTG remarks) are not filtered.
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
  At a field with no TAF the strip comes from LAMP, hour by hour, with no
  hatching, and the sentence begins "LAMP:" ("Now MVFR. LAMP: ..." for a
  bust). The TAF widget does the same.
- Lives: `TafTimelineCard.swift`; `Shared/TafTimeline.swift`, `TafStrip.swift`.
- Data: `/combined.taf`, else `/combined.lamp`; `forecast.sun`, `current.fltCat`.
- Rules: a TAF always wins over LAMP. LAMP ceiling and visibility are
  bands, so its categories are the bands' categories.
- Tests: `TafTimelineTests` (including `lampStandsInWhereNoTafIsIssued`),
  `CardRenderTests`; backend `test_lamp.py`.
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
  distance, motion and timing; rain ("Rain from about 2:40 PM", "Rain
  until about 3:10 PM", "Raining now") with how heavy it is, where it
  is and which way it moves, from the radar's rain rate carried along
  its motion, within ninety minutes only; fog (likely, possible,
  overnight).
  Thinned 2026-09-24: no dividers, no separate "Clouds and winds aloft"
  row, no ride info button, no "Cover holds near 60%" line.
- Lives: `FieldConditionsView.swift`; the rain row's words in `RainLine.swift`.
- Data: `/combined.conditions` (the rain line is `conditions.rain`, from
  `rainstart.py` on the server), `current.clouds`, `forecast.hourly`.
- Settings: `boundaryLayerReference` agl.
- Tests: the Aloft UI test taps the Clouds row (`conditions.clouds`);
  `RainLineTests` covers the rain row's words and decoding;
  `CloudBaseTests` covers the spread rule (`Shared/Models.swift` ›
  `CloudBase`: 400 ft per °C of spread, nothing under 1 °C or over
  15,000 ft). Night comes from `SunTimes.isNight`, shared with the hourly
  forecast card.
- Rules: the card exists only with density altitude, boundary layer, fog,
  storm, rain or cloud content. The rain row exists only while rain is
  here or due within ninety minutes; a dry radar shows nothing, and so
  does one whose echo is not moving (there is nothing to time). The Clouds row always shows while there is a
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
  line: "KLUK aviationweather.gov · forecast NOAA HRRR and NBM · radar
  RainViewer, NOAA NEXRAD · lightning NOAA GOES · fronts NWS WPC", with
  "forecast Open-Meteo.com (CC BY 4.0)" instead where the forecast came
  from Open-Meteo (off the HRRR grid).
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
- Rules: one load task for the panel's life (the three states sit in a
  `ZStack` that owns it), and a load whose task was cancelled reports
  nothing. Until 2026-10-02 the states sat in a `Group`, which hands its
  `.task` to whichever state is showing: a cancelled load reported
  failure, the failure view started a load, the load changed the state
  and cancelled itself, six thousand cancelled requests in thirty
  seconds. Seen only when the radar opened in the first moments after
  launch (`-uitest-radar`), not when opened by hand.

### radar.map.base
- Seen: muted Apple map, no points of interest, no compass, a red pin on the
  station, opening span 3.2°, minimum camera distance 60 km.
- Lives: `RadarMapView.swift` › `makeUIView`, `updateUIView`.
- Rules: every overlay's state (`PressureFieldOverlay`,
  `FrontFieldOverlay`, `LightningOverlay`) is behind a lock (`Locked`):
  the main thread replaces it while MapKit's drawing queue reads it, and
  a renderer reads it once per draw. Unguarded, replacing the pressure
  state thirty times a second crashed in `swift_deallocClassInstance`
  within a minute (iOS 17 simulator, 2026-10-02); at once a radar frame
  the same race had simply never been hit. `OverlayStateTests` replaces
  the states 20,000 times under three readers and dies the same way with
  the lock out. When the map is taken down (`dismantleUIView`) the crossfade's
  display link, the pending tile warm-up and the flow layer are stopped:
  closing the radar in the middle of a crossfade crashed on iOS 17, the
  link firing into a renderer whose map was gone (found 2026-10-02). When
  the station coordinate changes the pin moves and the map
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
- Seen: rain echoes in Barry's palette. While a loop plays the rain
  travels between frames; on the slider the frames crossfade. Chip
  "Radar".
- Lives: `RadarMapView.swift` › `RadarTileOverlay`, `Coordinator`;
  `RadarPalette.swift`; `RadarGlideView.swift`, `RadarGlide.swift`.
- Data: `/radar/frames?span=hour|day` (host and the span's frames, each
  with its `kind`; see `radar.timeline`). Since 2026-09-25 the host is
  Barry itself: MRMS frames every ten minutes,
  tiles at `/radar/tiles/<time>/512/{z}/{x}/{y}/2/0_1.png` drawn on Tower
  in RainViewer's Universal Blue colours, so the app reads them back
  exactly as it read RainViewer's. Model frames come in the same shape
  from `/radar/model/<key>/...`. RainViewer (same URL shape, 7 past
  frames and up to 3 nowcast, whatever the span) when Barry's frames are
  missing or over 20 minutes old, or when `BARRY_RADAR_SOURCE=rainviewer`.
  Native zoom 7, ancestors cropped and upscaled beyond it.
- Seen, differently: MRMS is quality-controlled, so the faint night-time
  returns from birds and insects that RainViewer showed as pale blobs
  around the radar sites are gone.
- Settings: `radarShowRadar` true.
- Rules: alpha 0.75 full, 0.55 dimmed under Lightning, 0.02 for the
  frames about to be shown (the next two of the loop, going round, and
  the one either side on the slider; `Coordinator.framesNear`), 0 while
  the map moves. Only those frames' overlays are on the map at all
  (`Coordinator.syncAttached`): the one on screen, the near ones, and
  whichever is fading out; none while the GPU draws the loop. An overlay
  goes on when its frame is wanted and comes off once nothing has
  changed for a second (`pruneAttached`): MapKit re-composites its
  overlays when one goes, and taking them off mid-scrub showed as frames
  vanishing and overlapping for a tick (Jordan, 2026-10-02). A frame
  scrubbed to starts its crossfade from nothing even when its layer was
  just made, and a loop stopped by a scrub hands back to the frame's
  layer only once its tiles are in, under the GPU's picture, so the two
  are never painted over each other at full strength. Until
  2026-10-02 every frame of the span sat on the map at 0.02 to keep its
  tiles loaded: ten layers on the old one-hour timeline, thirty on the
  six-hour span, each blended over the whole screen on every refresh, and
  Xcode showed 14 fps on the phone; and with the rest then parked at
  true zero, seventeen layers all loading at once, MapKit drew the first
  tile it handed the frame on screen and none of the rest on about one
  cold open in ten (found 2026-10-02; 36 clean opens after the change).
  The near frames go on 0.8 s after the one on screen has its tiles, so
  it loads alone, and a frame with nothing to fade from (a cold open,
  the radar coming back) is shown outright rather than faded in. The
  tiles are kept in the app's own caches: fetched and repainted for the
  view on screen when a loop buffers, when the map settles after a move,
  and for the rest of the span once the loop is under way
  (`prefetchFrames`), so a frame going on the map is a cache read.
  Zoomed out past the source's native zoom (tile z under 7) a tile is
  asked for at 256 px and drawn over the same ground: a quarter of the
  pixels to download (a 62 KB tile is 19), repaint (5.9 ms a tile down to
  1.8, release build on a Mac) and hold on the GPU. Overlays are kept by the frame's `key` (the number its path ends
  in; a model frame's negated), not its time: the hour span's nowcast and
  the day span's model frame can share a valid time. Crossfade 0.3 s.
  Only a PNG is a tile: a 429 or 503 (Cloudflare's rate rule on the
  hostname answers a burst that way) is a miss, never cached, fetching
  pauses for its Retry-After and the renderers reload after it. Found
  2026-09-25: the first production run drew blank because the error
  pages had been cached as tiles.
  Palette: transparent below 5 dBZ, blues to 45, orange 45 to 50, red 55 to
  60, magenta 60 to 65, pale above. Tiles are repainted from RainViewer's
  colours; snow pixels pass through. Tile caches are sized in bytes (48 MB
  repainted, 24 MB source); `URLCache.shared` is 200 MB on disk; one ring of
  tiles is prefetched after each settle; in-flight requests are shared.
- The loop, on the GPU (`RadarGlideView`, since 2026-10-02): while a
  loop plays the radar is one Metal view over the map, not the tile
  layers, which sit at zero. For each pixel the shader asks where its
  rain came from: the server says how the rain moved between the two
  frames either side of the moment (`/radar/motion`, the nowcast's own
  block matching), the earlier frame is read that far forward along the
  motion, the later one that far back, and the two are blended, leaning
  to the nearer. Where the motion is right one shape travels; where the
  rain also grew or died, the blend fills it in or thins it out over the
  gap. The tile layers could only crossfade: a storm was two ghosts for
  half a second, then jumped. No more comes over the network: the
  pictures are the same tiles the map downloads (the source cache), read
  back to dBZ (`RadarPalette.codes`, kept 32 MB by URL) and laid side by
  side into one texture a frame for the tiles on screen
  (`RadarGlide.stitch`); Barry's colours are a lookup in the shader.
  Only the two frames of the moment and the next two are held
  (`RadarGlide.wanted`). The loop's frames come as stacks
  (`/radar/stack`, `RadarGlide.stackParts`, `RadarStackLoader`): the
  observed frames but the newest (which is on screen from its own tile),
  in runs of four, one request a tile for each run, read straight into
  the codes cache; a loop that is not evenly spaced falls back to a tile
  a frame. Buffering waits for the first run only, for every tile on
  screen, and the loop starts on those frames; the rest are fetched
  behind the clock. Since 2026-10-02 the hour loop is 12 requests for the
  view where it was about 42, the six-hour loop 30 where it was about
  115, and nothing else is fetched for the span when a loop starts (the
  frames a scrub could reach used to be, a tile each; a scrub now fetches
  as it goes). The motion is asked for when a loop starts and
  again when the newest frame or the region changes
  (`RadarModel.ensureMotion`); until it arrives, or for a pair it does
  not give, the frames crossfade in place. Starting, the tile layers go
  to zero once the first picture is up; stopping, the frame the loop is
  on comes back in its tile layer and the GPU holds that same frame until
  the tiles have been read in (`Coordinator.syncGlide`), so nothing is
  blank either way. A pan or zoom stretches the pictures held until the
  map settles and they are laid out again. Like the wind and the
  six-hour isobars the view sits above the map's own labels. Falls back
  to the tile layers if the shaders do not compile.
- Tests: `RadarPaletteTests` (colours, a tile read back to codes),
  `RadarGlideTests` (which frames a moment sits between, the frames to
  hold, the motion in map units, tiles stitched into place, the shaders
  compile); the UI test keeps Radar on.

### radar.timeline
- Seen: `[6h] [60] [slider] [Now]`, and the frame's time under them
  ("8:20 PM · 20m ago", "11:00 AM · 5h ago", "· nowcast +40m" in orange,
  "· model +3h" in purple). Until 2026-10-02 it was `[Now] [60] [slider]`
  over one hour of radar and thirty minutes of nowcast.
- The two replay chips are the two spans (`RadarSpan`). **60**, the hour
  span: every ten minutes from two hours back, then the nowcast; its loop
  is the last hour. **6h**, the day span: a frame every twenty minutes
  from six hours back, the newest frame, then each hour to twelve ahead;
  its loop is the last six hours (on the hour only at first: an hour
  between radar frames is a jump no renderer smooths). Tapping a chip puts the timeline on its span and
  plays it; tapping the one that is playing pauses. The 6h mark is the
  bare `goforward` symbol with "6h" set inside it, there being no
  `goforward.6h` (`ReplayGlyph`).
- What a frame is (`kind`): observed (MRMS), nowcast (the newest frame
  carried 10 to 60 minutes forward by the motion of the last three
  frames; no growth or decay), or model (HRRR's own composite
  reflectivity for that hour, `modelradar.py`). On the day span an hour
  within the nowcast's reach is the nowcast's, the rest the model's.
- How far the nowcast is shown is its own score's call: 30 minutes always,
  and each ten minutes more while that lead's CSI over the last three
  hours is at least 0.40 and beats leaving the rain where it was
  (`nowcast_leads`; the scores are on `/models/scores`). Measured on five
  hours of 2026-10-02: 0.70 at 10 minutes, 0.55 at 30, 0.44 at 60;
  persistence 0.64, 0.47, 0.36. Three frames of motion beat two by half a
  point.
- One clock for every layer that has a past and a future
  (`docs/RADAR_TIMELINE.md`): the isobars and the Pressure shading
  (`radar.layer.isobars`), the fronts, troughs and H and L
  (`radar.layer.fronts`). Wind, stations, lightning, advisories and the
  Change field only know now: they stay drawn, and the frame-time line
  says so at its far end ("Wind and stations show now.", "Other layers
  show now." past three names; `radar.nowOnlyNote`). It is beside the
  time, not under it, and whether it shows only changes with a tap or a
  scrub: never while the hour loop plays, throughout while the six-hour
  loop plays, and on a paused slider more than fifteen minutes from the
  newest frame (`RadarTimeline.showsNowOnlyNote`). The first version sat
  on a line of its own and followed the slider, so it came and went with
  every pass of a loop through now and the card jumped with it.
- A loop buffers before it plays (`RadarModel.startLoop`,
  `Coordinator.syncBuffer`): on open, on a replay chip, on a span change,
  the map shows the newest frame while every tile each of the loop's
  frames needs for the view on screen is fetched and repainted into the
  caches and MapKit's own loads of them finish; then the loop starts from
  its first frame. Ten seconds at most, after which it plays and fills in
  as it goes, as it always did. The chip reads as on from the tap and
  shows a small spinner in place of its glyph while it waits; a scrub,
  Now or the chip again cancels. Before 2026-10-02 the loop started at
  once and its first pass showed frames popping in.
- Lives: `RadarTimeline.swift` (the rules, pure functions);
  `RadarView.swift` › `radarControls`, `replay`; `RadarModel.swift` ›
  `setSpan`, `loopStart`, `playheadTime`.
- Settings: `radarAutoplay` true ("Play the last hour" or "Hold on the
  latest", in Settings › Radar). The radar always opens on the hour span;
  the span is not remembered.
- Rules: the loop is a clock, a moment in the weather, not a frame
  number (`RadarTimeline.advance`, `RadarModel.playClock`, ticked 30 times
  a second): it runs evenly from the loop's start to the newest frame
  (the hour in 3.85 s, a ten-minute frame every 0.55 s as before; the six
  hours in 8 s), rests there 1.65 s and goes round. The radar shows the
  frame nearest the clock; the isobars are drawn for the clock's own
  moment, so they glide while the radar steps, and the fronts and the H
  and L are the chart of that moment, crossfading to the next
  (`radar.layer.isobars`, `radar.layer.fronts`). The past
  only: forecast frames are never looped, only scrubbed to, and nothing
  is drawn ahead of its last chart. Scrubbing pauses. Now parks on the newest observed frame of
  the span on the timeline. A span's list is fetched the first time its
  chip is tapped and again once five minutes old; nothing else refreshes
  it while the screen stays open. When the day span's list cannot be
  fetched the timeline stays on the hour. Under the frame time there is at
  most one note (`radar.note`): the wind altitude first, then a stale
  lightning feed, then a calm map with Wind on; usually none.
- On the clock (since 2026-10-02, `LayerTimelines.swift`): the wind, the
  stations and the lightning follow the timeline too, each from a series
  of past hours the server keeps (`/radar/field/series`,
  `/metars/series`, `/lightning/series`), fetched when a loop starts or
  the slider leaves now with the layer on, and again when the newest
  frame or the region changes (`RadarModel.ensureClockLayers`). The wind
  is slid between the two hours either side of the moment as vectors
  (west backing to south passes through southwest), the streaks by the
  flow view blending two grids (`WindFlowView.setSecond`), the arrows in
  tenths of the hour in place. A station shows its latest report at or
  before the moment (a METAR at :53 stands for the hour after) and steps
  when the next comes, its marker reconfigured in place. The lightning is
  the twenty minutes before the last ten-minute mark, no arrival pulse.
  While a loop plays the map drives all three from the loop's clock
  (`Coordinator.stepClockLayers`) and what SwiftUI hands it waits; with
  the slider parked away from now the model hands the moment's own
  (`shownWindFieldOnClock`, `shownStationObs`, `shownLightning`). Where a
  series does not reach a moment (within 90 minutes for the wind and the
  stations; the lightning's own frame) the layer stays at now and the
  note under the frame time names it; the note goes by whether the
  series reaches the loop's two ends, so it holds steady while a loop
  plays. The histories fill over the hours after a server start.
  Advisories and the pressure-change field stay at now (Jordan: not
  wanted on the animation).
- Tests: `LayerTimelineTests` (the wind slid between hours, a station's
  report for a moment, the lightning's frame, where each cannot reach);
  `RadarTimelineTests` (loop starts, the clock, the frame nearest
  it, the frames kept warm, the time line's words, frame keys, contours, the field between two
  hours and its shape with the rise taken out); `OverlayStateTests`; the UI test checks Now, scrub and both loops' selection
  states.

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
- Data: `/radar/pressure` › `isobars` at now. Away from now (a paused
  slider more than fifteen minutes from the newest frame, or a loop
  playing), the lines of that moment, contoured on the phone
  (`PressureTimeline.swift`, the server's marching squares in Swift) from
  `/radar/pressure/series`: the field gridded at each hour and at now, all
  on one lattice. Past hours are gridded from the server's station
  snapshot nearest the hour, hours ahead are the field now plus HRRR's own
  change in sea-level pressure from now, so the lines leave now where the
  stations put them and move as the model moves them; a moment between
  two frames is the two slid together. One spacing throughout, the field
  now's. Off the model's grid there are no hours ahead. The Pressure
  shading follows the same field; the Change field does not.
- In the six-hour loop the lines are drawn by the GPU (`IsolineView`,
  Metal, a view over the map like the wind's): every pixel reads the
  pressure under it from the two grids either side of the moment, each
  through a cubic filter, slid together, and is on a line where that
  value crosses a multiple of the spacing. One draw of the whole screen
  at one moment, smooth by construction. The overlay renderer it replaces
  there is redrawn by MapKit a tile at a time, each on its own schedule,
  so a moving line was at two moments either side of a tile's edge and
  broke there; and its contours were straight between grid squares. The
  hour loop and a paused slider keep the renderer, where the lines are
  still or nearly, and labelled. While the GPU draws, whatever field
  SwiftUI hands the renderer is stripped of its lines first
  (`Coordinator.syncPressure`): a pan mid-loop brings a fresh field for
  the new area with its lines on, and until 2026-10-02 those were drawn
  under the GPU's (Jordan saw both sets). Falls back to the renderer if
  the shaders do not compile (`OverlayStateTests` checks that they do).
- The six-hour loop draws the field's shape, not its values
  (`PressureTimeline.pattern`): each moment's field with the area's own
  rise or fall between then and now taken out, and no labels on the
  lines, which are no longer the pressure of that moment. Why: behind a
  front the whole view was 2 hPa up in six hours, the isobars 2 hPa apart
  on a field 5 hPa across, so every line crossed the map during the loop
  and landed, when it went round, where its neighbour had started: lines
  running on a belt (Jordan, 2026-10-02, who took it for tweening across
  the wrap). With the rise out, a line moves when a trough or a ridge
  does. The hour loop and a paused slider draw the true isobars of the
  moment, labelled.
- Rules: the series is fetched only while Isobars or Pressure is on and
  the day span is up or the slider has left now, and again when the map
  moves to another region. While the hour loop plays the map redraws the
  lines from the loop's clock 20 times a second (`RadarLineSource`,
  `Coordinator.stepLines`), outside SwiftUI; the fronts only when the
  chart changes.
- Settings: `radarIsobars` false; `radarIsobarsSplit` migration gives
  isobars to anyone who had Pressure on. `radarIsobarLabels` true: the
  pressure written on each line; off (More sheet, "Pressure on each
  line", asked for by Jordan 2026-10-02) the lines alone, in the unit
  the key still names. The six-hour loop never labels.
- Tests: `PressureLabelTests`.

### radar.layer.wind
- Seen: grey streaks drifting with the wind (Flow) or arrows (Arrows),
  each arrow with its speed under it in the wind unit ("20 kts", since
  2026-09-25). Chip "Wind".
- Lives: `WindFlowView.swift` (the Metal shaders are a string in it,
  compiled on the device); `RadarMapView.syncArrows`.
- Data: `/radar/field?pad=0.5`: from the server's HRRR store, every point
  of a lattice the whole map shares (about 11 across the view and 8 down,
  the step from a fixed ladder) out to half a span past each edge of the
  view; or 7 by 5 inside the view from Open-Meteo off the HRRR grid
  (`source` says which); boundary layer and CAPE present but unused on the
  map. The winds aloft (`/radar/field/levels`) come the same way.
- Settings: `radarWindArrows` true (the Wind chip; historical name),
  `radarWindStyle` "flow" or "arrows".
- Rules: particles scale with view area (120 to 400), 30 fps cap, CPU
  simulation and one Metal draw call, anchored to the ground, a new grid
  bends existing streaks. Panning (since 2026-10-02): the grid reaches
  half a span past the view and is kept until the view has moved a fifth
  of its span, so wind is there wherever a pan stops; streaks live 15% of
  the view past each edge, and one carried out of reach comes back in on
  the side the pan uncovers with its trail already flown (`grown`), so
  that edge is never bare and nothing sprouts in step afterwards; a
  reading looks only at the lattice's samples within a step and a half.
  Arrows: the ones kept at a zoom are counted from the equator and the
  prime meridian, so the next grid keeps the same arrows; arrows in both
  the old set and the new stay on the map and are updated in place, new
  ones fade in over a quarter second. Before, the grid stopped 12% short
  of the view's own edges and was laid out afresh per region: a pan showed
  bare map, then every arrow moved.
  Arrows under 6 km/h are dropped. The grid is thinned on the phone to a
  lattice at least 76 points apart across and 60 down at the current
  zoom (every second, third... column and row), at the surface and at
  every level, and re-thinned on each zoom, so a denser grid never
  becomes a wall of arrows and numbers. The one note line says "Wind
  under 3 kt across the map." at the surface when nothing draws.
- Tests: the UI test turns Wind on.
- For: P S D M W.

### radar.rail.altitude
- Seen: a vertical rail, highest stop on top: SFC, 2.5k, 5k, 10k, 14k, 18k.
  Tap or drag. Full screen only, while Wind is on. Off the surface the
  map also draws that level's height contours from HRRR, solid near-black
  lines (near-white in dark mode) labelled in decameters ("318"), and the
  surface isobars step aside, and stay aside for as long as the rail is
  off the surface, even while a new view's height lines load or fail (a
  failed fetch keeps the old lines and is tried again after a rate-limit
  block; until 2026-09-25 it cleared them and the surface isobars came
  back under the altitude note). The note line (`radar.altitudeNote`) says
  "Wind and 700 mb heights at about 10,000 ft. Other layers stay at the
  surface." ("Wind at about ..." where there are no heights).
- Lives: `RadarView.swift` › `altitudeRail`; `RadarModel.swift` ›
  `WindAltitude`, `fetchHeights`; `PressureFieldOverlay.swift` (the lines).
- Data: `/radar/field/levels` once per region, all levels in one call
  (925, 850, 700, 600, 500 hPa); `/radar/heights` per level and region.
  Levels that lie underground (surface pressure under the level's) are left
  out of both, so 850 hPa draws nothing over the Rockies.
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
- Data: `/fronts`, fetched once per open, not tied to the region: the
  analysis, the earlier analyses back nine hours (`history`), and the 12
  and 24 h forecast charts. Each analysis is sent twice, to a tenth of a
  degree and then in whole degrees; the server takes the fine one (until
  2026-10-02 it drew whichever came last, the coarse one).
- Settings: `radarFronts` true; More sheet toggles `radarFrontLines`,
  `radarFrontPips`, `radarFrontWeak`, `radarFrontCenters` (all true).
- Rules: the map draws the chart of the moment the timeline is on, each
  one as WPC drew it (`RadarTimeline.fronts`). An analysis has the map
  from its own valid time until the next one's; the newest stands through
  now (it is usually two hours old). Ahead of now a forecast chart takes
  over half way between the chart before it and its own valid time. One
  chart gives way to the next by crossfade over twenty minutes of the
  timeline (`FrontMorph.crossfade`), about half a second of the six-hour
  loop; the key names the chart on screen ("WPC fronts at Fri 2 PM",
  "WPC fronts, forecast for Sat 8 PM"). No front is drawn anywhere a
  chart did not put it. For a few hours on 2026-10-02 fronts were slid
  between charts, each matched to the nearest of its type on the next
  one: WPC does not draw the same front the same way twice (four
  consecutive analyses that day held 62, 80, 48 and 97 segments; a third
  of the matched pairs had an end travelling over 500 km), and fronts
  broke apart and flew across the map. Until that day the forecast
  charts arrived unused, because a map with its own clock read
  tomorrow's front as today's; the radar's clock is now the only one.
  Pips sit on the left
  of travel. The key and the map share
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
  METAR bolt markers when Stations is off, the radar dimmed, and under it
  all a light violet wash where NOAA gives a 10 percent or better chance of
  lightning in the next hour, deeper as the chance rises (four steps, 10,
  30, 50, 70). Chip "Lightning". The key says what the wash is. The note
  line says "Lightning feed catching up." when the feed is stale.
- Lives: `LightningOverlay.swift`; `LightningMarkerView` in `StationLayer.swift`;
  the wash is a plain `MKTileOverlay` (`RadarMapView.syncLightningNext`).
- Data: `/radar/frames.lightningNext` and its tiles at
  `/radar/lightning/<time>/512/{z}/{x}/{y}.png` (MRMS's next-60-minute
  lightning probability, refreshed every two minutes on Tower; absent from
  RainViewer). `/lightning` (0.02° cells, 20 min window, clusters, coverage),
  refetched every 60 s, on a move over 1.5°, and on region change. The
  client sends no `half`, so the server's ±3° box applies: at continental
  zoom only the box around the centre shows flashes.
- Settings: `radarStorms` true.
- Rules: a quiet day draws nothing. The 60 s ticker runs while the embed
  is off screen.
- For: P M E W.

### radar.layer.advisories
- Seen: chip "Advisories" (off by default). SIGMET areas drawn solid and
  G-AIRMET areas dashed, outlined in their hazard's colour (convective red,
  IFR purple, mountain obscuration pink, turbulence brown, icing blue,
  surface wind orange) with a short label at the middle ("Conv", "IFR",
  "Turb", "Ice"); pilot reports of turbulence (waves) and icing
  (snowflake) from the last two hours, grey for smooth, yellow light,
  orange moderate, red severe. Tap a label or a report for a sheet: the
  name, heights ("5,000 ft to FL220"), valid time and the bulletin, or the
  report in words ("Light to moderate turbulence", altitude, aircraft,
  age) over the raw PIREP.
- Lives: `iOSApp/AdvisoriesOverlay.swift` (`AdvisoryPolygon`,
  `AdvisoryLabelView`, `PirepView`, `AdvisoryDetailSheet`, `AdvisoryInk`);
  `RadarModel.fetchAdvisories`; `RadarMapView.syncAdvisories`.
- Data: `/advisories?lat&lon&half` (half follows the map span, 3 to 30°).
- Settings: `radarAdvisories` false.
- Rules: report symbols draw in an image view of their own; MapKit
  recoloured an annotation view's own image and they came out black.
  Freezing-level lines from the G-AIRMETs are left out.
- Tests: `AdvisoryTests`; backend `test_advisories.py` on real feeds saved
  as fixtures.
- For: P S.

### radar.sheet.key
- Seen: a key listing only the layers that are on, plus sources.
- Lives: `RadarSheets.swift` › `RadarKeySheet`.

### radar.sheet.more
- Seen: "Map options": Presets first: the user's saved layer
  combinations as pills, the one matching the map filled in; a tap puts
  the map back that way and closes the sheet; a long press offers "Save
  these layers here", Rename and Delete; a "Save these layers" pill (just
  "Save" once there are some) asks for a name. Then Layers: every chip on
  the map as a switch with its icon (Radar, Pressure, Change, Isobars,
  Wind, Fronts, Troughs, Stations, Lightning, Advisories). Then four front
  toggles, Flow or Arrows, Barbs or Speeds, each with a caption. The fixed
  layer sets (Flying, Wind, On the water, Weather, Just the radar) went on
  2026-09-25 when presets replaced them.
- Lives: `RadarSheets.swift` › `RadarMoreSheet`; `RadarPresets.swift`
  (`RadarPreset`, `RadarPresetStore`).
- Settings: `radarPresets.v1`; a preset writes the chip keys plus
  `radarWindStyle` and `radarBuoys`. "Set up for" still opens the radar
  with its own bundle (`Audience.RadarLayers`).
- Tests: `RadarPresetTests`.

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
  and knots, cloud layers, freezing level, boundary layer. From HRRR on
  Tower (17 levels, underground ones left out, cloud from humidity and
  the model's cloud water and ice) where the point is on its grid, else
  Open-Meteo (11 levels); `source` says which. Also `turbulence` (GTG,
  now, every 1,000 ft) and `icing` (CIP, now, every 500 ft: probability,
  severity 1 trace to 4 heavy, large drops), drawn on the first stop
  (`aloft.now.turbulence`, `aloft.now.icing`).
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
  Turb, Layer chips and a More menu ("Show every layer", "Clouds only").
  Whether the row is open is not remembered.
- Settings: `aloftLayers` "clouds,wind,temp,icing,turb" (Turb added
  2026-09-25; anyone who had changed the chips before keeps their set and
  turns Turb on themselves).

### aloft.now.turbulence and aloft.now.icing
- Seen: on the scrubber's first stop only, a thin strip on the clouds
  column's right edge where GTG has light turbulence or worse, with
  "moderate turbulence" (light, moderate, severe) at the top of each run;
  a strip on its left edge where CIP has light icing or worse, with
  "light icing" (light, moderate, heavy) and ", large drops" when
  supercooled large drops are even odds. The strip deepens with the
  category. On that stop the cloud bands drop their "icing" guess; later
  hours keep it.
- Lives: `AloftView.swift` (the strips); `AloftMath.swift` ›
  `AloftHazards`, `HazardRun`.
- Data: `/aloft.turbulence`, `/aloft.icing` (served when a run under 90
  minutes old is held).
- Rules: AWC's categories for a medium aircraft (0.15, 0.22, 0.34 EDR);
  trace icing is left out; neither product forecasts, so later hours show
  nothing from them.
- Tests: `AloftHazardTests`; backend `test_turbulence_and_icing_now_come_with_the_column`.
- For: P S.

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
- Since 2026-09-30 the phone also pushes each new report: every snapshot
  it saves (`SnapshotStore.onSave`, set at launch) goes to the watch as
  `sync.snapshot` when its station, altimeter, pressure or front differ
  from the last one sent, through the complication channel while Barry is
  on the watch face and the day's budget lasts (about 50), which wakes the
  complication at once, otherwise queued for the watch app's next run. The
  watch saves it unless it holds a newer snapshot for the same station,
  keeps its own sensor reading, and reloads the complication
  (`PhoneSync.take`). A pilot's face showed the last hour's number until
  the app was opened.

### watch.page.main
- Seen: station title with a gear, the trend glyph coloured by class and
  intensity, the headline pressure, "altimeter ·" or "sensor ·" then the
  3 h change, the 6 h chart, the verdict, "METAR N min ago". An "altimeter
  here X est." line in Backcountry mode off an airport.
- Lives: `WatchApp/WatchContentView.swift` › `loaded`.
- Data: `/combined?station=&tz=` (no coordinates; `/front` is phone only).
- Rules: the headline is the station's altimeter setting whenever it
  reports one, wherever the wearer is (since 2026-09-30: a glance at the
  wrist sets the altimeter while the AWOS cycles); otherwise the
  calibrated sensor with an orange dot, otherwise sea-level pressure. The
  complications show the same number (`TendencySnapshot.altimeterLeads`);
  the phone's widgets keep the airport rule. The sensor counts only if calibrated (or
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
  its next look at :08 past the hour or +20 min, whichever is sooner
  (`nextRefresh`: routine METARs reach the server by about :05); refreshes
  in the background when 15 min old; without a snapshot
  waits 5 s then retries in 2 min. Stale after 2 h. Never blocks on the
  network, because a slow fetch leaves the slot grey for good.
- Tests: `SnapshotStalenessTests`, `TendencyParityTests`, `ComplicationRefreshTests`.

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
| `widget.taf.medium` | TAF, medium | the TAF sentence over the 24 h category strip; LAMP where no TAF is issued |
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
| `GET /combined` | `station`, `lat`, `lon`, `tz`, `clock` (12 or 24) | pressure (series, current, tendency), forecast, reading (trend, feature, confidence, explanation), conditions (with the rain line, `conditions.rain`, when the radar has rain here or on the way), runways, taf, lamp (LAMP guidance from this hour, when the site has it), lightningNearby, verdict | AWC METAR (Open-Meteo surface pressure as fallback), Open-Meteo forecast, AWC TAF, LAMP from NOMADS, OurAirports runways, GLM flashes, bulk METAR lightning | pressure 12 min per station; forecast 30 min per 0.1° cell; TAF 30 min | the phone and watch (`PressureStore`), complications, widgets, the airport check in Settings |
| `GET /pressure/{station}` | `hours` | pressure only | as above | one key per station, whole day | nobody now |
| `GET /forecast` | `lat`, `lon` | hourly, sun, `source` ("hrrr+nbm", "hrrr" or "open-meteo"), `stale`; on `/combined` also `pressureOffset` | the HRRR forecast feeds (48 h) with NBM over the first 36 h, sun times computed; Open-Meteo, 2 days, off the grid | NOAA: 30 min per 0.1° cell and run; Open-Meteo: 30 min per 0.1° cell, last good re-served 12 h when upstream fails | inside `/combined` |
| `GET /front` | `station`, `lat`, `lon` | status, headline, bearing, eta, nearestFront | bulk METAR history (7.5 h) or an AWC box, forecast, `/fronts` | 15 min per station and 0.1° | the phone's front banner only |
| `GET /fronts` | none | WPC analysis plus the progs, and `history`: the analyses of the nine hours before, oldest first | IEM AFOS (CODSUS, the last twelve products; CODSRP) | 30 min, one entry | the radar |
| `GET /radar/hrrr` | none | run time | IEM tile probe | 10 min | nobody (the model frames it served are Barry's own since 2026-10-02) |
| `GET /radar/model/{t}/{size}/{z}/{x}/{y}/{color}/{opts}.png` | the frame's key (valid time plus forecast hour), 256 or 512, zoom to 12 | an RGBA PNG in the radar's colours | the model radar store (`state/radarmodel`, HRRR REFC on a 0.03 degree grid) | a week, immutable; a miss is never cached | the radar's day span |
| `GET /radar/stack/{t0}/{step}/{n}/{size}/{z}/{x}/{y}.png` | up to 8 frames `step` (600 or 1200) seconds apart from `t0`; 256 or 512; zoom to 7 | one greyscale PNG, the frames' tiles stacked top to bottom, a byte a pixel: dBZ plus 32 where there is echo, zero where none (the code the app's palette is indexed by) | the radar store, rendered on the tile pool and kept in the tile cache | immutable, a week | the GPU loop: a loop's frames in one request a tile instead of one a frame |
| `GET /radar/field/series` | `lat`, `lon`, spans, `pad`, `levels` | the map's wind grid at each hour from seven back to the top of this one, and at now, oldest first, on the one lattice; with `levels` the altitude stops' winds too; an hour with no analysis held is left out | the HRRR analyses the store keeps: the map feed keeps its seven older cycles as hour 0 and the wind fields alone (`FeedSpec.history`, about 90 MB an hour), so the history fills over the first six hours after a start | 5 min | the wind on the radar's clock (`radar.layer.wind`) |
| `GET /metars/series` | `lat`, `lon`, `half` | each station's reports over the last six hours and a half: time, wind, gust, category; nearest first, the map's 350 at most | the bulk snapshots, which since 2026-10-02 keep wind and category beside the pressure | none; the snapshots are 25 min apart | the stations on the radar's clock (`radar.layer.stations`) |
| `GET /lightning/series` | `lat`, `lon`, `half` | six hours of GLM flashes once believed, a frame every ten minutes (the twenty minutes before each mark, binned to 0.02° cells, ages from the mark) | the flash store's history (`flashes.HISTORY_S`), kept in memory only since the last start | 1 min | the lightning on the radar's clock (`radar.layer.lightning`) |
| `GET /radar/motion` | `span` (hour or day), `lat`, `lon`, spans | how the rain moved between each pair of frames the span's loop plays: east and north speeds in degrees per hour on a lattice of blocks about 50 km across (`lat0`, `lon0` the north-west block's centre, rows going south), for the region and half a span past each edge; a pair not found is left out (about 2 KB a pair) | the block matching the nowcast is built on (`radar.motion`), found at each poll for every pair either loop plays and kept; twenty-minute pairs on the copy pooled once more | none; a pair never changes | the radar loop gliding (`radar.layer.radar`) |
| `GET /radar/pressure/series` | `lat`, `lon`, spans | per hour from seven back to twelve ahead, and now: unix time, `kind` (observed, now or model) and the field's grid to a hundredth of a hectopascal, every frame on one lattice (about 260 KB before compression at 20 frames); `stepHPa`, the spacing to contour at; the model `run` | the station snapshots and the HRRR forecast feed's MSLP, no upstream | 5 min; quantized like `/radar/pressure`; a past hour's grid is kept as long as its snapshot | the radar's isobars away from now |
| `GET /metars` | `lat`, `lon`, `half`, `buoys` | stations with wind, category, visibility, ceiling, altimeter, lightning, raw; with `buoys=1` also NDBC buoys and coastal stations (`kind` "buoy", waves, water temperature, pressure and its 3 h change) | bulk table (AWC box fallback); NDBC `latest_obs.txt` | 2 min; centre 0.2°, half 0.5°; 350 stations plus up to 120 buoys nearest first; NDBC once per 10 min for everyone, failures remembered 60 s and never block the stations | the radar station layer |
| `GET /advisories` | `lat`, `lon`, `half` | SIGMET and G-AIRMET areas (kind, hazard, label, base and top, valid times, outline, bulletin) and PIREPs of turbulence and icing (position, time, altitude, aircraft, intensities, raw) that touch the box | AWC `airsigmet`, `gairmet` (current hour), `pirep` (lower 48, 2 h) | each feed 10 min for everyone, failures 60 s; a failed feed is left out | the radar Advisories layer |
| `GET /radar/pressure` | `lat`, `lon`, spans | isobars, isallobars, grids, extrema | bulk table and history, no upstream | 5 min; centre 0.1°, spans 0.5°; two builds at a time | the radar pressure layers |
| `GET /lightning` | `lat`, `lon`, `half` | 0.02° cells, clusters, window 1200 s, coverage | GLM store | 60 s; centre 0.2°, half 0.5° | the radar lightning layer |
| `GET /radar/frames` | `source` (mrms or rainviewer, optional), `span` (hour or day, optional) | host, frames each with `time`, `path`, `nowcast` and `kind` (observed, nowcast, model), `lightningNext`. No `span`: 7 observed and 3 nowcast, what builds to 93 expect. `hour`: every ten minutes of the last two hours, then the nowcast to as far as its score allows (30 to 60 minutes). `day`: a frame every twenty minutes from six hours back, the newest, then each hour to twelve ahead (nowcast where it reaches, else model). Nowcast and model paths name the run that made them | Barry's MRMS frames and the model radar store, else RainViewer (7 and 3 whatever the span) | RainViewer's list 2 min; Barry's read from the store | the radar |
| `GET /radar/lightning/{t}/{size}/{z}/{x}/{y}.png` | the grid's unix time, 256 or 512, zoom to 12 | an RGBA PNG, violet by the chance of lightning in the next hour | MRMS LightningProbabilityNext60min, the newest three held | as the radar tiles | the Lightning layer |
| `GET /radar/tiles/{t}/{size}/{z}/{x}/{y}/{color}/{opts}.png` | the frame's unix time, 256 or 512, zoom to 12 | an RGBA PNG in Universal Blue, empty tiles about 1 KB | the MRMS store: uint8 dBZ on the 0.01 degree grid and four max-pooled copies for wide views | `public, max-age=604800, immutable` (Cloudflare keeps them); misses `no-store`; 64 MB in process; own budget, 1,500 a minute per client (`BARRY_TILE_RATE_PER_MIN`) | the radar |
| `GET /aloft` | `lat`, `lon` | 25 hourly columns, `source`, `stale`, and what is there now: `turbulence` (GTG) and `icing` (CIP) | the HRRR column feeds; Open-Meteo pressure levels off the grid | HRRR: 1 h per 0.1° cell and column run; Open-Meteo: 1 h per 0.1° cell, last good 12 h; the hazards are read fresh each request | Aloft |
| `GET /radar/field` | `lat`, `lon`, spans, `pad` (0 to 0.75 of the span, optional) | wind, boundary layer and CAPE, and `source`. From HRRR: 88 points inside the view, or with `pad` every point of the shared lattice out to that far past each edge (about 300 at 0.5, 30 KB). From Open-Meteo: 35 inside the view, `pad` or not | the HRRR store; Open-Meteo multi-point (35 weighted calls) off the HRRR grid or before a cycle is held | HRRR: none needed; Open-Meteo: until five past the next hour, at least 10 min; centre 0.05°, spans 0.5°; last good copy for 6 h | the radar wind layer |
| `GET /radar/field/levels` | same | the same points at five levels, underground levels left out, and `source` | as `/radar/field` | as `/radar/field` | the altitude rail |
| `GET /radar/heights` | `lat`, `lon`, spans, `hPa` (925, 850, 700, 600, 500) | height contours in metres, 30 m apart at 700 hPa and below and 60 m above, with the run and valid time | the HRRR store only; 503 off its grid | until five past the next hour, per level, region and run | the altitude rail |
| `GET /models/scores` | `days` (1 to 60, default 14) | `days`: per UTC day, newest first, hours scored and for HRRR and RRFS (the same cycle, the same lead) the mean sea-level pressure error (raw, bias, and with each hour's bias taken out), 10 m wind speed error in knots, direction error where the wind is 8 kt or more, and the lead; `rainStarts`: the "rain starts at" calls scored, hits, hit rate, calls pending, and the same by day; `nowcast`: per lead (10 to 60 minutes) the radar nowcast's CSI at 20 dBZ against the frame that arrived, persistence's beside it, frames checked, the same by day, and `shownMin`, how far the timeline is listing it now | none: the model store and the bulk METAR table, scored once an hour (`modelscore.py`), kept 60 days in `state/model_scores`; the rain calls in `state/rain_calls`; the nowcast's counts by UTC hour in `state/nowcast_scores` | none | Jordan, for the RRFS switch and the rain line |
| `GET /fallbacks` | `days` (1 to 60, default 14) | per UTC day, newest first: answers served by a fallback instead of the NOAA feeds, by kind (forecast, aloft, field, levels, radar, pressure) and reason (`off-grid`: outside the HRRR domain, expected; `no-data`: nothing held for it; `stale`: radar frames held but old; `off`: switched off in the configuration; `upstream`: AWC failed); then the newest 40 events with where (a station or a point to a tenth of a degree) | none: `fallbacks.py`, one event per kind, reason and place every ten minutes, kept 60 days in `state/fallbacks`, written by the scheduler once a cycle; every occurrence counts on `/metrics` as `barry_fallbacks_total` | none | Jordan, for taking the fallbacks out |
| `GET /stations/search` | `q`, `limit` | id and name matches, METAR stations only | AWC directory | directory 24 h | Settings, onboarding |
| `GET /glance` | `stations` (comma list, up to 8), `tz`, `clock` | one line per field: category, wind, altimeter, sea-level pressure, 3 h change and class, the verdict without forecast, observation time | the same cached reports as `/combined` (saved fields are watched stations) | none of its own; a field that cannot be read is left out | the Fields card |
| `GET /route` | `from`, `to`, `speedKt` (40 to 400, default 100), `tz`, `clock` | distance, time, arrival time, both ends' glance lines, corridor stations (along and off the line, category, wind), the worst of them, nearest lightning near the line, fronts crossing it, the destination's category at arrival and where it came from (`arriveSource` taf or lamp), TEMPO at arrival, minutes from sunset | none: the bulk table, the flash store, `/fronts`, the ends' cached reports, TAF and LAMP | 5 min per pair and speed | the Route card and screen |
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
  20 minutes kept. After each poll the credible flashes are worked out
  against the newest radar frame within 15 minutes of each flash (about
  80 ms for 25,000 flashes); the rest are counted on `/metrics` as
  `barry_glm_flashes_dropped`. `BARRY_GLM=0` disables.
- Model loop every 300 s: when the newest HRRR cycle (expected 58 min
  after its hour) is not held, the analysis and the next two hours of the
  fields in `sources/hrrr.py` by byte range from AWS, or whole files from
  NOMADS when the bucket is 10 minutes late and NOMADS has it. Winds turned
  earth-relative, fields written to `state/model/hrrr/<cycle>/` as float32,
  two cycles kept (about 1 GB). A cycle takes 5 s and peaks near 700 MB.
  `BARRY_HRRR=0` disables and every map layer stays on Open-Meteo.
- Radar loop every 120 s: lists the MRMS composite on the bucket, fetches
  the file nearest each mark that isn't held (1.2 MB, 0.2 s to decode;
  newest first): every ten minutes of the last two hours and, since
  2026-10-02, every twenty of the last six: 25 frames and the six nowcast
  ones, about a gigabyte with the pooled copies under `state/radar`. Then the nowcast for a new newest frame
  (motion by block matching on the 0.04 degree copy, 0.3 s, averaged with
  the step before's; six frames advected, under a second each; the motion
  is kept for the rain line), then every lead scored against the new
  frame (`_score_nowcast`: the frames 10 to 60 minutes back carried
  forward on the 0.04 degree copy, hits, misses and false alarms at 20
  dBZ, persistence beside them, summed by UTC hour and kept 60 days in
  `state/nowcast_scores`),
  the newest lightning probability grid (30 KB) under `state/ltgnext`,
  and the newest rain-rate grid (PrecipRate, a megabyte, held in memory
  only). Then the "rain starts at" calls old enough to check are scored
  against the frames within 15 minutes of their predicted start (a hit
  is 20 dBZ within two points), kept 60 days in `state/rain_calls`.
  Degraded when the newest frame is 20 minutes old; `BARRY_MRMS=0` stops
  it.
- The model loop also pulls `hrrr-refc`: composite reflectivity for f01
  to f16 of every cycle at full resolution (half a megabyte a field on
  the bucket, one run kept, 59 MB; the frames made from it 51 MB). Each hour not yet past is read
  onto a 0.03 degree grid as the radar's own dBZ codes
  (`modelradar.py`, 0.1 s a field) and kept in `state/radarmodel` under
  its valid time plus its forecast hour, the newest two runs' worth, an
  hour past dropped. It is a `FeedSpec` like the rest, so the RRFS switch
  is the same change as for them.
- The model loop also pulls the Aloft column feeds: `hrrr-col2` (f00 to
  f03 of every cycle) and `hrrr-colx2` (f00 to f30 of the 00, 06, 12 and
  18 UTC cycles), 17 levels of height, temperature (stored in Celsius),
  humidity, wind, cloud water and ice plus the surface, every other point
  in float16. One run of each is kept (3.5 GB for the day-long one); a
  day-long run takes about 4 minutes on Tower. Each run's files are opened
  as soon as it lands, and after a restart, so the first column read is
  quick. Then GTG turbulence (every 15 minutes) and CIP icing (hourly)
  from NOMADS, one whole file each, newest run only.
- And the point forecast: `hrrr-fc3` (f00 to f18 of every cycle, three
  runs kept for the model scores) and `hrrr-fcx3` (f00 to f48 of the long
  cycles), 15 surface fields each hour stored point-major, pressures less
  1,000 hPa so half precision keeps tenths; then NBM
  every third hour (f01 to f36: temperature, dew point, wind, direction,
  gust, sky, and the hourly chance of rain and of thunder). On `/combined`
  the NOAA pressure curve is shifted to meet the station's latest reading
  (`pressureOffset`; HRRR reduces to sea level its own way, and Open-Meteo
  at KLUK serves the same HRRR numbers without the shift).
- And RRFS beside HRRR (`sources/rrfs.py`): sea-level pressure and 10 m
  wind for hours 1 to 3 of every cycle (about 80 minutes after each; the
  00 and 12 UTC ones two hours; some hourly cycles are missing before the
  operational date and are walked past), served to nobody. Each pass then
  scores the hour nearest the newest METARs, and fills in the hour before,
  at every station reporting within 15 minutes of it: RRFS from the newest
  cycle that reaches the hour, HRRR from the same cycle at the same lead
  (`modelscore.py`, `/models/scores`), so the two are compared like for
  like.
- LAMP loop every 300 s: when a new hourly run (HH:30, looked for eight
  minutes after) is not held, one 4.4 MB bulletin from NOMADS for every
  site, parsed in a thread (2,313 stations, 0.4 s). On a cold start a run
  not landed yet falls back an hour. Guidance over six hours old is not
  served. `BARRY_LAMP=0` disables. Every NOMADS request goes through
  `sources/nomads.py`, 10 s apart (`BARRY_NOMADS_SPACING`).
- Unhealthy (503, autoheal restarts): a loop exited or stalled (refresh
  1800 s, lightning 600 s, LAMP and model 3600 s). Degraded (200, or 503
  with `strict`): the lightning feed or the bulk table is stale, or no LAMP
  run or HRRR cycle for three hours.
- Every answer a fallback gives instead of the NOAA feeds (Open-Meteo for
  the forecast, the Aloft column, the radar's wind grid and winds aloft;
  RainViewer for the radar timeline; Open-Meteo's surface pressure when
  AWC fails) is logged with why and where (`fallbacks.py`, `/fallbacks`),
  so the month before the fallback code comes out is measured.
- Tests: `backend/tests`, 381 tests; `test_property` reads the app's own
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
| `route.from`, `route.to` | "" | the route's two IDs; empty means no route | the hero menu, a Fields line, the planner, the Route card |
| `route.recent` | "" | comma list of `FROM>TO`, newest first, five kept | RouteSettings |
| `cruiseSpeedKt` | 100 | 60 to 200 in 20s; timing for the route | Settings › Cards and screens |
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
| `radarIsobarLabels` | true | | radar More sheet |
| `radarStations` | off | off, barbs, speeds | radar |
| `radarStationStyleLast` | barbs | style restored when the chip turns on | radar More sheet |
| `radarAdvisories` | false | SIGMETs, G-AIRMETs and PIREPs on the radar | radar chip |
| `radarBuoys` | false | buoys and coastal stations in the station layer | radar Map options, the water preset in "Set up for", a saved preset |
| `radarPresets.v1` | none | JSON list of saved radar presets: a name and every chip's state, the wind style and buoys | radar Map options |
| `radarStorms` | true | Lightning chip | radar |
| `radarAutoplay` | true | play the last hour, or hold on the latest | Settings › Radar |
| `aloftCeilingFt` | 18000 | 6000, 12000, 18000, 24000; also caps the radar rail | Settings › Aloft, the Aloft menu |
| `aloftLayers` | clouds,wind,temp,icing,turb | adds layer | Aloft chips |
| `savedLocations.v1` | My location | JSON list | Settings, onboarding |
| `savedLocations.selected.v1` | first entry | UUID | Settings, the hero menu |
| `homeStation` | unset, then the snapshot's, then KLUK | also the watch sync key | onboarding, PressureStore |
| `barometer.calibration.v2`, `barometer.history.v2`, `barometer.refAltitude.v1` | none | the phone barometer's model, 48 h history, altitude datum | BarometerManager |
| `watch.barometer.calibration.v1`, `watch.barometer.refAltitude.v1` | none | the watch barometer | WatchBarometer |
| `watchBarometerEnabled` | false | watch Settings switch; overwritten by the phone sync | watch, PhoneSync |
| `tendency.snapshot.v1` | none | the complication and lock widget snapshot | SnapshotStore |
| `airportSelected`, `selectionPhysical` | false | watch sync keys, not phone settings | PhoneSync |
| `sync.watchSensor.lastFromPhone` | unset | the last "use watch sensor" value the phone sent; the watch applies a new value only when it changes | PhoneSync |
| `sync.snapshot` | none | not a setting: the key the phone's pushed complication snapshot travels under in a WatchConnectivity user-info payload | WatchSync, PhoneSync |
| `locationMode`, `placeLabel`, `placeLat`, `placeLon` | legacy | read once for migration | |

Not a key: `combined.json` in the App Group container holds the last
`/combined` payload for the widgets and the cold start.

## Clock times

The verdict and the reading's summary (`/combined`, `/glance`, `/route`)
are written on the server, with the hour in the phone's zone (`tz`) and
clock (`clock=24` gives "16:00", otherwise "4 PM"; `verdict.py`
`_fmt_local_hour`, half an hour rounds up). Every other time is formatted
on the phone: `.formatted(date: .omitted, time: .shortened)` for times
with minutes, and `ClockText.hour` ("4 PM" or "16:00") for an hour in a
sentence, the quiet-hours labels, the onboarding sample and the tide
sentence. Chart axes keep the bare hour. Placeholders the server leaves
for the phone: `{eta}` (storm), `{end}` (rain). Until 2026-09-26 the
server always wrote "4 PM", beside cards that followed a 24-hour phone.

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

- `home.verdict.trackRecord`: built and hidden until the score is defined
  against what Barry claims (see ROADMAP D6).
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
- 2026-09-24, later: the Fields card, the advisories layer and the route
  (card, screen, planner, `/route`) from docs/ROUTES.md. LAMP from NOMADS
  behind the TAF card and the route's arrival (NOAA.md phase 1a). HRRR
  on Tower behind the radar's wind grid, the rail's winds and new height
  contours (phase 2).
- 2026-09-25: the rest of the NOAA switch: the Aloft column from HRRR with
  GTG turbulence and CIP icing, the point forecast from HRRR and NBM, radar
  tiles from MRMS with a nowcast and the chance of lightning, RRFS scored
  beside HRRR; Map options presets.
- 2026-09-25, later: the rain line on the Conditions card from the radar's
  rain rate and motion, scored against the frames that follow; the model
  scores compare HRRR and RRFS from the same cycle at the same lead, with
  RRFS from every hourly cycle; the blank first radar run traced to
  Cloudflare's rate rule answering tile bursts with 429 pages the app
  cached as tiles, and the map made to treat those as misses. Every
  fallback answer logged at `/fallbacks`.
