"""Lightning and thunderstorms, decoded from the METAR itself.

No new data source: the present-weather group carries TS / VCTS and the
remarks carry the lightning report (FRQ LTGICCG OHD, LTG DSNT SW, TSB42,
TSNO). ASOS sites with a lightning sensor use fixed bands, so the words mean
distances: a thunderstorm in the body is within about 5 NM, VC is 5 to 10 NM,
and DSNT is 10 to 30 NM. Manual observers use the same words less precisely,
and the client copy stays vague enough for both.

Pure functions, no I/O. `parse` returns None for "nothing reported", which
must never be read as "no lightning": a field without a sensor, or one whose
sensor is out (TSNO), says nothing at all.
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta
from typing import List, Optional

from .models import LightningNearby, LightningOut, StationObs

# Present weather containing a thunderstorm: TS, TSRA, +TSRA, VCTS, TSGR ...
_WX_TS = re.compile(r"^[+-]?(VC)?TS([A-Z]{2})*$")
# Remarks tokens: LTG, LTGIC, LTGICCG, LTGCGIC, LTGCC ...
_LTG = re.compile(r"^LTG((?:IC|CC|CG|CA)*)$")
_TSB = re.compile(r"^TSB(\d{2}|\d{4})(?:E(\d{2}|\d{4}))?$")
_TSE = re.compile(r"^TSE(\d{2}|\d{4})$")
_DIRS = {"N", "NE", "E", "SE", "S", "SW", "W", "NW"}
_FREQ = {"OCNL": "occasional", "FRQ": "frequent", "CONS": "continuous"}


def _split_types(code: str) -> List[str]:
    out: List[str] = []
    for i in range(0, len(code), 2):
        t = code[i:i + 2]
        if t in ("IC", "CC", "CG", "CA") and t not in out:
            out.append(t)
    return out


def _directions(tokens: List[str], start: int) -> tuple[List[str], Optional[str], int]:
    """Direction words following a lightning/TS token: 'SW', 'SW-NW',
    'W AND NW', 'ALQDS', plus an optional 'MOV E'. Returns (dirs, moving,
    index of the first token not consumed)."""
    dirs: List[str] = []
    moving: Optional[str] = None
    i = start
    while i < len(tokens):
        t = tokens[i]
        if t in ("AND",):
            i += 1
            continue
        if t in ("ALQDS", "ALQS"):
            dirs.append("ALQDS")
            i += 1
            continue
        if t == "MOV" and i + 1 < len(tokens) and tokens[i + 1] in _DIRS:
            moving = tokens[i + 1]
            i += 2
            continue
        if t in _DIRS:
            dirs.append(t)
            i += 1
            continue
        if "-" in t and all(p in _DIRS for p in t.split("-")):
            dirs.append(t)
            i += 1
            continue
        break
    return dirs, moving, i


def _time_from(code: str, obs: Optional[datetime]) -> Optional[datetime]:
    """TSB42 = minute 42 of the observation hour (or the hour before, when
    that minute is after the observation); TSB1542 = 15:42Z."""
    if obs is None:
        return None
    if len(code) == 4:
        hh, mm = int(code[:2]), int(code[2:])
        if hh > 23 or mm > 59:
            return None
        t = obs.replace(hour=hh, minute=mm, second=0, microsecond=0)
        if t > obs + timedelta(minutes=5):
            t -= timedelta(days=1)
        return t
    mm = int(code)
    if mm > 59:
        return None
    t = obs.replace(minute=mm, second=0, microsecond=0)
    if t > obs + timedelta(minutes=1):
        t -= timedelta(hours=1)
    return t


def parse(raw: Optional[str], wx: Optional[str] = None,
          obs_time: Optional[datetime] = None) -> Optional[LightningOut]:
    """Decode the thunderstorm/lightning state of one METAR. `wx` is AWC's
    decoded present-weather string when available (the body is parsed for
    it otherwise)."""
    if not raw and not wx:
        return None
    body, _, rmk = (raw or "").partition(" RMK ")
    body_tokens = body.split()
    rmk_tokens = rmk.split()

    if "TSNO" in rmk_tokens:
        return None  # lightning sensor out: nothing can be said

    wx_tokens = wx.split() if wx else [t for t in body_tokens if _WX_TS.match(t)]
    at_station = any(_WX_TS.match(t) and not t.lstrip("+-").startswith("VC") for t in wx_tokens)
    in_vicinity = any(_WX_TS.match(t) and t.lstrip("+-").startswith("VC") for t in wx_tokens)

    frequency: Optional[str] = None
    types: List[str] = []
    dirs: List[str] = []
    moving: Optional[str] = None
    since: Optional[datetime] = None
    ltg_seen = False
    ltg_distant = False
    ltg_overhead = False
    ltg_vicinity = False
    ts_ended = False

    i = 0
    while i < len(rmk_tokens):
        t = rmk_tokens[i]
        m = _LTG.match(t)
        if m:
            ltg_seen = True
            if i > 0 and rmk_tokens[i - 1] in _FREQ:
                frequency = _FREQ[rmk_tokens[i - 1]]
            for ty in _split_types(m.group(1)):
                if ty not in types:
                    types.append(ty)
            j = i + 1
            # Qualifiers: OHD / VC / DSNT, in any order before the directions.
            while j < len(rmk_tokens) and rmk_tokens[j] in ("OHD", "VC", "DSNT"):
                q = rmk_tokens[j]
                ltg_overhead |= q == "OHD"
                ltg_vicinity |= q == "VC"
                ltg_distant |= q == "DSNT"
                j += 1
            d, mv, j = _directions(rmk_tokens, j)
            dirs += [x for x in d if x not in dirs]
            moving = moving or mv
            i = j
            continue
        m = _TSB.match(t)
        if m:
            since = _time_from(m.group(1), obs_time)
            if m.group(2):
                ts_ended = True
            i += 1
            continue
        if _TSE.match(t):
            ts_ended = True
            i += 1
            continue
        if t == "TS" and i + 1 < len(rmk_tokens):
            # "TS SW MOV NE" / "TS OHD": where the storm is and where it's going.
            j = i + 1
            if rmk_tokens[j] == "OHD":
                ltg_overhead = True
                j += 1
            d, mv, j = _directions(rmk_tokens, j)
            dirs += [x for x in d if x not in dirs]
            moving = moving or mv
            i = j
            continue
        i += 1

    if at_station or ltg_overhead:
        status = "thunderstorm"
    elif in_vicinity or ltg_vicinity or (ltg_seen and not ltg_distant):
        status = "vicinity"
    elif ltg_distant:
        status = "distant"
    elif since is not None and not ts_ended:
        status = "thunderstorm"
    else:
        return None

    return LightningOut(status=status, frequency=frequency, types=types,
                        directions=dirs, moving=moving,
                        since=since if status == "thunderstorm" else None)


# ---- Nearest lightning to a point ----------------------------------------------

LIGHTNING_RADIUS_KM = 160.9        # 100 statute miles
LIGHTNING_MAX_AGE_H = 1.5          # older reports are last hour's storm
_STATUS_RANK = {"thunderstorm": 0, "vicinity": 1, "distant": 2}
_COMPASS = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
_COMPASS_DEG = {c: i * 45.0 for i, c in enumerate(_COMPASS)}
_CARDINAL_WORD = {"N": "north", "NE": "northeast", "E": "east", "SE": "southeast",
                  "S": "south", "SW": "southwest", "W": "west", "NW": "northwest"}


def _haversine_km(lat1, lon1, lat2, lon2) -> float:
    import math
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def _bearing_deg(lat1, lon1, lat2, lon2) -> float:
    import math
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    x = math.sin(dl) * math.cos(p2)
    y = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(x, y)) + 360.0) % 360.0


def cardinal(deg: float) -> str:
    return _COMPASS[int(((deg + 22.5) % 360) // 45)]


def nearest(table: List[StationObs], lat: float, lon: float, now: datetime,
            continues_until: Optional[datetime] = None) -> Optional[LightningNearby]:
    """The closest fresh lightning report within LIGHTNING_RADIUS_KM. A
    "distant" report puts the flashes 10 to 30 NM from THAT station, not at
    it, so any station with a storm at it or close by outranks every
    distant-only report; distant reports are the fallback."""
    best = None
    best_key = None
    for s in table:
        if s.lightning is None or s.obsTime is None:
            continue
        age_h = (now - s.obsTime).total_seconds() / 3600.0
        if age_h > LIGHTNING_MAX_AGE_H or age_h < -0.25:
            continue
        d = _haversine_km(lat, lon, s.lat, s.lon)
        if d > LIGHTNING_RADIUS_KM:
            continue
        key = (s.lightning.status == "distant", d)
        if best_key is None or key < best_key:
            best, best_key = s, key
    if best is None:
        return None
    dist_km = _haversine_km(lat, lon, best.lat, best.lon)
    brg = _bearing_deg(lat, lon, best.lat, best.lon)
    toward: Optional[bool] = None
    mv = best.lightning.moving
    if mv in _COMPASS_DEG and dist_km >= 3:
        # The storm moves toward `mv`; it comes at the user when that is
        # within 45° of the bearing from the storm to the user.
        to_user = (brg + 180.0) % 360.0
        diff = abs((_COMPASS_DEG[mv] - to_user + 540.0) % 360.0 - 180.0)
        toward = True if diff <= 45.0 else (False if diff >= 135.0 else None)
    return LightningNearby(
        station=best.id, name=best.name,
        distanceMi=int(round(dist_km * 0.621371)),
        bearingDeg=round(brg, 1), cardinal=cardinal(brg),
        status=best.lightning.status, at=best.obsTime,
        moving=mv, towardYou=toward, continuesUntil=continues_until,
    )
