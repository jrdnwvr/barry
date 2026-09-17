# Barry — project context

A barometric **pressure-tendency** app for Apple Watch + iPhone, with a small
caching backend. The signal that weather is coming is the *rate of change* of
pressure, not the absolute value. Barry shows the −24h observed / +24h forecast
pressure curve and turns the 3-hour tendency into a plain-language verdict and an
at-a-glance watch complication.

- **Platforms:** iOS 17+ (SwiftUI + Swift Charts), watchOS 10+ (SwiftUI +
  WidgetKit complication), backend in Python (FastAPI).
- **Bundle IDs:** `me.wvr.barry`, `.watchkitapp`, `.watchkitapp.complication`.
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
left-of-travel side = direction of motion, verified) and morphs between valid
times. Wind is a particle-flow layer by default (`WindFlowView.swift`, Flow/Arrows
picker); arrows scale with speed from ~3 kt. `/front` also names the nearest
WPC-analyzed front (`nearestFront`: type, distance, bearing, and motion/ETA
from WPC's 12 h prog) — enrichment only, the backtested status logic is untouched.
The radar is its own pushed screen (`RadarScreen`; map full-bleed, floating
bottom card, collapsible Layers panel) and has a **station layer**: the
backend holds AWC's bulk METAR cache (`metars.cache.csv.gz`, every station,
refreshed every 5 min by the scheduler) and `/metars?lat&lon&half=3` slices
a box out of it in milliseconds with grid thinning to ~350 (no per-user AWC
call; the old bbox query is only the fallback). `StationLayer.swift` draws
METAR wind barbs or speed labels (Off/Barbs/Speeds, `@AppStorage("radarStations")`); tapping a
station opens `StationDetailSheet` (decoded report + raw METAR). **Crosswind
readout**: `backend/app/runways.py` serves OurAirports runways (TRUE headings;
rebuild with `tools/build_runways.py`) on `/combined.runways`, and
`RunwayWindsView.swift` projects the METAR wind onto each runway end.
`/privacy` and `/support` are the App Store URLs (app/static/).

Radar layers (2026-09-16) are two-tier: one BASE (`RadarBase`: Radar,
Pressure = isobars + shading, Change = isallobars + shading) plus overlays
Wind / Fronts / Stations / Storms on a chip bar; `RadarKeySheet` lists only
what is on. Boundary-layer top lives on the main page (density altitude
card) now, not the map. **Lightning** (`backend/app/lightning.py`) is decoded
from the METARs themselves (TS/VCTS + LTG remarks): `StationObs.lightning`,
`CurrentObs.lightning`, `/combined.lightningNearby` (nearest fresh report
within 100 mi with motion relative to the user), `ConditionsOut.storm`
(model weather_code/CAPE + TAF). No new data source. Absent lightning means
"nothing reported", never "no lightning".

Parked, fully built: **forecast radar** (HRRR via Iowa Mesonet, +6 h model
frames) behind `RadarModel.modelFramesEnabled = false` — flip one Bool to ship;
while false the app makes zero IEM / `/radar/hrrr` requests.

Not yet: courtesy emails to RainViewer + IEM before public App Store, App
Store listing copy, verdict track record (built, hidden until rescored),
real strike positions (GOES GLM would be the source), APNs push.
