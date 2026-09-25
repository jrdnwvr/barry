"""How the models Barry runs do at the stations it serves.

Once an hour, RRFS's sea-level pressure and 10 m wind from the newest
cycle and lead that reach the hour are read at every METAR station on the
grid whose report is within 15 minutes of it, and HRRR's from the same
cycle at the same lead (its forecast feed, stored the same way: every
other point, half precision, pressure less 1,000), so the two are compared
like for like. Kept 60 days. This is the evidence for the RRFS switch
(NOAA.md phase 7): run beside HRRR through the winter, switch when it is at
least as good.

Scores per model and hour: stations, sea-level pressure mean absolute
error and bias (model minus station), the same error with the hour's
median bias taken out (the models reduce to sea level their own way; the
app shifts the curve to the station anyway, so this is the number that
matters), 10 m wind speed error in knots, and direction error where the
wind is 8 kt or more.

An hour's record is filled in as the feeds land: a pass that finds the
METARs before RRFS has arrived adds RRFS on a later pass, so a slow cycle
costs nothing but time.
"""

from __future__ import annotations

import math
from datetime import datetime, timedelta, timezone
from typing import Dict, Iterable, List, Optional, Tuple

import numpy as np

from . import grib
from .modelfields import grid
from .modelstore import ModelStore

RRFS_FEED = "rrfs-sfc"
HRRR_FEED = "hrrr-fc3"          # the point forecast feed, packed, 6 km, half precision
PRESSURE_ADD = 1000.0            # both store pressure less 1,000 hPa
MODELS: Tuple[Tuple[str, str], ...] = (("rrfs", RRFS_FEED), ("hrrr", HRRR_FEED))
OBS_WINDOW = timedelta(minutes=15)
MIN_STATIONS = 100
KEEP_DAYS = 60
KT_PER_MS = 1.943844


def _find(store: ModelStore, feed: str, valid: datetime) -> Optional[Tuple[datetime, int]]:
    """The newest cycle of the feed with an hour valid at `valid`."""
    for cycle in store.cycles(feed):
        fhr = int(round((valid - cycle).total_seconds() / 3600))
        if fhr in store.hours(feed, cycle):
            return cycle, fhr
    return None


def _fields(store: ModelStore, feed: str, cycle: datetime, fhr: int):
    """(grid, mslp, u10, v10) for one hour, from a packed hour or one file
    per field; None when the hour or a field is not held."""
    g = grid(store, feed, cycle)
    if g is None or fhr not in store.hours(feed, cycle):
        return None
    names = (store.grid(feed, cycle) or {}).get("pack")
    if names:
        arr = store.load(feed, cycle, fhr, "pack")
        if arr is None or not all(n in names for n in ("mslp", "u10", "v10")):
            return None
        return g, arr[..., names.index("mslp")], arr[..., names.index("u10")], arr[..., names.index("v10")]
    parts = [store.load(feed, cycle, fhr, n) for n in ("mslp", "u10", "v10")]
    if any(p is None for p in parts):
        return None
    return g, parts[0], parts[1], parts[2]


def _score(g: grib.LambertGrid, mslp, u, v, obs: List, lat: np.ndarray, lon: np.ndarray) -> Optional[dict]:
    p = g.sample(mslp, lat, lon) + PRESSURE_ADD
    spd, deg = grib.wind_speed_dir(g.sample(u, lat, lon), g.sample(v, lat, lon))
    spd = spd * KT_PER_MS
    slp_err = [pm - s.slp for pm, s in zip(p, obs) if s.slp is not None and math.isfinite(pm)]
    idx = [i for i, s in enumerate(obs) if s.windKt is not None and math.isfinite(spd[i])]
    if len(slp_err) < MIN_STATIONS // 2 or len(idx) < MIN_STATIONS // 2:
        return None
    e = np.array(slp_err)
    wind_err = [abs(spd[i] - obs[i].windKt) for i in idx]
    dirs = []
    for i in idx:
        s = obs[i]
        if s.windKt >= 8 and s.windDir is not None and math.isfinite(deg[i]):
            d = abs(deg[i] - s.windDir) % 360
            dirs.append(min(d, 360 - d))
    return {
        "stations": len(e),
        "slpMae": round(float(np.mean(np.abs(e))), 2),
        "slpBias": round(float(np.mean(e)), 2),
        "slpMaeUnbiased": round(float(np.mean(np.abs(e - np.median(e)))), 2),
        "windMaeKt": round(float(np.mean(wind_err)), 2),
        "dirMaeDeg": round(float(np.mean(dirs)), 1) if dirs else None,
    }


def score_hour(store: ModelStore, table: Iterable, valid: datetime,
               existing: Optional[dict] = None) -> Optional[dict]:
    """The record for one valid hour: RRFS from the newest cycle and lead
    that reach it, and HRRR from the same cycle and lead, each against the
    reports within 15 minutes of the hour. With `existing` (the record
    already held for the hour) only what it lacks is added. None when too
    few reports fall near the hour, RRFS does not hold it, or nothing new
    could be scored."""
    obs = [s for s in table if s.kind == "metar" and s.obsTime is not None
           and abs(s.obsTime - valid) <= OBS_WINDOW]
    if len(obs) < MIN_STATIONS:
        return None
    out = dict(existing) if existing else {"t": valid.isoformat(), "reports": len(obs)}
    if all(name in out for name, _ in MODELS):
        return None
    found = _find(store, RRFS_FEED, valid)
    if found is None:
        return None
    cycle, fhr = found
    lat = np.array([s.lat for s in obs])
    lon = np.array([s.lon for s in obs])
    added = False
    for name, feed in MODELS:
        if name in out:
            continue
        f = _fields(store, feed, cycle, fhr)
        if f is None:
            continue
        sc = _score(*f, obs, lat, lon)
        if sc is not None:
            out[name] = {"run": cycle.isoformat(), "lead": fhr, **sc}
            added = True
    return out if added else None


def matched(record: dict) -> bool:
    """Both models scored from the same cycle at the same lead."""
    h, r = record.get("hrrr"), record.get("rrfs")
    return bool(h and r and h.get("run") == r.get("run") and h.get("lead") == r.get("lead"))


def daily(records: List[dict], days: int = 14) -> List[dict]:
    """The matched records grouped by UTC day, each model's scores
    averaged, newest day first."""
    by_day: Dict[str, List[dict]] = {}
    for r in records:
        if matched(r):
            by_day.setdefault(r["t"][:10], []).append(r)
    out = []
    for day in sorted(by_day, reverse=True)[:days]:
        rows = by_day[day]
        entry = {"day": day, "hours": len(rows)}
        for m, _ in MODELS:
            vals = [r[m] for r in rows]
            entry[m] = {k: round(float(np.mean([v[k] for v in vals if v.get(k) is not None])), 2)
                        for k in ("slpMae", "slpBias", "slpMaeUnbiased", "windMaeKt", "dirMaeDeg", "lead")
                        if any(v.get(k) is not None for v in vals)}
        out.append(entry)
    return out


def prune(records: List[dict], now: datetime) -> List[dict]:
    cut = (now - timedelta(days=KEEP_DAYS)).isoformat()
    return [r for r in records if r["t"] >= cut]
