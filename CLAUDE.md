# Barry — project context

A barometric **pressure-tendency** app for Apple Watch + iPhone, with a small
caching backend. The signal that weather is coming is the *rate of change* of
pressure, not the absolute value. Barry shows the −24h observed / +48h forecast
pressure curve and turns the 3-hour tendency into a plain-language verdict and an
at-a-glance watch complication.

- **Platforms:** iOS 17+ (SwiftUI + Swift Charts), watchOS 10+ (SwiftUI +
  WidgetKit complication), backend in Python (FastAPI). Briefly raised to
  18/11 on 2026-09-21 and reverted: a Pilots tester's iPhone is on 17.0.3 and
  is the most active one. On-screen detection uses GeometryReader instead of
  iOS 18's `onScrollVisibilityChange`.
- **Bundle IDs:** `me.wvr.barry`, `.widget` (phone widgets), `.watchkitapp`,
  `.watchkitapp.BarryWidget` (complications).
  App Group: `group.me.wvr.barry`.
- **Backend prod host (when deployed):** `https://barry.wide-stack.com`. Local dev
  default: `http://127.0.0.1:8077`.

## Repo layout

```
barry/
├── backend/                 # FastAPI caching proxy (Python 3.10+, done + tested)
│   ├── app/
│   │   ├── main.py          # routes: /combined, /pressure/{station}, /forecast, /front,
│   │   │                    #         /radar/hrrr, /stations/nearest, /healthz
│   │   ├── service.py       # orchestration: sources + cache + graceful degradation
│   │   ├── scheduler.py     # periodic BATCHED metar refresh of active stations
│   │   ├── cache.py         # in-process TTL cache + active-station registry
│   │   ├── tendency.py      # 3h tendency classification + intensity  (DOMAIN SRC OF TRUTH)
│   │   ├── verdict.py       # plain-language verdict
│   │   ├── models.py        # normalized response schemas (the client contract)
│   │   ├── stations.py      # small ICAO station table + nearest() resolver
│   │   └── sources/aviationweather.py, openmeteo.py
│   ├── tests/               # pytest, upstreams mocked (94 tests)
│   ├── backtest/            # front-watch validation harness (IEM archive replay;
│   │                        #   RESULTS.md = the evidence behind front.py's constants)
│   ├── Dockerfile, fly.toml, DEPLOY.md
│   └── pyproject.toml       # venv at backend/.venv
└── ios/
    ├── project.yml          # XcodeGen spec -> generates Barry.xcodeproj
    └── Barry/
        ├── Shared/          # Models, BarryAPI, Tendency (mirrors backend), PressureUnit,
        │                    #   PressureStore, LocationManager, SharedSnapshot, AppConfig
        ├── iOSApp/          # BarryApp, ContentView, PressureChartView (hero curve),
        │                    #   VerdictHeaderView, ConfirmationOverlayView, ForecastCaveatView, SettingsView
        ├── WatchApp/        # BarryWatchApp, WatchContentView (condensed glyph/value/delta/verdict + sparkline)
        └── WatchComplication/  # BarryComplication (widget), TendencyProvider, ComplicationViews
```

## Data architecture

Two keyless sources, each covering half the curve, behind a caching proxy so the
app can be distributed without tripping per-IP rate limits.

- **Observed + `presTend`** — aviationweather.gov METAR JSON. Has the trustworthy
  station-reported 3-hour tendency. Limit: 100 req/min per IP, 15-day retention,
  requires a descriptive `User-Agent` (`Barry/1.0 (jrdn@wvr.me)`), airport-based.
- **Forecast + wind/precip** — Open-Meteo, true point forecasts, generous limits.
  Also the graceful-degradation source (`surface_pressure`) if AWC fails.
- **Backend** batches all *actively watched* stations into one comma-separated AWC
  call every ~10 min and serves from a TTL cache, so cost scales with stations
  watched (~M), not users (N). Clients call the backend only — never AWC directly.

## Domain logic — tendency (the important part)

Given a signed 3-hour delta `d` (hPa, negative = falling). This table is the single
source of truth; it is mirrored in **`backend/app/tendency.py`** and
**`ios/Barry/Shared/Tendency.swift`** — keep them in sync by hand.

| Condition          | class          | color        |
|--------------------|----------------|--------------|
| d ≥ +1.5           | `rising_fast`  | green        |
| +0.5 ≤ d < +1.5    | `rising`       | light green  |
| −0.5 < d < +0.5    | `steady`       | gray         |
| −1.5 < d ≤ −0.5    | `falling`      | pale amber   |
| −3.0 < d ≤ −1.5    | `falling_mod`  | amber        |
| d ≤ −3.0           | `falling_fast` | deep red     |

