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

import math
from datetime import datetime, timezone
from typing import Dict, List, Optional, Sequence

import httpx

from .. import lightning as ltg
from ..models import StationObs, CurrentObs, SeriesPoint, TafOut, TafPeriod
from ..tendency import resolve_tendency

BASE_URL = "https://aviationweather.gov/api/data/metar"
# Every station's latest METAR, one gzip'd CSV refreshed by AWC each minute.
# ~250 KB for the whole world; the courteous way to cover a big area.
CACHE_URL = "https://aviationweather.gov/data/cache/metars.cache.csv.gz"
# Station directory (names, elevation, what each site issues). ~350 KB, daily.
STATIONS_URL = "https://aviationweather.gov/data/cache/stations.cache.json.gz"
TAF_URL = "https://aviationweather.gov/api/data/taf"
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
        altim=newest.get("altim"),
        temp=newest.get("temp"),
        dewpoint=newest.get("dewp"),
        windspeed=_wind_kmh(newest.get("wspd")),
        winddir=_wind_dir(newest.get("wdir")),
        windgust=_wind_kmh(newest.get("wgst")),
        visibilitySM=vis,
        ceilingFt=ceiling_ft,
        ceilingCover=ceiling_cover,
        fltCat=newest.get("fltCat") or _flight_category(vis, ceiling_ft),
        wx=newest.get("wxString") or None,
        lightning=ltg.parse(newest.get("rawOb"), newest.get("wxString") or None,
                            newest.get("t")),
    )


