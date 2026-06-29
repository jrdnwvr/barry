# Barry

A barometric **pressure-tendency** app for Apple Watch + iPhone. The signal that
weather is coming isn't absolute pressure — it's the *rate of change*. Barry
shows the −24h observed / +24h forecast pressure curve and turns the 3-hour
tendency into a plain-language "is weather coming?" verdict and an at-a-glance
watch complication.

See [the full project brief](#) for product and data-architecture details.

## Status

| Phase | Scope | State |
|-------|-------|-------|
| 1 | Backend core (sources, tendency, `/combined`) | ✅ done · tested · live-verified |
| 2 | Backend caching + scheduler + graceful fallback | ✅ done · tested |
| 3 | iOS app shell + networking + hero chart | ✅ scaffolded · builds |
| 4 | Watch app | ✅ scaffolded · builds |
| 5 | Complication (WidgetKit) | ✅ scaffolded · builds |
| 6 | Confirmation overlays + polish | ✅ scaffolded · builds |

The backend was built first because it defines the data contract both apps consume
and is fully testable without Xcode. The iOS/watch/complication targets compile and
link for the simulator (`xcodebuild ... ** BUILD SUCCEEDED **`); they still need a
signing team + App Group setup and on-device testing before distribution. See
[`ios/README.md`](ios/README.md).

## Backend

FastAPI caching proxy. Two upstreams: **aviationweather.gov** (observed pressure +
the trustworthy 3-hour `presTend`) and **Open-Meteo** (point forecast + wind/precip
overlays, and the graceful-degradation source when AWC is unavailable).

### Run

```bash
cd backend
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"
.venv/bin/uvicorn app.main:app --reload --port 8077
```

### Test

```bash
cd backend
.venv/bin/pytest -q          # 36 tests, upstreams mocked — no network needed
```

### Endpoints

| Endpoint | Purpose |
|----------|---------|
| `GET /combined?station=KLUK&lat=39.1&lon=-84.5` | **Primary.** Merged −24/+24 curve + tendency + verdict in one call. |
| `GET /pressure/{station}?hours=24` | Observed series + current + tendency (AWC, cached). |
| `GET /forecast?lat=..&lon=..` | Open-Meteo forecast (pressure/wind/precip), cached. |
| `GET /stations/nearest?lat=..&lon=..` | Location → nearest known station (client convenience). |
| `GET /healthz` | Liveness + scheduler stats. |

Example:

```bash
curl "http://127.0.0.1:8077/combined?station=KLUK&lat=39.1&lon=-84.5"
```

### How it stays under the rate limit

aviationweather.gov allows 100 req/min **per IP**, and a shared proxy collapses all
users onto one IP. So the backend never calls AWC per-request at scale:

- A **scheduler** (`app/scheduler.py`) refreshes only the stations users are
  actually watching, **batching all of them into one comma-separated call** every
  ~10 min. N users watching M stations cost ~M/cycle, not N.
- Responses are served from a **TTL cache** (~12 min pressure, ~30 min forecast).
- An **active-station registry** tracks stations requested in the last ~24h.
- A descriptive `User-Agent` (`Barry/1.0 (jrdn@wvr.me)`) is sent on
  every upstream request, as AWC requires.
- **Graceful degradation:** if AWC fails, the observed line is rebuilt from
  Open-Meteo `surface_pressure` so the app degrades rather than dies.

### Domain logic (the important part)

`app/tendency.py` is the single source of truth for the tendency thresholds
(brief §4.1) — classification bands plus a continuous 0–1 intensity used for the
complication's color depth. `app/verdict.py` maps class + forecast confirmation to
the one-line verdict (brief §4.2). The Swift apps will mirror these constants in
`Shared/`; keep the two in sync by hand.

> **Intensity note:** the brief's prose ("pale amber at −1.5 → deep red at −4+")
> and its example JSON (`delta3h −2.4 → intensity 0.6`) disagree on the mapping.
> The code follows the prose (band 1.5→4.0 hPa mapped to 0→1, so −2.4 → 0.36).
> Flip `INTENSITY_FLOOR` to `0.0` in `tendency.py` to match the example instead.

## Repository layout

```
barry/
├── backend/            # FastAPI caching proxy (done)
│   ├── app/
│   │   ├── main.py         # routes
│   │   ├── service.py      # cache + sources orchestration + degradation
│   │   ├── scheduler.py    # periodic batched METAR refresh
│   │   ├── cache.py        # TTL cache + active-station registry
│   │   ├── tendency.py     # 3h tendency classification + intensity
│   │   ├── verdict.py      # plain-language verdict
│   │   ├── models.py       # normalized response schemas (the contract)
│   │   ├── stations.py     # small station table + nearest resolver
│   │   └── sources/        # aviationweather.py, openmeteo.py
│   └── tests/
└── ios/                # Xcode project (not started — needs Xcode + Apple Dev acct)
```
