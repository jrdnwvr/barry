# What Barry has to keep doing

Written 2026-09-21. This is the inventory of behaviour a change can break,
with how each one is checked today and what would check it better. It exists
so that "I ran it and it looked fine" has a list to run against.

Three columns of meaning: **Automated** is a test in the repo. **Sim** is a
scripted or eyeballed check in the simulator. **Phone** is something only a
real device can show. An empty cell means nothing checks it.

## Backend (FastAPI, 294 tests, all through a mock transport unless noted; CI runs them on every push)

| Behaviour | Automated | Notes |
|---|---|---|
| `/combined` returns pressure, forecast, verdict for a valid station | yes | |
| Tendency classification matches the table in CLAUDE.md | yes, Python side | no parity test with Swift yet |
| Degraded answer when AWC is down, short TTL, replaced when back | yes | |
| Station registry: only answering stations, capped, persisted, restored | yes | |
| Scheduler batches watched stations, survives a bad batch or record | yes | a bad record drops one station |
| Bulk METAR table sliced by box, thinned to a ceiling | yes | |
| Pressure and change fields: contours, grids, extrema, feathering is client side | yes | |
| Fronts: WPC bulletin parse, analysis frame only | yes | |
| GLM lightning: poll, slice, clusters, nearest with motion | yes | clocks frozen on both sides |
| TAF parse and timeline | yes | |
| Runways from OurAirports, true headings | yes | |
| Station validation at every route, 422 on junk | yes, through the app | |
| Every numeric parameter bounded; inf, nan, denormals; error body shapes | yes, through the app | |
| One cached day per station regardless of hours | yes, counts upstream calls | |
| Forecast keyed and fetched per tenth-degree cell | yes, checks the URL | |
| Per-upstream budgets fail fast without calling | yes | |
| Per-address request budget, health check exempt | yes, through the app | |
| Docs and schema not served | yes | |
| Error bodies carry no upstream detail | yes | |
| Persistence round-trips datetimes, migrates pickle once | yes | |
| Pressure grid off the event loop, one build per key, two at a time | yes | single-flight and negative caching tested on the cache |
| Every route from its own schema: never a 500, bounded upstream calls and body | yes, Hypothesis | found a remembered failure answering 500 |
| Sweeps of coordinates, box sizes and spans stay bounded in cache entries | yes | |
| Health check p95 under 200 ms while grids build | tools/loadtest.py | run before a deploy that touches the grid |
| Diagnostics drop box: JSON only, 1 MB, gated, pruned | yes, through the app | |
| Counters at /metrics answer the box only; every response carries a request id | yes, through the app | |
| Health check: 503 when a loop dies or stalls, degraded when upstream is silent | yes, through the app | strict form for an outside monitor |
| Container runs as nobody, hashed install, pinned tunnel | deploy smoke | `docker exec id`, `docker inspect` |

## iOS app (54 unit tests and one UI test; `xcodebuild test -scheme Barry`)

Cards, in the order the home screen shows them by default.

| Behaviour | Automated | Sim | Phone | Notes |
|---|---|---|---|---|
| METAR strip: station, category, raw wind, vis, ceiling | | eyeball | | |
| Hero: pressure in the chosen unit, 3 h delta, verdict | | eyeball | | unit switch hPa/inHg |
| Tendency class and intensity agree with the backend | yes, shared fixture | | | tendency_cases.json, generated from tendency.py |
| Verdict copy for each tendency class | yes, Python side | | | the app shows the server's sentence |
| Lightning row: nearest, motion, count within 100 mi | | eyeball | | |
| Pressure chart 6 h / 48 h, forecast dashed, drag to read | | eyeball | | |
| TAF card: sentence, strip, sunset and sunrise marks | yes, timeline from a real KLUK TAF; renders at three widths | eyeball | | found the start hour rounding forward |
| Rain and wind row | | eyeball | | |
| Conditions: density altitude, clouds, boundary layer, fog | | eyeball | | |
| Backcountry strip card off field, altimeter estimate | | eyeball | | |
| Runway winds dial and sentence | yes, components, order, sentences | | | |
| Radar card animates only while on screen | | measured | | CPU 0.1% off screen |
| Sensor card on device only | | | yes | needs a barometer |
| Sources card | | eyeball | | |
| Home screen editor: reorder, hide, presets, TAF off by default | | eyeball | | |
| Live Activity: opt in, events, banner | | | yes | permission prompt |
| Onboarding first run | | eyeball | | |
| Saved locations switcher | | eyeball | | |
| Cold start shows the saved reading marked "saved", refreshes behind it | | eyeball | | 12 s interactive timeout, patient session for silent refreshes |
| MetricKit reports reach /diagnostics | | | yes | needs a day on a device |

Radar screen, each layer alone and stacked.

| Behaviour | Automated | Sim | Phone | Notes |
|---|---|---|---|---|
| Radar tiles repainted to Barry's palette; Now parks on the latest frame, the loop plays the last hour, a scrub pauses where it lands | palette tested; UI test taps Now, scrubs, loops | eyeball | | frame time under the slider |
| Pressure shading, Change shading, one at a time | | eyeball | | |
| Isobars alone over plain radar, labels in hPa | | eyeball | | |
| Wind streaks: direction, tone by speed, visible at 3 kt | | eyeball | | |
| Streaks stay on the ground through a pan, no blanking | | eyeball | yes | |
| Fronts at the analysis, pips on the leading side | | eyeball | | |
| Troughs on their own chip | | eyeball | | |
| Stations: barbs or speeds, cover the visible map, tap for detail | | eyeball | | |
| Lightning cells with violet outlines | | eyeball | | |
| Key sheet lists only what is on | | eyeball | | |
| Zoom out to a continent: field covers the view, no rectangle | | eyeball | | was the 422 bug |
| Pan then pan back: tiles from cache, ring prefetched | | | yes | pop-in is a feel |
| Layer migration: Pressure users keep isobars | | done once | | |
| Recentre button, full screen push and pop | | eyeball | | |
| Every layer toggled, a pan, a zoom out and in, back to the dashboard, wind still on | UI test (BarryUITests) | | | launches with -uitest: onboarded, KLUK, layers off |

Widgets and watch.

| Behaviour | Automated | Sim | Phone | Notes |
|---|---|---|---|---|
| TAF widget medium, lock screen rectangular and inline | | eyeball | | self-fetch in sim |
| Field glance small and medium, temp and dew labelled | | | | not looked at since the label |
| Trend widget with curve and lightning line | | eyeball | | |
| Runway winds widget | | eyeball | | |
| Staleness past two hours: "as of", grey | yes, clock-driven on the snapshot | | | |
| Watch page: same pressure as the phone, 6 h chart | | eyeball | | |
| Complications answer from cache at once | | eyeball | yes | could not verify on a face |
| Watch barometer with steadiness gate | | | yes | |
| Phone to watch sync of station and toggles | | | yes | |

## What was built (2026-09-22)

1. Done: tendency_cases.json, generated from the Python table, read by both suites.
2. Done: RunwayMath, TafTimeline, the palette, snapshot staleness; the cards render at three widths.
3. Done: BarryUITests walks the radar. It runs against the live backend.
4. Done: staleness is clock-driven on the snapshot.
5. Done: the health check can fail, and the deploy script waits on it.

Not automated: anything marked phone, and the eyeballs. Snapshot images
were not adopted: nobody has reviewed a reference on a device yet, so the
render tests only prove the cards draw.

Everything marked eyeball above was looked at in the simulator this week.
Everything marked phone has not been seen on a device since build 86.