def _series_point(p: dict) -> SeriesPoint:
    vis = _visibility_sm(p.get("visib"))
    ceiling_ft, _ = _ceiling(p.get("clouds"))
    return SeriesPoint(
        t=p["t"], slp=p["slp"], altim=p["altim"],
        windKmh=_wind_kmh(p.get("wspd")), windDir=_wind_dir(p.get("wdir")),
        gustKmh=_wind_kmh(p.get("wgst")), temp=p.get("temp"), dewpoint=p.get("dewp"),
        visibilitySM=vis, ceilingFt=ceiling_ft,
        fltCat=p.get("fltCat") or _flight_category(vis, ceiling_ft),
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
                    "elev": r.get("elev"),
                    "temp": r.get("temp"),
                    "dewp": r.get("dewp"),
                    "wspd": r.get("wspd"),
                    "wdir": r.get("wdir"),
                    "wgst": r.get("wgst"),
                    "visib": r.get("visib"),
                    "clouds": r.get("clouds"),
                    "fltCat": r.get("fltCat"),
                    "wxString": r.get("wxString"),
                    "rawOb": r.get("rawOb"),
                }
            )
        if not points:
            continue
        points.sort(key=lambda p: p["t"])
        newest = points[-1]

        def any_of(key):
            # Station metadata is the same on every report, but individual
            # records (SPECIs especially) drop fields — take it from whichever
            # report has it, newest first.
            return next((p[key] for p in reversed(points) if p.get(key) is not None), None)

        out[sid] = {
            "name": any_of("name"),
            "lat": any_of("lat"),
            "lon": any_of("lon"),
            "elev": any_of("elev"),
            "series": [_series_point(p) for p in points],
            # Wind + aviation conditions from the newest METAR — real measurements,
            # so the client can prefer them over the model for "now" (METAR-first).
            "current": _current_obs(newest),
            "presTend": newest.get("presTend"),
            "raw": newest.get("rawOb"),
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
    return await _fetch_parse(params, client)


# Half-height of the front-watch box in degrees of latitude (~155 km); the
# longitude half-width is scaled by cos(lat) so the box stays square-ish in km.
BBOX_HALF_LAT_DEG = 1.4


async def fetch_metars_bbox(
    lat: float,
    lon: float,
    client: httpx.AsyncClient,
    *,
    hours: int = 4,
    half_lat_deg: float = BBOX_HALF_LAT_DEG,
) -> Dict[str, dict]:
    """Fetch + parse every reporting station in a box around a point — the
    regional tendency field for the front watch, in ONE call. AWC's bbox form
    is minLat,minLon,maxLat,maxLon."""
    half_lon = half_lat_deg / max(0.2, math.cos(math.radians(lat)))
    params = {
        "bbox": f"{lat - half_lat_deg},{lon - half_lon},{lat + half_lat_deg},{lon + half_lon}",
        "format": "json",
        "hours": str(hours),
    }
    return await _fetch_parse(params, client)


async def _fetch_parse(params: dict, client: httpx.AsyncClient) -> Dict[str, dict]:
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


# ---- Bulk cache --------------------------------------------------------------

def _f(value) -> Optional[float]:
    """CSV cell -> float; "10+" style caps parse to their number."""
    if value is None:
        return None
    v = str(value).strip().rstrip("+")
    if not v:
        return None
    try:
        return float(v)
    except ValueError:
        return None


def parse_metar_cache(text: str) -> List[StationObs]:
    """Parse AWC's metars.cache.csv into StationObs. Rows without a real
    position (some military ids report -99.99) are dropped. Sky layers come
    as repeated sky_cover/cloud_base_ft_agl column pairs."""
    import csv
    from io import StringIO

    rows = csv.reader(StringIO(text))
    header = next(rows, None)
    if not header or "station_id" not in header:
        return []
    col = {name: i for i, name in enumerate(header)}   # last index wins for dupes
    covers = [i for i, n in enumerate(header) if n == "sky_cover"]
    bases = [i for i, n in enumerate(header) if n == "cloud_base_ft_agl"]

    def cell(row, name):
        i = col.get(name)
        v = row[i] if i is not None and i < len(row) else None
        # AWC writes the literal word "null" for some empty text fields.
        return None if v is None or v.strip() in ("", "null") else v

    out: List[StationObs] = []
    for row in rows:
        if len(row) < 12:
            continue
        sid = (cell(row, "station_id") or "").strip().upper()
        lat, lon = _f(cell(row, "latitude")), _f(cell(row, "longitude"))
        # -99.99/-99.99 (some military ids) fails the latitude range.
        if not sid or lat is None or lon is None or abs(lat) > 90 or abs(lon) > 180:
            continue
        # Ceiling: lowest BKN/OVC/OVX layer; else the lowest layer reported.
        layers = []
        for ci, bi in zip(covers, bases):
            cov = row[ci].strip() if ci < len(row) else ""
            if cov and cov != "null":
                layers.append((cov, _f(row[bi]) if bi < len(row) else None))
        ceiling_ft, ceiling_cover = None, None
        ceils = [(b, c) for c, b in layers if c in _CEILING_COVERS and b is not None]
        if ceils:
            b, c = min(ceils)
            ceiling_ft, ceiling_cover = int(b), c
        elif layers:
            ceiling_cover = layers[0][0]
        wdir = _f(cell(row, "wind_dir_degrees"))
        altim_inhg = _f(cell(row, "altim_in_hg"))
        obs = None
        t = cell(row, "observation_time")
        if t:
            try:
                obs = datetime.fromisoformat(t.replace("Z", "+00:00"))
            except ValueError:
                obs = None
        out.append(StationObs(
            id=sid, lat=lat, lon=lon,
            windKt=_f(cell(row, "wind_speed_kt")),
            windDir=wdir,
            gustKt=_f(cell(row, "wind_gust_kt")),
            fltCat=(cell(row, "flight_category") or None),
            obsTime=obs,
            visibilitySM=_f(cell(row, "visibility_statute_mi")),
            ceilingFt=ceiling_ft, ceilingCover=ceiling_cover,
            temp=_f(cell(row, "temp_c")), dewpoint=_f(cell(row, "dewpoint_c")),
            altim=round(altim_inhg * 33.8639, 1) if altim_inhg is not None else None,
            slp=_f(cell(row, "sea_level_pressure_mb")),
            presTend=_f(cell(row, "three_hr_pressure_tendency_mb")),
            wx=(cell(row, "wx_string") or None),
            lightning=ltg.parse(cell(row, "raw_text"), cell(row, "wx_string"), obs),
            raw=(cell(row, "raw_text") or None),
        ))
    return out


async def fetch_metar_cache(client: httpx.AsyncClient) -> List[StationObs]:
    """One request for the whole world's latest METARs."""
    import gzip
    r = await client.get(CACHE_URL, headers={"User-Agent": USER_AGENT}, timeout=30.0)
    r.raise_for_status()
    body = r.content
    if body[:2] == b"\x1f\x8b":
        body = gzip.decompress(body)
    return parse_metar_cache(body.decode("utf-8", errors="replace"))


# ---- Station directory ------------------------------------------------------

def parse_station_info(items) -> Dict[str, dict]:
    """AWC stations.cache.json -> {ICAO: {name, lat, lon, elev, metar, taf}}.
    Name is composed the way AWC's METAR JSON does it ("Site, ST, CC")."""
    out: Dict[str, dict] = {}
    for it in items or []:
        sid = (it.get("icaoId") or "").strip().upper()
        if not sid or it.get("lat") is None or it.get("lon") is None:
            continue
        bits = [b for b in (it.get("site"), it.get("state"), it.get("country")) if b]
        types = it.get("siteType") or []
        out[sid] = {
            "name": ", ".join(bits) if bits else sid,
            "site": it.get("site") or sid,
            "lat": float(it["lat"]), "lon": float(it["lon"]),
            "elev": it.get("elev"),
            "metar": "METAR" in types, "taf": "TAF" in types,
        }
    return out


async def fetch_station_info(client: httpx.AsyncClient) -> Dict[str, dict]:
    import gzip
    import json
    r = await client.get(STATIONS_URL, headers={"User-Agent": USER_AGENT}, timeout=30.0)
    r.raise_for_status()
    body = r.content
    if body[:2] == b"\x1f\x8b":
        body = gzip.decompress(body)
    return parse_station_info(json.loads(body.decode("utf-8", errors="replace")))


# ---- TAF ------------------------------------------------------------------

def _any_to_dt(value) -> Optional[datetime]:
    """AWC mixes epoch integers (period times) and ISO strings (issue/valid
    times) in the same TAF record."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return _epoch_to_dt(value)
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def parse_taf(records) -> Optional[TafOut]:
    """AWC's decoded TAF JSON (one record per station, `fcsts` = periods)."""
    if not records:
        return None
    rec = records[0]
    sid = (rec.get("icaoId") or "").upper()
    if not sid:
        return None
    periods: List[TafPeriod] = []
    for f in rec.get("fcsts") or []:
        vis = _visibility_sm(f.get("visib"))
        ceiling_ft, cover = _ceiling(f.get("clouds"))
        wdir = f.get("wdir")
        periods.append(TafPeriod(
            timeFrom=_any_to_dt(f.get("timeFrom")), timeTo=_any_to_dt(f.get("timeTo")),
            change=f.get("fcstChange") or None,
            windDir=float(wdir) if isinstance(wdir, (int, float)) else None,
            windKt=f.get("wspd"), gustKt=f.get("wgst"),
            visibilitySM=vis, ceilingFt=ceiling_ft, ceilingCover=cover,
            wx=f.get("wxString") or None,
            fltCat=_flight_category(vis, ceiling_ft),
        ))
    return TafOut(station=sid, issueTime=_any_to_dt(rec.get("issueTime")),
                  validFrom=_any_to_dt(rec.get("validTimeFrom")),
                  validTo=_any_to_dt(rec.get("validTimeTo")),
                  raw=rec.get("rawTAF"), periods=periods)


async def fetch_taf(station: str, client: httpx.AsyncClient) -> Optional[TafOut]:
    r = await client.get(TAF_URL, params={"ids": station.upper(), "format": "json"},
                         headers={"User-Agent": USER_AGENT}, timeout=15.0)
    r.raise_for_status()
    if not r.content.strip():
        return None
    return parse_taf(r.json())
