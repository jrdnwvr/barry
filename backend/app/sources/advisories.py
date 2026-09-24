"""The Aviation Weather Center's advisories, for the radar's Advisories layer.

Three national feeds, each pulled once every ten minutes for everyone:
SIGMETs (convective and the rest), G-AIRMETs at the current hour (IFR,
mountain obscuration, turbulence, icing, surface wind, low-level shear),
and pilot reports of turbulence and icing over the last two hours. The
same fixed cost as the METAR table; public domain.
"""

from __future__ import annotations

import ast
from datetime import datetime, timezone
from typing import Any, List, Optional

import httpx

from ..models import AdvisoryArea, PirepOut

USER_AGENT = "Barry/1.0 (jrdn@wvr.me)"
SIGMET_URL = "https://aviationweather.gov/api/data/airsigmet?format=json"
GAIRMET_URL = "https://aviationweather.gov/api/data/gairmet?format=json"
PIREP_URL = "https://aviationweather.gov/api/data/pirep?format=json&age=2&bbox=18,-130,56,-60"

# G-AIRMET hazards drawn as areas, and the word each is labelled with.
GAIRMET_HAZARDS = {
    "IFR": "IFR", "MT_OBSC": "Mtn obsc", "TURB-HI": "Turb", "TURB-LO": "Turb",
    "ICE": "Ice", "SFC_WND": "Sfc wind", "LLWS": "LLWS",
}


def _time(v: Any) -> Optional[datetime]:
    if v in (None, "", "None"):
        return None
    try:
        return datetime.fromtimestamp(float(v), tz=timezone.utc)
    except (TypeError, ValueError):
        pass
    try:
        return datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except ValueError:
        return None


def _coords(v: Any) -> List[List[float]]:
    if isinstance(v, str):
        try:
            v = ast.literal_eval(v)
        except (ValueError, SyntaxError):
            return []
    out = []
    for c in v or []:
        try:
            out.append([float(c["lat"]), float(c["lon"])])
        except (KeyError, TypeError, ValueError):
            continue
    return out


def _hundreds(v: Any) -> Optional[int]:
    """"050" or "FL180" (hundreds of feet) to feet; "SFC" to 0; "FZL" or
    missing to None."""
    if v in (None, "", "None", "FZL"):
        return None
    s = str(v).upper().replace("FL", "")
    if s == "SFC":
        return 0
    try:
        return int(float(s)) * 100
    except ValueError:
        return None


def _feet(v: Any) -> Optional[int]:
    if v in (None, "", "None"):
        return None
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return None


def parse_sigmets(data: Any) -> List[AdvisoryArea]:
    out: List[AdvisoryArea] = []
    for x in data or []:
        kind_raw = str(x.get("airSigmetType") or "").upper()
        if kind_raw not in ("SIGMET", "AIRMET"):
            continue                       # outlooks are not advisories
        hazard = str(x.get("hazard") or "").upper()
        pts = _coords(x.get("coords"))
        if len(pts) < 3:
            continue
        convective = hazard == "CONVECTIVE"
        kind = "convective" if convective else ("sigmet" if kind_raw == "SIGMET" else "airmet")
        label = f"Convective SIGMET {x.get('seriesId') or ''}".strip() if convective \
            else f"{kind_raw.title() if kind_raw == 'AIRMET' else 'SIGMET'} {hazard.title()}"
        out.append(AdvisoryArea(
            kind=kind, hazard=hazard or kind_raw, label=label,
            baseFt=_feet(x.get("altitudeLow1")), topFt=_feet(x.get("altitudeHi1")),
            validFrom=_time(x.get("validTimeFrom")), validTo=_time(x.get("validTimeTo")),
            points=pts, raw=x.get("rawAirSigmet")))
    return out


def parse_gairmets(data: Any) -> List[AdvisoryArea]:
    out: List[AdvisoryArea] = []
    for x in data or []:
        hazard = str(x.get("hazard") or "").upper()
        if hazard not in GAIRMET_HAZARDS or str(x.get("geometryType")) != "AREA":
            continue
        if str(x.get("forecastHour") or "0") != "0":
            continue
        pts = _coords(x.get("coords"))
        if len(pts) < 3:
            continue
        due = x.get("due_to")
        out.append(AdvisoryArea(
            kind="airmet", hazard=hazard, label=f"AIRMET {GAIRMET_HAZARDS[hazard]}",
            baseFt=_hundreds(x.get("base")), topFt=_hundreds(x.get("top")),
            validFrom=_time(x.get("validTime")), validTo=_time(x.get("expireTime")),
            points=pts, raw=None if due in (None, "", "None") else str(due)))
    return out


def _intensity(v: Any) -> Optional[str]:
    s = str(v or "").strip().upper()
    return s or None


def parse_pireps(data: Any) -> List[PirepOut]:
    """Reports of turbulence or icing (smooth and clear-of-ice included:
    a negative report is still news); the rest are left out."""
    out: List[PirepOut] = []
    for x in data or []:
        turb, ice = _intensity(x.get("tbInt1")), _intensity(x.get("icgInt1"))
        if not turb and not ice:
            continue
        try:
            lat, lon = float(x["lat"]), float(x["lon"])
        except (KeyError, TypeError, ValueError):
            continue
        fl = _feet(x.get("fltLvl"))
        out.append(PirepOut(
            lat=lat, lon=lon, obsTime=_time(x.get("obsTime")),
            altFt=fl * 100 if fl is not None else None,
            aircraft=x.get("acType") or None, turbulence=turb, icing=ice,
            urgent=str(x.get("pirepType") or "").upper().startswith("URGENT"),
            raw=x.get("rawOb") or ""))
    return out


async def _get(client: httpx.AsyncClient, url: str) -> Any:
    resp = await client.get(url, headers={"User-Agent": USER_AGENT}, timeout=15.0)
    resp.raise_for_status()
    return resp.json() if resp.content else []


async def fetch_sigmets(client: httpx.AsyncClient) -> List[AdvisoryArea]:
    return parse_sigmets(await _get(client, SIGMET_URL))


async def fetch_gairmets(client: httpx.AsyncClient) -> List[AdvisoryArea]:
    return parse_gairmets(await _get(client, GAIRMET_URL))


async def fetch_pireps(client: httpx.AsyncClient) -> List[PirepOut]:
    return parse_pireps(await _get(client, PIREP_URL))
