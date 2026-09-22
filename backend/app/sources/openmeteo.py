"""Open-Meteo client — point forecast pressure + wind/precip confirmation.

Distribution-grade source (brief §2.2): keyless, true lat/lon point forecasts,
generous limits. Provides the +24h dashed forecast line and the wind/precip
overlays, and doubles as the graceful-degradation source for the observed line
when AWC fails (via `surface_pressure`).
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import List, Optional

import httpx

from ..models import (AloftCloud, AloftHour, AloftLevel, AloftSurface, FieldPoint, ForecastHour,
                      SunTimes)

BASE_URL = "https://api.open-meteo.com/v1/forecast"
USER_AGENT = "Barry/1.0 (jrdn@wvr.me)"

HOURLY_FIELDS = [
    "pressure_msl",
    "surface_pressure",
    "windspeed_10m",
    "winddirection_10m",
    "wind_gusts_10m",
    "precipitation_probability",
    # Field-conditions inputs (density altitude + fog risk, conditions.py)
    "temperature_2m",
    "dew_point_2m",
    "cloud_cover",
    # Storm outlook + the boundary-layer card (same request, no extra call)
    "cape",
    "convective_inhibition",
    "weather_code",
    "boundary_layer_height",
    # Ride estimate (conditions.ride): sun, near-surface lapse, shear
    "shortwave_radiation",
    "temperature_80m",
    "temperature_180m",
    "wind_speed_80m",
]

# Sunrise/sunset bound the fog-risk night window and the burn-off estimate.
DAILY_FIELDS = ["sunrise", "sunset"]


def _parse_iso(t: str) -> datetime:
    # Open-Meteo returns naive ISO local-to-UTC strings when timezone=UTC;
    # we request UTC and stamp tzinfo explicitly.
    return datetime.fromisoformat(t).replace(tzinfo=timezone.utc)


def parse_forecast(data: dict) -> List[ForecastHour]:
    hourly = data.get("hourly") or {}
    times = hourly.get("time") or []
    pmsl = hourly.get("pressure_msl") or []
    wspd = hourly.get("windspeed_10m") or []
    wdir = hourly.get("winddirection_10m") or []
    wgst = hourly.get("wind_gusts_10m") or []
    pprob = hourly.get("precipitation_probability") or []
    temp = hourly.get("temperature_2m") or []
    dewp = hourly.get("dew_point_2m") or []
    cloud = hourly.get("cloud_cover") or []
    sp = hourly.get("surface_pressure") or []
    cape = hourly.get("cape") or []
    cin = hourly.get("convective_inhibition") or []
    wcode = hourly.get("weather_code") or []
    blh = hourly.get("boundary_layer_height") or []
    rad = hourly.get("shortwave_radiation") or []
    t80 = hourly.get("temperature_80m") or []
    t180 = hourly.get("temperature_180m") or []
    w80 = hourly.get("wind_speed_80m") or []

    def at(seq, i):
        return seq[i] if i < len(seq) else None

    out: List[ForecastHour] = []
    for i, t in enumerate(times):
        out.append(
            ForecastHour(
                t=_parse_iso(t),
                pressure_msl=at(pmsl, i),
                windspeed=at(wspd, i),
                winddir=at(wdir, i),
                windgust=at(wgst, i),
                precip_prob=at(pprob, i),
                temperature=at(temp, i),
                dewpoint=at(dewp, i),
                cloudcover=at(cloud, i),
                surface_pressure=at(sp, i),
                cape=at(cape, i),
                cin=at(cin, i),
                weather_code=at(wcode, i),
                boundary_layer=at(blh, i),
                radiation=at(rad, i),
                temp80m=at(t80, i),
                temp180m=at(t180, i),
                wind80m=at(w80, i),
            )
        )
    return out


def parse_daily_sun(data: dict) -> SunTimes:
    daily = data.get("daily") or {}
    return SunTimes(
        sunrise=[_parse_iso(t) for t in (daily.get("sunrise") or [])],
        sunset=[_parse_iso(t) for t in (daily.get("sunset") or [])],
    )


def parse_surface_pressure_series(data: dict):
    """For graceful degradation: (times, surface_pressure) for the recent past."""
    hourly = data.get("hourly") or {}
    times = [_parse_iso(t) for t in (hourly.get("time") or [])]
    sp = hourly.get("surface_pressure") or []
    return times, sp


async def fetch_forecast(
    lat: float,
    lon: float,
    client: httpx.AsyncClient,
    *,
    forecast_days: int = 2,
    past_days: int = 0,
) -> dict:
    """Fetch raw Open-Meteo JSON. Returns the decoded dict for flexible reuse.

    `past_days` is used by the degradation path to pull recent surface_pressure.
    """
    params = {
        "latitude": lat,
        "longitude": lon,
        "hourly": ",".join(HOURLY_FIELDS),
        "daily": ",".join(DAILY_FIELDS),
        "forecast_days": str(forecast_days),
        "timezone": "UTC",
    }
    if past_days:
        params["past_days"] = str(past_days)
    resp = await client.get(
        BASE_URL,
        params=params,
        headers={"User-Agent": USER_AGENT},
        timeout=15.0,
    )
    resp.raise_for_status()
    return resp.json()


# ---- Radar field grid (wind + boundary layer), many points in one call ----

def parse_field_grid(data, now: datetime) -> List[FieldPoint]:
    """Open-Meteo multi-location response -> FieldPoints. Boundary layer is
    hourly, so the current UTC hour is picked once and indexed per point."""
    items = data if isinstance(data, list) else [data]
    hour_key = now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H")
    out: List[FieldPoint] = []
    for it in items:
        cur = it.get("current") or {}
        spd, deg = cur.get("wind_speed_10m"), cur.get("wind_direction_10m")
        if spd is None or deg is None:
            continue
        bl = cape = None
        hourly = it.get("hourly") or {}
        times = hourly.get("time") or []
        vals = hourly.get("boundary_layer_height") or []
        capes = hourly.get("cape") or []
        for i, t in enumerate(times):
            if t.startswith(hour_key):
                bl = vals[i] if i < len(vals) else None
                cape = capes[i] if i < len(capes) else None
                break
        out.append(FieldPoint(lat=it["latitude"], lon=it["longitude"],
                              windKmh=float(spd), windDeg=float(deg), blM=bl,
                              capeJkg=cape))
    return out


async def fetch_field_grid(lats, lons, client: httpx.AsyncClient, *, now: datetime) -> List[FieldPoint]:
    """Current wind and today's boundary-layer heights at many points, one request."""
    params = {
        "latitude": ",".join(f"{v:.3f}" for v in lats),
        "longitude": ",".join(f"{v:.3f}" for v in lons),
        "current": "wind_speed_10m,wind_direction_10m",
        "hourly": "boundary_layer_height,cape",
        "forecast_days": "1",
        "timezone": "UTC",
    }
    r = await client.get(BASE_URL, params=params,
                         headers={"User-Agent": USER_AGENT}, timeout=15.0)
    r.raise_for_status()
    return parse_field_grid(r.json(), now)