**Intensity** (0–1, for the complication's color depth) maps `|d|` from 1.5→4.0 hPa
onto 0→1, clamped. (Note: the original brief's example JSON implied `|d|/4.0`
instead; we chose the banded mapping. Flip `INTENSITY_FLOOR` to `0.0` to switch.)

Prefer the station-reported `presTend`; otherwise compute `d` from the time series.

## API contract

- `GET /combined?station=KLUK&lat=39.1&lon=-84.5` — **primary**. Returns
  `{ pressure, forecast, verdict }`: the full −24/+24 picture in one call.
- `GET /pressure/{station}?hours=24`, `GET /forecast?lat=&lon=`,
  `GET /stations/nearest?lat=&lon=`, `GET /healthz`.

The Swift `Codable` models in `Shared/Models.swift` match this exactly (note the
JSON key `class` ↔ Swift `cls`).

## Run locally

```bash
# Terminal 1 — backend (default port the apps expect)
cd ~/barry/backend && .venv/bin/uvicorn app.main:app --port 8077

# Terminal 2 — apps
cd ~/barry/ios && xcodegen generate && open Barry.xcodeproj
```

Schemes: **Barry** (iOS), **BarryWatch** (watchOS), **BarryComplication**. In the
iOS Simulator, `127.0.0.1` reaches the Mac, so the local backend just works. On a
physical device, set `BarryBackendURL` (in the two Info.plists) to the Mac's LAN IP.

```bash
cd ~/barry/backend && .venv/bin/pytest -q     # run backend tests (36, no network)
```

## Conventions & gotchas

- **Backend runs ONE worker/instance** — the cache, registry, and scheduler are
  in-process. Scaling out needs Redis first (see `cache.py`).
- **Tendency thresholds live in two files** (Python + Swift) by design — change both.
- **Metal toolchain is a separate download** under Xcode 27:
  `xcodebuild -downloadComponent MetalToolchain` (~840 MB). Without it
  `WindFlow.metal` fails to compile and the whole app build fails.
- **Xcode project is generated** by XcodeGen from `ios/project.yml`; it's gitignored.
  After editing `project.yml` or adding/renaming source files, re-run `xcodegen generate`.
- **Set your signing Team** per target in Signing & Capabilities (free Apple ID is
  fine for the simulator). If the App Group can't be provisioned, the apps still
  run; only the complication's cached snapshot stays empty (handled gracefully).
- **watchOS complication refresh** is budget-limited (~20 min) — not live by design.
- Forecast pressure is smoothed; it's rendered dashed with a caveat note, because
  real fronts arrive sharper than the model shows.

## Status (2026-08)

Backend deployed (Unraid + Cloudflare Tunnel, `https://barry.wide-stack.com`);
deploy = `cd /mnt/user/appdata/barry && git pull && cd backend && docker compose
up -d --build`. Shipped and live: phone barometer calibration engine, storm
alerts (local notifications), saved locations, onboarding, iPad kneeboard
dashboard (3-column in landscape), radar (RainViewer + wind arrows + boundary
layer top), drag-select range analysis, and the **front watch** (`/front`,
regional isallobaric analysis — constants validated in `backend/backtest/`
across five climates plus a held-out year; direction = centroid track with
coherent-gradient fallback; NEVER wire front statuses to notifications).

Also live (2026-09): **fronts on the radar** — `/fronts` parses WPC's coded
bulletins (CODSUS analysis + CODSRP 12/24/36/48 h progs, via IEM AFOS) into
typed polylines; `FrontsOverlay.swift` draws the classic chart (pips on the
left-of-travel side = direction of motion, verified) at the ANALYSIS time only.
The 12/24 h progs still come down and the morph code is still there, but the
map no longer carries a clock of its own: two independent times on one map read
as tomorrow's front being today's. Wind is a particle-flow layer by default (`WindFlowView.swift`, Flow/Arrows
picker); arrows scale with speed from ~3 kt. `/front` also names the nearest
WPC-analyzed front (`nearestFront`: type, distance, bearing, and motion/ETA
from WPC's 12 h prog) — enrichment only, the backtested status logic is untouched.
The radar is its own pushed screen (`RadarScreen`; map full-bleed, floating
bottom card, collapsible Layers panel) and has a **station layer**: the
backend holds AWC's bulk METAR cache (`metars.cache.csv.gz`, every station,
refreshed every 10 min by the scheduler) and `/metars?lat&lon&half=3` slices
a box out of it in milliseconds with grid thinning to ~350 (no per-user AWC
call; the old bbox query is only the fallback). `StationLayer.swift` draws
METAR wind barbs or speed labels (Off/Barbs/Speeds, `@AppStorage("radarStations")`); tapping a
station opens `StationDetailSheet` (decoded report + raw METAR). **Crosswind
readout**: `backend/app/runways.py` serves OurAirports runways (TRUE headings;
rebuild with `tools/build_runways.py`) on `/combined.runways`, and
`RunwayWindsView.swift` projects the METAR wind onto each runway end.
`/privacy` and `/support` are the App Store URLs (app/static/).

Radar layers (2026-09-21) all stack: Radar is a chip like the rest, the
shading pair (`RadarField`: Pressure or Change, one at a time, lighter when
the radar is under it; Change also carries its isallobars and H/L), then
Isobars (`radarIsobars`, its own line layer so the contours can sit on plain
radar or beside a trough), Wind / Fronts / Troughs (WPC trough lines on their
own chip) / Stations / Lightning; `RadarKeySheet` lists only what is on. The
`radarIsobarsSplit` flag migrates anyone who had Pressure on to keep lines. Radar tiles are read back
to dBZ and repainted (`RadarPalette`); clusters of GLM flashes get a violet
outline. Radar tile pop-in on a pan is held down four ways (2026-09-21): parked
frames drop to alpha 0 while the map moves (MapKit stops fetching for them)
and return to 0.02 once it settles; both tile caches are sized in bytes
(48 MB repainted, 24 MB source) rather than a count that one screen of seven
frames overflowed; `URLCache.shared` is 200 MB on disk because RainViewer
sends a two-day max-age; and `prefetchRing` warms one ring of tiles around
the viewport for the current frame after each region change. The wind
streaks (`WindFlowView` + `WindFlow.metal`) simulate on the CPU but render
in Metal: every trail segment becomes a quad in one buffer,
one draw call. Measured on the full-screen radar in the simulator, that took
the app from 46% CPU to 21%. Boundary-layer top lives on the main page (density altitude
card) now, not the map. **Lightning** (`backend/app/lightning.py`) is decoded
from the METARs themselves (TS/VCTS + LTG remarks): `StationObs.lightning`,
`CurrentObs.lightning`, `/combined.lightningNearby` (nearest fresh report
within 100 mi with motion relative to the user), `ConditionsOut.storm`
(model weather_code/CAPE + TAF). Absent lightning means "nothing reported",
never "no lightning". **Strike positions** come from NOAA's GOES lightning
mapper (`backend/app/sources/glm.py`, public S3, anonymous, polled per
minute by the scheduler; `flashes.py` holds 20 min; `/lightning` slices
0.02° bins; `LightningOverlay.swift` draws them). Fixed server cost, zero
per user; `BARRY_GLM=0` disables the poll.

Parked, fully built: **forecast radar** (HRRR via Iowa Mesonet, +6 h model
frames) behind `RadarModel.modelFramesEnabled = false` — flip one Bool to ship;
while false the app makes zero IEM / `/radar/hrrr` requests.

**docs/PRODUCTION.md (2026-09-21)** is the hardening plan: an independent
review of everything since build 86 plus the backend, what was fixed the same
day, and the ranked open items (backend fan-out and registry validation are the
first two). Read it before any security or robustness work.

**docs/NOAA.md (2026-09-24)** is the plan for replacing Open-Meteo and
RainViewer with NOAA feeds processed on Tower (HRRR, NBM, MRMS by byte range
from AWS Open Data; RRFS lands 2026-10-14 on the HRRR grid), in seven phases
starting with a bridge (Open-Meteo's own server container on Tower). The
bucket layouts, latencies, field sizes and decode timings in it were measured;
read it before touching any weather source. NOMADS is the fallback
mirror for those, and the only home of LAMP, GTG turbulence and CIP icing
(phase 1a). Tower's line has no data cap. Open-Meteo's public API is
non-commercial only and RainViewer's is personal use only, which is the
reason for the plan.

Live since 2026-09-25 (phases 1a to 6, and 7 started): the scheduler's
model loop pulls HRRR (map, column and forecast feeds), NBM, GTG, CIP and
RRFS into `state/model` (`modelstore.py`, `sources/hrrr.py`, `nbm.py`,
`hazards.py`, `rrfs.py`; decoding and the Lambert grid in `grib.py`), and
serves the radar wind grid, the rail's winds and height contours, the
Aloft column with turbulence and icing, and the point forecast from it
(`modelfields.py`), Open-Meteo only off the HRRR grid. The radar loop pulls
MRMS into `state/radar` and serves Barry's own tiles in RainViewer's URL
shape and colours (`radar.py`), with a nowcast and NOAA's chance of
lightning; RainViewer only when those frames are stale
(`BARRY_RADAR_SOURCE`). LAMP comes from NOMADS (`sources/lamp.py`,
`nomads.py`, 10 s between requests). Forecast pressure is stored less
1,000 hPa in half precision, and on `/combined` the curve is shifted to
meet the station's latest report. `/models/scores` scores HRRR and RRFS
against the METARs hourly for the switch. Container memory limit 3 GB.
On Tower the state volume is mounted from `/mnt/cache/...` directly
(`BARRY_STATE_DIR` in `backend/.env`): through `/mnt/user` the FUSE layer
stalled model reads for seconds while a run was written. Feeds whose
storage format changes get a new name and the old one goes in
`hrrr.RETIRED`, dropped on start.

**docs/FEATURES.md (2026-09-24)** is the feature registry: every user-facing
feature with a stable slug, where it lives, what data and settings it uses,
its tests, and the defects found on the day. A change that adds, removes or
changes a feature updates it in the same commit; `python3
tools/check_features.py` fails when a settings key or route is missing.
**docs/REVIEW.md** holds the dated ten-thousand-foot reviews (structure,
audiences, customisation, the hand-made look, direction, fix-first list).
Read both before planning new work. The app must look and read as made by
a hobbyist: no caption under every control, no pill on every line, white
space over labels.

Not yet: courtesy emails to RainViewer + IEM before public App Store, App
Store listing copy, verdict track record (built, hidden until rescored),
real strike positions (GOES GLM would be the source), APNs push.

## Aloft (added 2026-09-22)

The clouds-and-winds-aloft column: `GET /aloft?lat&lon` serves 25 hourly
columns of Open-Meteo pressure levels (1000 to 400 hPa) in feet and knots
with derived cloud layers (runs of cover from 30 percent, icing between 0
and -20 C), the freezing level and the boundary layer, cached per
tenth-degree cell for an hour. On iOS, `AloftScreen` (iOSApp/AloftView.swift)
draws it on a compressed scale (the bottom 6,000 ft get 52 percent of the
height; `AloftMath.swift` holds the pure parts and their tests), with the
METAR's ceiling drawn separately from the model's layers, a ceiling menu
(6k/12k/18k/24k, also in Settings), layer chips and an hourly scrubber.
It opens from the conditions card's Clouds row and its last row. The
design handoff it follows came from the user's Design canvas.

## Wind at altitude (added 2026-09-24)

The full-screen radar has an altitude rail on the right while Wind is on:
SFC, 2.5k, 5k, 10k, 14k, 18k (capped by the Aloft ceiling setting). Off
the surface, the app asks `/radar/field/levels` once per region for the
map grid's wind at 925/850/700/600/500 hPa (ten variables, so Open-Meteo
counts it as one call per point) and redraws the streaks from it; moving
between stops needs no new request. `WindAltitude` in RadarModel holds the
stops and each one's streak ramp (35 km/h at the surface up to 130 at
18k). Other layers stay at the surface and the note under the timeline
says so. The level is not remembered between opens.

