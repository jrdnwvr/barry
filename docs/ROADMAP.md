# Barry improvement proposal (2026-09-15)

Findings from an audit of the app, watch, widget, and backend, turned into
work items we can knock out one at a time. Each item says what it fixes
(debt or pilot utility), rough size, and what it depends on. Sizes: S = under
half a day, M = a day, L = two to three days.

Suggested order: A1, A2, A3, E1, E2, B1, B2, C1, C2, D1, D2, then the rest.
The first six clear the debt so everything after lands on clean ground.

---

## A. Data flow: one source, one fetch

The rule in CLAUDE.md is "clients never talk to upstreams". The audit found
four places that still do, plus two backend calls that are now redundant
with the bulk METAR table.

**A1. Proxy the radar's Open-Meteo wind grid and boundary-layer grid.** (S) DONE 2026-09-15, commit 1c2484b: `/radar/field`, one call for both layers.
`RadarModel.fetchWind` and `fetchBoundaryLayer` call api.open-meteo.com
directly from the phone for every map pan (one multi-point request each).
Every user pays it; nothing is shared. Move both behind `/wind-grid` and
`/bl-grid` (region cell as the cache key, 10 min TTL) so the server makes
one call per region per ten minutes for everyone. Also removes the phone's
last dependence on Open-Meteo's URL format.

**A2. Proxy RainViewer's frame list.** (S) DONE 2026-09-15: `/radar/frames`, 2 min TTL.
`RadarModel.load` fetches `weather-maps.json` from RainViewer on every
radar open. Serve it from `/radar/frames` with a 5 min TTL: one upstream
call per five minutes total, and the app gets a clean model (frames + host)
instead of parsing RainViewer's shape. Tiles keep coming from their CDN
directly, which is what they want.

**A3. Nearest station from the bulk table.** (S) DONE 2026-09-15, commit 292c363.
`nearest_reporting_station` still issues a bbox METAR query (hours=3,
widened once). The in-memory bulk table already has every station's
position and pressure; pick the closest with an SLP or altimeter. Zero
upstream calls, and the ten-airport table in `stations.py` becomes
unnecessary (keep it only for offline unit tests, or delete).

**A4. Front watch ring from the bulk table (needs validation).** (M, then a
backtest run) DONE 2026-09-15 differently: the ring series come from a 9.5 h history of bulk snapshots with the validated math untouched (no re-validation needed); bbox only during the 7.5 h cold start, and the history is persisted (E6) so deploys don't restart it.
`/front` makes the single priciest AWC call left: an 8 hour bbox pull per
station every 15 minutes, to compute each ring station's 3 h delta from its
series. The bulk file carries AWC's own `three_hr_pressure_tendency_mb`
per station, and keeping the previous two snapshots in memory gives the
"ring as of 4 hours ago" the track rule needs. Caveat: the v1.2 constants
were tuned on deltas computed from series, not reported tendencies. Do
this only with a backtest that swaps the input and confirms the hit rate
holds. If it does, `/front` costs nothing upstream.

**A5. Station names.** (S) DONE 2026-09-15: AWC station directory, daily; names on /metars, nearest, and search.
The bulk file has no station names, so the tap sheet shows a bare id
outside the home station. AWC publishes `stations.cache.json.gz` (ids,
names, elevations). Load it once a day; it also enables a real station
search (D5).

**A6. Delete the dead Swift interpreter.** (S) DONE 2026-09-15: `Reading` moved to Models.swift, the rest removed.
`Shared/Interpreter.swift` (401 lines) mirrors the backend interpreter and
nothing calls it. Delete it. `Tendency.swift` stays (the complication needs
the color table offline).

## B. The pressure graph and selection

Today: tap reads one point; a sideways drag paints a range and a card
appears under the chart. The drag is precise but fiddly, the card pushes
the layout, and the two features you most want to inspect (the feature pin
and the front-edge marker) can't be selected directly.

**B1. Select events, not pixels.** (M) DONE 2026-09-15: chips (Around the <feature>, Last 3 h, Since midnight, Next 6 h) + tap on the feature pin.
Make the chart's markers tappable selections: tap the "trough" or "front
edge" pin and the window around that feature (feature time minus 3 h to
plus 3 h, clipped to data) is selected and analyzed. Add three preset chips
under the chart: Last 3 h, Since midnight, Next 6 h. Freehand drag stays
for the curious, but most reads become one tap.

**B2. Selection handles and snapping.** (M) DONE 2026-09-15 (half-hour snap, edge-handle drags, live re-analysis, haptics); handle drag awaits a hands-on check since the simulator gesture tool died mid-verification.
Once a range exists, draw draggable handles on its edges (Screen Time
style) so you adjust a window instead of redrawing it. Snap edges to the
nearest half hour. Haptic tick on snap. Long-press anywhere starts a new
range (so the scroll view never fights you, even on iOS 17).