# ---- Aloft: pressure levels at a point ----------------------------------

# Surface to about 24,000 ft. Fewer levels would hide the low-level detail
# the column exists to show; more would be model noise at this scale.
ALOFT_LEVELS = [1000, 975, 950, 925, 900, 850, 800, 700, 600, 500, 400]
ALOFT_VARS = ("temperature", "dew_point", "cloud_cover", "wind_speed", "wind_direction", "geopotential_height")
ALOFT_HOURLY = ([f"{v}_{p}hPa" for p in ALOFT_LEVELS for v in ALOFT_VARS]
                + ["freezing_level_height", "boundary_layer_height",
                   "temperature_2m", "dew_point_2m", "wind_speed_10m", "wind_direction_10m"])
CLOUD_LAYER_PCT = 30       # a level counts as cloud from scattered; the app shades dense from 70
ICING_MIN_C, ICING_MAX_C = -20.0, 0.0
FT_PER_M = 3.28084


async def fetch_aloft(lat: float, lon: float, client: httpx.AsyncClient, *, forecast_days: int = 2) -> dict:
    """Raw Open-Meteo JSON for the column: every level, two days, knots."""
    params = {
        "latitude": lat,
        "longitude": lon,
        "hourly": ",".join(ALOFT_HOURLY),
        "wind_speed_unit": "kn",
        "forecast_days": str(forecast_days),
        "timezone": "UTC",
    }
    resp = await client.get(BASE_URL, params=params, headers={"User-Agent": USER_AGENT}, timeout=15.0)
    resp.raise_for_status()
    return resp.json()


