# Barry — project context

A barometric **pressure-tendency** app for Apple Watch + iPhone, with a small
caching backend. The signal that weather is coming is the *rate of change* of
pressure, not the absolute value. Barry shows the −24h observed / +24h forecast
pressure curve and turns the 3-hour tendency into a plain-language verdict and an
at-a-glance watch complication.

- **Platforms:** iOS 17+ (SwiftUI + Swift Charts), watchOS 10+ (SwiftUI +
  WidgetKit complication), backend in Python (FastAPI).
- **Bundle IDs:** `com.wide-stack.barry`, `.watchkitapp`, `.watchkitapp.complication`.
  App Group: `group.com.wide-stack.barry`.
- **Backend prod host (when deployed):** `https://barry.wide-stack.com`. Local dev
  default: `http://127.0.0.1:8077`.

## Repo layout

```
barry/
├── backend/                 # FastAPI caching proxy (Python 3.10+, done + tested)
│   ├── app/
│   │   ├── main.py          # routes: /combined, /pressure/{station}, /forecast, /stations/nearest, /healthz
│   │   ├── service.py       # orchestration: sources + cache + graceful degradation
│   │   ├── scheduler.py     # periodic BATCHED metar refresh of active stations
│   │   ├── cache.py         # in-process TTL cache + active-station registry
│   │   ├── tendency.py      # 3h tendency classification + intensity  (DOMAIN SRC OF TRUTH)
│   │   ├── verdict.py       # plain-language verdict
│   │   ├── models.py        # normalized response schemas (the client contract)
│   │   ├── stations.py      # small ICAO station table + nearest() resolver
│   │   └── sources/aviationweather.py, openmeteo.py
│   ├── tests/               # pytest, upstreams mocked (36 tests)
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

## Status

Backend: done, tested, live-verified. iOS/watch/complication: built and compiling
(`xcodebuild ** BUILD SUCCEEDED **`). Not yet: cloud deploy (artifacts ready in
`backend/DEPLOY.md`), push notifications on `falling_fast`, multiple saved stations,
iOS `CMAltimeter` live-pressure dot.