**B3. The analysis as a floating card, not a layout shift.** (S) DONE 2026-09-15.
Present the range result as a card anchored to the chart (overlay, with a
close X) rather than inserting it into the scroll stack, so the chart
doesn't jump when it appears.

**B4. Show what the reading is made of.** (S) DONE 2026-09-15: trailing 3 h fit + scatter band when steadiness < 0.8 (caveats were already under the verdict).
The interpreter already returns `steadiness`, `confidence`, and `caveats`.
The chart shows none of them. A thin confidence band around the observed
curve (wider when steadiness is low) and a caveat line under the verdict
("short window", "gap in reports") make the honesty visible instead of
buried in JSON.

**B5. One analysis engine, on the server.** (M) Depends on C1.
`RangeAnalysis.swift` is a third copy of the de-tide and phase logic
(backend interpreter, unused Swift interpreter, and this). Replace it with
`/analyze?station&from&to`, which can use everything the server has
(forecast, fronts, ring stations) and is unit-tested once. The app keeps a
tiny offline fallback ("net change over the window") for when the server
is unreachable.

## C. A more descriptive reading (server side)

Pressure stays the primary signal; everything else is corroboration and is
labeled as such. That keeps the feature's identity and makes the answer
more useful. None of this is against the spirit as long as the sentence
leads with the pressure and says "the model agrees" or "the model
disagrees" rather than replacing the barometer with the forecast.

**C1. Explain the change, not just the shape.** (M) DONE 2026-09-15: `explanation` block on the reading (supporting/conflicting, metar vs model), summary under the verdict; client now sends its real UTC offset.
Extend the interpreter's `Reading` with an `explanation` block: the
detected feature, the nearest WPC front and its ETA (already computed for
the banner), and the forecast's own view of the same hours (rain
probability, wind shift, gust onset, cloud base trend from Open-Meteo,
which we already pull). Output a structured list of "supporting" and
"conflicting" signals with times. Verdict copy becomes: "Sharp fall,
bottoming around 6 PM. WPC has a cold front 90 mi west moving this way;
the model shifts wind to 310 at 7 PM and puts rain at 5 PM." When the
model disagrees, say so: that's the most useful sentence a barometer app
can offer.

**C2. Wind shift and gust detection from METAR history.** (S) DONE 2026-09-15: series points carry wind/temp/vis/ceiling/category; `signals.py` detects shift, gust onset, temp drop, category change.
The METAR parser already sees per-report wind but only keeps pressure in
the series. Keep wind and temperature per point; then the interpreter can
detect a veer or back of more than 60 degrees in 2 h and a temperature
drop, which is how a front actually announces itself at a field. Feeds C1
and the front watch's "passed" call.

**C3. Confidence from agreement.** (S) DONE 2026-09-15: +0.1 per strong supporting signal (capped at 1), ×0.8 when the model stays calm against a fall, `model_disagrees` caveat named in the honesty note. The computed six-of-ten replacement waits on D6.
When the pressure feature, the WPC front motion, and the model forecast
all point at the same window, raise confidence; when they disagree, lower
it and name the disagreement. Replace the fixed "six of ten" copy with a
computed figure once D6 exists.

**C4. Tendency in the user's own terms.** (S) DONE 2026-09-15: per-hour rate with a front/storm comparison under the verdict when |rate| ≥ 1.5 hPa/3 h.
Offer the 3 h rate as "hPa per 3 h" or "inHg per hour" plus a plain
comparison ("as fast as a typical frontal passage") so a non-meteorologist
gets a sense of scale.

**C5. Serve the reading history.** (M)
Keep the last 48 h of readings per station on the server (cheap, in
memory, persisted to a small SQLite). Lets the chart show when the trend
class changed, and is the raw material for D6.

## D. Pilot utility from data we already have

**D1. Runway winds over the next hours.** (S) DONE 2026-09-15: 12 h outlook line (peak crosswind, when another end takes over).
The runway card uses the current METAR wind only. Open-Meteo hourly wind
and gusts are already in `/combined`. Add a small timeline: "Rwy 21L: 3 kt
crosswind now, peaks 12 kt around 3 PM, favors Rwy 25 after 5 PM." That
is the question a pilot planning a late departure actually has.

**D2. Watch the field's category, not just the pressure.** (S) DONE 2026-09-15: `CategoryStripView` under the station row with ceiling/visibility trend.
METAR history has visibility and ceiling per report. Show the last 6 h of
flight category as a strip under the METAR line (green/blue/red/magenta
blocks) and note the trend ("ceiling lowering 1,500 ft/h"). Costs nothing
upstream (C2 keeps the fields).

