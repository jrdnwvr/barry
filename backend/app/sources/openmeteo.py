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

from ..models import ForecastHour

BASE_URL = "https://api.open-meteo.com/v1/forecast"
USER_AGENT = "Barry/1.0 (jrdn@wvr.me)"

HOURLY_FIELDS = [
    "pressure_msl",
    "surface_pressure",
    "windspeed_10m",
    "winddirection_10m",
    "precipitation_probability",
]


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
    pprob = hourly.get("precipitation_probability") or []

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
                precip_prob=at(pprob, i),
            )
        )
    return out


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
