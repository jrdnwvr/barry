"""Observed signals from the station's own recent METARs (C2).

Pressure is the lead instrument; these are how a change actually announces
itself at a field: the wind veers or backs, a gust front arrives, the
temperature drops behind a front, the ceiling comes down. Pure functions
over SeriesPoints so they test without I/O.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import List, Optional, Sequence

from .models import SeriesPoint

LOOKBACK_H = 3.0            # only recent reports count as "a signal"
PAIR_MIN_H, PAIR_MAX_H = 0.75, 2.5   # compare a report with one this much earlier
WIND_SHIFT_DEG = 60.0
WIND_MIN_KMH = 9.0          # ~5 kt: below this a direction is noise
GUST_ONSET_KMH = 28.0       # ~15 kt
GUST_QUIET_KMH = 19.0       # ~10 kt: "no gusts before" means under this
TEMP_DROP_C = 3.0
CAT_ORDER = {"VFR": 0, "MVFR": 1, "IFR": 2, "LIFR": 3}


@dataclass(frozen=True)
class Signal:
    kind: str                 # wind_shift | gust_onset | temp_drop | category_change
    at: datetime
    detail: dict = field(default_factory=dict)


def _angle_delta(a: float, b: float) -> float:
    """Signed change from a to b in degrees, -180..180 (positive = veer)."""
    return (b - a + 540.0) % 360.0 - 180.0


def _earlier(pts: Sequence[SeriesPoint], i: int, has) -> Optional[SeriesPoint]:
    """The most recent report PAIR_MIN_H..PAIR_MAX_H before pts[i] that `has`."""
    t = pts[i].t
    for j in range(i - 1, -1, -1):
        dt = (t - pts[j].t).total_seconds() / 3600.0
        if dt > PAIR_MAX_H:
            break
        if dt >= PAIR_MIN_H and has(pts[j]):
            return pts[j]
    return None


def detect(series: Sequence[SeriesPoint], now: datetime) -> List[Signal]:
    pts = sorted((p for p in series if p.t >= now - timedelta(hours=LOOKBACK_H + PAIR_MAX_H)),
                 key=lambda p: p.t)
    recent_from = now - timedelta(hours=LOOKBACK_H)
    out: List[Signal] = []
    seen = set()

    for i in range(len(pts) - 1, -1, -1):
        p = pts[i]
        if p.t < recent_from:
            break

        # Wind shift: both ends blowing, direction moved a lot.
        if "wind_shift" not in seen and p.windDir is not None and (p.windKmh or 0) >= WIND_MIN_KMH:
            q = _earlier(pts, i, lambda x: x.windDir is not None and (x.windKmh or 0) >= WIND_MIN_KMH)
            if q is not None:
                d = _angle_delta(q.windDir, p.windDir)
                if abs(d) >= WIND_SHIFT_DEG:
                    out.append(Signal("wind_shift", p.t, {
                        "fromDeg": q.windDir, "toDeg": p.windDir, "veer": d > 0}))
                    seen.add("wind_shift")

        # Gust onset: gusting now, quiet a couple of hours ago.
        if "gust_onset" not in seen and (p.gustKmh or 0) >= GUST_ONSET_KMH:
            q = _earlier(pts, i, lambda x: x.windKmh is not None)
            if q is not None and (q.gustKmh or 0) < GUST_QUIET_KMH:
                out.append(Signal("gust_onset", p.t, {"gustKmh": p.gustKmh}))
                seen.add("gust_onset")

        # Temperature drop behind a front.
        if "temp_drop" not in seen and p.temp is not None:
            q = _earlier(pts, i, lambda x: x.temp is not None)
            if q is not None and q.temp - p.temp >= TEMP_DROP_C:
                out.append(Signal("temp_drop", p.t, {"dropC": q.temp - p.temp}))
                seen.add("temp_drop")

        # Flight category change (either direction; the reader decides).
        if "category_change" not in seen and p.fltCat in CAT_ORDER:
            q = _earlier(pts, i, lambda x: x.fltCat in CAT_ORDER)
            if q is not None and q.fltCat != p.fltCat:
                out.append(Signal("category_change", p.t, {
                    "fromCat": q.fltCat, "toCat": p.fltCat,
                    "worse": CAT_ORDER[p.fltCat] > CAT_ORDER[q.fltCat]}))
                seen.add("category_change")

    out.sort(key=lambda s: s.at)
    return out