## Tests and checks (added 2026-09-22)

- Backend: `cd backend && .venv/bin/pytest -q` (304 tests; Hypothesis
  property tests read the app's own OpenAPI document). CI runs the suite,
  pip-audit, the image build and trivy on every push touching `backend/`.
  `tools/loadtest.py` against a local uvicorn started with
  `BARRY_RATE_PER_MIN=0` checks `/healthz` stays quick while grids build.
- iOS: `cd ios && xcodebuild test -scheme Barry -destination 'platform=iOS
  Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO` runs BarryTests
  (unit; fixtures come from `backend/tests/fixtures/`, wired in
  project.yml) and BarryUITests (the radar walk; launches with `-uitest`,
  which `UITestSupport.prepare()` turns into a known state). Give the UI
  test a specific simulator: `-destination 'platform=iOS Simulator,id=<udid>'`.
  The name "iPhone 17 Pro" matches one device per installed runtime, and the
  iOS 27 beta one hung the run for twenty minutes without a line of output. The tendency
  table is checked on both sides against `tendency_cases.json`;
  regenerate it with `backend/tools/gen_tendency_fixture.py` after
  changing `tendency.py`, then mirror the change in `Tendency.swift`.
- Production: `sh deploy.sh` on Tower (image tagged by commit, health
  waited on, three tags kept), `sh rollback.sh <tag>`. `/healthz` can be
  `degraded` (upstream quiet, 200) or `unhealthy` (a loop died, 503,
  autoheal restarts). `/metrics` answers on the box only. Logs are JSON
  lines with a request id; there is no per-request log. Runbook in
  `docs/RUNBOOK.md`, plan and status in `docs/PRODUCTION.md`, test
  inventory in `docs/TESTING.md`.