def cloud_layers(levels: List[AloftLevel]) -> List[AloftCloud]:
    """Consecutive levels at or above CLOUD_LAYER_PCT become one layer, base
    at the lowest such level and top at the highest, cover the run's
    maximum. A single cloudy level still gets a band: half the gap to the
    next level up, so it is visible without pretending to a depth."""
    out: List[AloftCloud] = []
    run: List[int] = []

    def close(run_idx: List[int]) -> None:
        if not run_idx:
            return
        lo, hi = run_idx[0], run_idx[-1]
        base = levels[lo].ft
        if hi + 1 < len(levels):
            top = levels[hi].ft if hi > lo else levels[hi].ft + (levels[hi + 1].ft - levels[hi].ft) // 2
        else:
            top = levels[hi].ft + 1000
        cover = max((levels[i].cloudPct or 0) for i in run_idx)
        icing = any(ICING_MIN_C <= levels[i].tempC <= ICING_MAX_C for i in run_idx)
        out.append(AloftCloud(baseFt=base, topFt=max(top, base + 200), coverPct=cover, icing=icing))

    for i, lv in enumerate(levels):
        if (lv.cloudPct or 0) >= CLOUD_LAYER_PCT:
            run.append(i)
        else:
            close(run)
            run = []
    close(run)
    return out


def parse_aloft(data: dict, *, now: datetime, hours: int = 25) -> List[AloftHour]:
    """Hourly columns from the current UTC hour forward. Levels whose height
    is missing are dropped; the rest are sorted by height so the runs that
    make cloud layers are contiguous in altitude."""
    hourly = data.get("hourly") or {}
    times = hourly.get("time") or []
    start_key = now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H")

    def col(name):
        return hourly.get(name) or []

    def at(seq, i):
        return seq[i] if i < len(seq) else None

    out: List[AloftHour] = []
    started = False
    for i, t in enumerate(times):
        if not started:
            if t.startswith(start_key):
                started = True
            else:
                continue
        if len(out) >= hours:
            break
        levels: List[AloftLevel] = []
        for p in ALOFT_LEVELS:
            h_m = at(col(f"geopotential_height_{p}hPa"), i)
            temp = at(col(f"temperature_{p}hPa"), i)
            if h_m is None or temp is None:
                continue
            cloud = at(col(f"cloud_cover_{p}hPa"), i)
            levels.append(AloftLevel(
                hPa=p, ft=int(round(h_m * FT_PER_M)), tempC=float(temp),
                dewC=at(col(f"dew_point_{p}hPa"), i),
                dirDeg=at(col(f"wind_direction_{p}hPa"), i),
                spdKt=at(col(f"wind_speed_{p}hPa"), i),
                cloudPct=int(round(cloud)) if cloud is not None else None,
            ))
        levels.sort(key=lambda lv: lv.ft)
        frz = at(col("freezing_level_height"), i)
        blh = at(col("boundary_layer_height"), i)
        out.append(AloftHour(
            t=_parse_iso(t), levels=levels, clouds=cloud_layers(levels),
            surface=AloftSurface(tempC=at(col("temperature_2m"), i), dewC=at(col("dew_point_2m"), i),
                                 dirDeg=at(col("wind_direction_10m"), i), spdKt=at(col("wind_speed_10m"), i)),
            freezingFt=int(round(frz * FT_PER_M)) if frz is not None else None,
            blAglFt=int(round(blh * FT_PER_M)) if blh is not None else None,
        ))
    return out
