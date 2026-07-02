"""aviationweather.gov (AWC) METAR client — observed pressure + presTend.

Constraints baked in here (brief §2.1, §7):
  - keyless JSON, max 100 req/min per IP -> we batch many station ids per call
  - 15-day retention only
  - a descriptive custom User-Agent is REQUIRED or requests may be rejected
  - locations are airport/station based, not exact GPS

Units note: the decoded `presTend` from AWC is the 3-hour pressure tendency. We
treat it as hPa per the brief. METAR remark tendencies are reported in tenths of
hPa at the source; the AWC decoded field is already scaled. If you ever see
tendencies an order of magnitude too large, that scaling assumption is the first
thing to check.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Dict, List, Optional, Sequence

import httpx

from ..models import CurrentObs, SeriesPoint
from ..tendency import resolve_tendency

BASE_URL = "https://aviationweather.gov/api/data/metar"
USER_AGENT = "Barry/1.0 (jrdn@wvr.me)"


def _epoch_to_dt(epoch: Optional[float]) -> Optional[datetime]:
    if epoch is None:
        return None
    return datetime.fromtimestamp(float(epoch), tz=timezone.utc)


# AWC reports wind in knots; the API contract (and Open-Meteo) use km/h.
KT_TO_KMH = 1.852


def _wind_kmh(value) -> Optional[float]:
    """Knots → km/h; tolerates missing/non-numeric values."""
    try:
        return round(float(value) * KT_TO_KMH, 1)
    except (TypeError, ValueError):
        return None


def _wind_dir(value) -> Optional[float]:
    """Degrees as float; AWC uses the string "VRB" for variable wind → None."""
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def parse_records(records: Sequence[dict]) -> Dict[str, dict]:
    """Group raw METAR records by station id into a normalized intermediate form.

    Returns { station_id: { name, lat, lon, series: [...], current, presTend } }.
    `series` is sorted oldest -> newest; `current` is the newest observation.
    """
    by_station: Dict[str, List[dict]] = {}
    for rec in records:
        sid = rec.get("icaoId") or rec.get("station_id") or rec.get("id")
        if not sid:
            continue
        by_station.setdefault(sid.upper(), []).append(rec)

    out: Dict[str, dict] = {}
    for sid, recs in by_station.items():
        points = []
        for r in recs:
            t = _epoch_to_dt(r.get("obsTime"))
            if t is None:
                continue
            points.append(
                {
                    "t": t,
                    "slp": r.get("slp"),
                    "altim": r.get("altim"),
                    "presTend": r.get("presTend"),
                    "name": r.get("name"),
                    "lat": r.get("lat"),
                    "lon": r.get("lon"),
                    "wspd": r.get("wspd"),
                    "wdir": r.get("wdir"),
                    "wgst": r.get("wgst"),
                }
            )
        if not points:
            continue
        points.sort(key=lambda p: p["t"])
        newest = points[-1]
        out[sid] = {
            "name": newest.get("name"),
            "lat": newest.get("lat"),
            "lon": newest.get("lon"),
            "series": [
                SeriesPoint(t=p["t"], slp=p["slp"], altim=p["altim"]) for p in points
            ],
            # Wind from the newest METAR — a real measurement, so the client can
            # prefer it over the model forecast for "now" (METAR-first policy).
            "current": CurrentObs(
                slp=newest.get("slp"),
                presTend=newest.get("presTend"),
                windspeed=_wind_kmh(newest.get("wspd")),
                winddir=_wind_dir(newest.get("wdir")),
                windgust=_wind_kmh(newest.get("wgst")),
            ),
            "presTend": newest.get("presTend"),
            "_raw_points": points,
        }
    return out


async def fetch_metars(
    ids: Sequence[str],
    client: httpx.AsyncClient,
    *,
    hours: int = 24,
) -> Dict[str, dict]:
    """Fetch + parse METARs for one or many stations in a single batched call."""
    if not ids:
        return {}
    params = {
        "ids": ",".join(s.upper() for s in ids),
        "format": "json",
        "hours": str(hours),
    }
    resp = await client.get(
        BASE_URL,
        params=params,
        headers={"User-Agent": USER_AGENT},
        timeout=15.0,
    )
    resp.raise_for_status()
    data = resp.json()
    if not isinstance(data, list):
        data = []
    return parse_records(data)


def build_tendency(parsed: dict):
    """Resolve the tendency for one parsed station (prefer presTend, else series)."""
    points = parsed.get("_raw_points", [])
    times = [p["t"] for p in points]
    # tendency works off SLP; fall back to altimeter when SLP is missing
    values = [
        p["slp"] if p["slp"] is not None else p["altim"] for p in points
    ]
    return resolve_tendency(parsed.get("presTend"), times, values)
