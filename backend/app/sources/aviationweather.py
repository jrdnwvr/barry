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


def _visibility_sm(value) -> Optional[float]:
    """AWC visibility in statute miles. Usually numeric, but "10+" is common."""
    if value is None:
        return None
    try:
        return float(str(value).rstrip("+"))
    except ValueError:
        return None


# Cloud covers that constitute a ceiling (aviation definition).
_CEILING_COVERS = {"BKN", "OVC", "OVX"}


def _ceiling(clouds) -> tuple[Optional[int], Optional[str]]:
    """(base_ft, cover) of the lowest broken/overcast layer. When there's no
    ceiling, falls back to the lowest reported layer (FEW/SCT with its base) or
    a bare sky-clear cover so the client can still render something honest."""
    if not isinstance(clouds, list) or not clouds:
        return None, None
    ceilings = [
        (c.get("base"), c.get("cover"))
        for c in clouds
        if c.get("cover") in _CEILING_COVERS and c.get("base") is not None
    ]
    if ceilings:
        base, cover = min(ceilings, key=lambda x: x[0])
        return int(base), cover
    lowest = min(
        (c for c in clouds if c.get("base") is not None),
        key=lambda c: c["base"],
        default=None,
    )
    if lowest is not None:
        return int(lowest["base"]), lowest.get("cover")
    # No bases at all — typically CLR/SKC/CAVOK.
    return None, clouds[0].get("cover")


def _flight_category(vis_sm: Optional[float], ceiling_ft: Optional[int]) -> Optional[str]:
    """Standard US flight-category rules, used only when AWC omits fltCat."""
    if vis_sm is None and ceiling_ft is None:
        return None
    vis = vis_sm if vis_sm is not None else 99.0
    ceil = ceiling_ft if ceiling_ft is not None else 99999
    if vis < 1 or ceil < 500:
        return "LIFR"
    if vis < 3 or ceil < 1000:
        return "IFR"
    if vis <= 5 or ceil <= 3000:
        return "MVFR"
    return "VFR"


def _current_obs(newest: dict) -> CurrentObs:
    vis = _visibility_sm(newest.get("visib"))
    ceiling_ft, ceiling_cover = _ceiling(newest.get("clouds"))
    return CurrentObs(
        slp=newest.get("slp"),
        presTend=newest.get("presTend"),
        windspeed=_wind_kmh(newest.get("wspd")),
        winddir=_wind_dir(newest.get("wdir")),
        windgust=_wind_kmh(newest.get("wgst")),
        visibilitySM=vis,
        ceilingFt=ceiling_ft,
        ceilingCover=ceiling_cover,
        fltCat=newest.get("fltCat") or _flight_category(vis, ceiling_ft),
    )


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
                    "visib": r.get("visib"),
                    "clouds": r.get("clouds"),
                    "fltCat": r.get("fltCat"),
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
            # Wind + aviation conditions from the newest METAR — real measurements,
            # so the client can prefer them over the model for "now" (METAR-first).
            "current": _current_obs(newest),
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
    # An unknown identifier gets an EMPTY BODY from AWC (not an empty JSON
    # list) — .json() would raise and mask "no data" as a fetch failure,
    # which broke the K-prefix retry in get_pressure.
    try:
        data = resp.json()
    except ValueError:
        data = []
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
