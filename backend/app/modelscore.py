"""How the models Barry runs do at the stations it serves.

Once an hour, for each model feed that holds the hour, the model's
sea-level pressure and 10 m wind are read at every METAR station on its
grid whose report is within 15 minutes of the hour, and compared with the
report. Kept 60 days. This is the evidence for the RRFS switch (NOAA.md
phase 7): run beside HRRR through the winter, switch when it is at least
as good.

Scores per model and hour: stations, sea-level pressure mean absolute
error and bias (model minus station), the same error with the hour's
median bias taken out (the models reduce to sea level their own way; the
app shifts the curve to the station anyway, so this is the number that
matters), 10 m wind speed error in knots, and direction error where the
wind is 8 kt or more.
"""

from __future__ import annotations

import math
from datetime import datetime, timedelta, timezone
from typing import Dict, Iterable, List, Optional, Tuple

import numpy as np

from . import grib
from .modelfields import grid
from .modelstore import ModelStore

# model name -> (feed, what to add to the stored pressure)
MODELS: Dict[str, Tuple[str, float]] = {
    "hrrr": ("hrrr", 0.0),            # the map feed keeps hPa as float32
    "rrfs": ("rrfs-sfc", 1000.0),     # stored less 1,000 in half precision
}
OBS_WINDOW = timedelta(minutes=15)
MIN_STATIONS = 100
KEEP_DAYS = 60
KT_PER_MS = 1.943844


def _find(store: ModelStore, feed: str, valid: datetime):
    for cycle in store.cycles(feed):
        fhr = int(round((valid - cycle).total_seconds() / 3600))
        if fhr in store.hours(feed, cycle):
            return cycle, fhr
    return None


def score_hour(store: ModelStore, table: Iterable, valid: datetime) -> Optional[dict]:
    """Scores for one valid hour, or None when too few reports fall near it
    or no model holds it."""
    obs = [s for s in table if s.kind == "metar" and s.obsTime is not None
           and abs(s.obsTime - valid) <= OBS_WINDOW]
    if len(obs) < MIN_STATIONS:
        return None
    lat = np.array([s.lat for s in obs])
    lon = np.array([s.lon for s in obs])
    out: dict = {"t": valid.isoformat(), "reports": len(obs)}
    for name, (feed, add) in MODELS.items():
        found = _find(store, feed, valid)
        if found is None:
            continue
        cycle, fhr = found
        g = grid(store, feed, cycle)
        mslp, u, v = (store.load(feed, cycle, fhr, n) for n in ("mslp", "u10", "v10"))
        if g is None or mslp is None or u is None or v is None:
            continue
        p = g.sample(mslp, lat, lon) + add
        spd, deg = grib.wind_speed_dir(g.sample(u, lat, lon), g.sample(v, lat, lon))
        spd = spd * KT_PER_MS
        slp_err = [pm - s.slp for pm, s in zip(p, obs) if s.slp is not None and math.isfinite(pm)]
        idx = [i for i, s in enumerate(obs) if s.windKt is not None and math.isfinite(spd[i])]
        if len(slp_err) < MIN_STATIONS // 2 or len(idx) < MIN_STATIONS // 2:
            continue
        e = np.array(slp_err)
        wind_err = [abs(spd[i] - obs[i].windKt) for i in idx]
        dirs = []
        for i in idx:
            s = obs[i]
            if s.windKt >= 8 and s.windDir is not None and math.isfinite(deg[i]):
                d = abs(deg[i] - s.windDir) % 360
                dirs.append(min(d, 360 - d))
        out[name] = {
            "run": cycle.isoformat(), "lead": fhr, "stations": len(e),
            "slpMae": round(float(np.mean(np.abs(e))), 2),
            "slpBias": round(float(np.mean(e)), 2),
            "slpMaeUnbiased": round(float(np.mean(np.abs(e - np.median(e)))), 2),
            "windMaeKt": round(float(np.mean(wind_err)), 2),
            "dirMaeDeg": round(float(np.mean(dirs)), 1) if dirs else None,
        }
    return out if any(k in out for k in MODELS) else None


def daily(records: List[dict], days: int = 14) -> List[dict]:
    """The records grouped by UTC day, each model's scores averaged, newest
    day first; only hours both models were scored count toward both."""
    by_day: Dict[str, List[dict]] = {}
    for r in records:
        by_day.setdefault(r["t"][:10], []).append(r)
    out = []
    for day in sorted(by_day, reverse=True)[:days]:
        rows = [r for r in by_day[day] if all(m in r for m in MODELS)]
        entry = {"day": day, "hours": len(rows)}
        for m in MODELS:
            vals = [r[m] for r in rows]
            if vals:
                entry[m] = {k: round(float(np.mean([v[k] for v in vals if v.get(k) is not None])), 2)
                            for k in ("slpMae", "slpBias", "slpMaeUnbiased", "windMaeKt", "dirMaeDeg", "lead")
                            if any(v.get(k) is not None for v in vals)}
        out.append(entry)
    return out


def prune(records: List[dict], now: datetime) -> List[dict]:
    cut = (now - timedelta(days=KEEP_DAYS)).isoformat()
    return [r for r in records if r["t"] >= cut]