**D3. TAF alongside Barry.** (M) DONE 2026-09-15: `/combined.taf` (AWC decoded TAF, 30 min TTL per station), FM/BECMG rules and TEMPO/PROB bands on the chart, and TAF evidence in the explanation timed against the barometer's turn.
The one new upstream worth adding. AWC's TAF endpoint (same terms, same
cache style: `tafs.cache.csv.gz`) gives the forecaster's expected wind,
ceiling, and visibility by hour. Show the TAF's change groups on the
chart timeline as markers (FM, TEMPO, BECMG) and let C1 compare the
pressure signal against the TAF's timing. Pilots trust TAFs; Barry saying
"the TAF has this an hour later than the barometer does" is a strong hook.

**D4. Density altitude on the runway card.** (S) DONE 2026-09-15: callout when DA exceeds field by 1,500 ft.
DA is computed but lives in its own card; the runway card is where takeoff
decisions happen. Add "DA 2,500 ft, 5 kt tailwind on 3L" style callouts
when DA exceeds field elevation by more than 1,500 ft.

**D5. Station search anywhere.** (S) DONE 2026-09-15: Settings airport field searches /stations/search as you type.
With names loaded, the saved-locations picker can search any reporting
station worldwide by id or name, instead of relying on location or a
ten-airport table.

**D6. Verdict track record.** (M) Depends on C5.
For each reading, record what the pressure did over the following 6 h and
whether rain or a wind shift arrived. Show a small "Barry's last 30 days
here" line (right x of y times) on the honesty note. This replaces the
backtest's number with a live, local one, and tells us where the model
needs tuning.

**D7. Watch complication: front watch and category.** (S) DONE 2026-09-15: category dot + code on rectangular/inline, front arrow (rotated to the bearing) when approaching/passing; snapshot re-saved once /front answers.
The complication shows tendency only. Add the flight category color and
the front watch arrow when active. Data already flows through the shared
snapshot; it's a rendering change.

## E. Structural debt

**E1. Split RadarView.swift.** (S) DONE 2026-09-15: RadarModel.swift (278), RadarMapView.swift (481), RadarView.swift (514).
1,341 lines holding RadarModel, RadarMapView with its coordinator, and
RadarPanel. Three files, no behavior change. Do this before B and C touch
the radar again.

**E2. One card list for phone and iPad.** (S) DONE 2026-09-15: `glanceCards(_:layout:)`; embedded radar now recenters instead of rebuilding.
ContentView builds the phone stack and the iPad dashboard as two separate
lists; every new card (I did it twice today) is added in two places and
can drift. Extract a single `cards(for:)` builder both layouts consume.

**E3. Decide the HRRR forecast radar.** (S)
Fully built, parked behind `RadarModel.modelFramesEnabled = false`, with
backend routes and tests. Either enable it (IEM courtesy email first) or
delete the code path and its tests. Parked code is where bugs hide.

**E4. BarometerManager.swift (1,024 lines).** (M) DONE 2026-09-15: pure types moved to BarometerEngine.swift (347 lines); the manager is 687 lines of Core Motion glue.
The calibration engine, CoreMotion plumbing, and the comparison state live
in one class. Split the pure calibration math into a tested value type;
leave the manager as glue. Enables the sensor-vs-station math to be unit
tested without CoreMotion.

**E5. Run the iOS unit tests in Xcode Cloud.** (S)
`BarryTests` exists but isn't run anywhere (local runs have crashed this
Mac). Add a test action to the workflow so RangeAnalysis, Tendency, and
the models get exercised on every cloud build.

**E6. Backend: SQLite for the small durable things.** (M) Depends on C5. PARTLY DONE 2026-09-15: `persist.py` (atomic pickle in BARRY_DATA_DIR, compose volume ./state) holds the bulk history; reading history (C5) can use the same store.
The cache is in-process; a restart loses the bulk table, reading history,
and calibration state. A single SQLite file on the Unraid volume for
history and the last-good copies of each upstream (already done for
forecasts, ad hoc) makes deploys invisible to users.

## F. Efficiency check (current state, for the record)

- `/combined` and the scheduler share the pressure cache; no double fetch.
- `/metars` and nearest station: zero upstream calls per user (A3 done).
- `/front`: one 8 h bbox call per station per 15 min (A4 removes it).
- Radar wind and boundary layer: one backend call per region cell per 10 min (A1 done).
- RainViewer frame list: one backend call per 2 min total (A2 done).
- Fronts (WPC via IEM): one call per 30 min, global. Fine.
- Foreground polling: `/combined` and `/front` every 5 min while active;
  server TTLs (12 and 15 min) make most of those cache hits. Fine.
- Watch and widget read the phone's shared snapshot; no direct calls.
