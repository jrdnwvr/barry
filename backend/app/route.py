"""A route from one field to another: the geometry and the words.

Everything here works on data the server already holds (the bulk METAR
table, the lightning store, the WPC analysis, the destination's TAF), so a
route costs no upstream call of its own. Distances are nautical miles on a
sphere; the corridor is the great circle between the two fields, not an
airway, and the app says so.
"""

from __future__ import annotations

import math
from datetime import datetime, timedelta, timezone
from typing import Iterable, List, Optional, Sequence, Tuple

R_NM = 3440.065
CATEGORY_RANK = {"LIFR": 0, "IFR": 1, "MVFR": 2, "VFR": 3}


def _rad(d: float) -> float:
    return math.radians(d)


def distance_nm(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1, p2 = _rad(lat1), _rad(lat2)
    dp, dl = p2 - p1, _rad(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R_NM * math.asin(min(1.0, math.sqrt(a)))


def bearing_rad(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1, p2, dl = _rad(lat1), _rad(lat2), _rad(lon2 - lon1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return math.atan2(y, x)


def track_position(a: Tuple[float, float], b: Tuple[float, float],
                   p: Tuple[float, float]) -> Tuple[float, float]:
    """(along, off) in NM of point p relative to the great circle a to b:
    along the track from a (negative behind a), and off to either side."""
    d13 = distance_nm(a[0], a[1], p[0], p[1]) / R_NM
    t13 = bearing_rad(a[0], a[1], p[0], p[1])
    t12 = bearing_rad(a[0], a[1], b[0], b[1])
    xt = math.asin(max(-1.0, min(1.0, math.sin(d13) * math.sin(t13 - t12))))
    at = math.acos(max(-1.0, min(1.0, math.cos(d13) / max(1e-12, math.cos(xt)))))
    if math.cos(t13 - t12) < 0:
        at = -at
    return at * R_NM, abs(xt) * R_NM


def _segments_cross(p1, p2, q1, q2) -> bool:
    """Whether segment p1-p2 crosses q1-q2 on a flat lat/lon plane (fine at
    the scale of a route and a front's segments)."""
    def orient(a, b, c):
        return (b[1] - a[1]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[1] - a[1])
    d1, d2 = orient(q1, q2, p1), orient(q1, q2, p2)
    d3, d4 = orient(p1, p2, q1), orient(p1, p2, q2)
    return (d1 > 0) != (d2 > 0) and (d3 > 0) != (d4 > 0)


def front_crossings(a, b, fronts: Iterable, *, steps: int = 24) -> List[Tuple[str, float]]:
    """(type, along NM) for each front line the route crosses. The route is
    split into short pieces so a long great circle stays close to its arc."""
    pts = [(a[0] + (b[0] - a[0]) * i / steps, a[1] + (b[1] - a[1]) * i / steps) for i in range(steps + 1)]
    out: List[Tuple[str, float]] = []
    for f in fronts:
        line = [(p[0], p[1]) for p in f.points]
        hit: Optional[Tuple[float, float]] = None
        for i in range(len(pts) - 1):
            for j in range(len(line) - 1):
                if _segments_cross(pts[i], pts[i + 1], line[j], line[j + 1]):
                    hit = pts[i]
                    break
            if hit:
                break
        if hit:
            along, _ = track_position(a, b, hit)
            out.append((f.type, max(0.0, along)))
    return sorted(out, key=lambda t: t[1])


def worst(categories: Sequence[Optional[str]]) -> Optional[str]:
    known = [c for c in categories if c in CATEGORY_RANK]
    return min(known, key=lambda c: CATEGORY_RANK[c]) if known else None


def taf_at(periods: Sequence, t: datetime):
    """The TAF's prevailing period at t (base, FM or BECMG), and any TEMPO or
    PROB period that also covers t."""
    prevailing = None
    for p in periods:
        if p.change in (None, "FM", "BECMG") and p.timeFrom <= t < p.timeTo:
            prevailing = p
    temporary = [p for p in periods
                 if p.change not in (None, "FM", "BECMG") and p.timeFrom <= t < p.timeTo]
    return prevailing, temporary


def _julian(dt: datetime) -> float:
    return dt.timestamp() / 86400.0 + 2440587.5


def _from_julian(j: float) -> datetime:
    return datetime.fromtimestamp((j - 2440587.5) * 86400.0, tz=timezone.utc)


def sunset(lat: float, lon: float, day: datetime) -> Optional[datetime]:
    """Sunset on the UTC day of `day` (the sunrise equation, to a minute or
    two); None in polar day or night."""
    noon = datetime(day.year, day.month, day.day, 12, tzinfo=timezone.utc)
    n = round(_julian(noon) - 2451545.0 + 0.0008)
    j_star = n - lon / 360.0
    m = (357.5291 + 0.98560028 * j_star) % 360
    mr = _rad(m)
    c = 1.9148 * math.sin(mr) + 0.0200 * math.sin(2 * mr) + 0.0003 * math.sin(3 * mr)
    lam = _rad((m + c + 180 + 102.9372) % 360)
    j_transit = 2451545.0 + j_star + 0.0053 * math.sin(mr) - 0.0069 * math.sin(2 * lam)
    decl = math.asin(math.sin(lam) * math.sin(_rad(23.4397)))
    cos_w = (math.sin(_rad(-0.833)) - math.sin(_rad(lat)) * math.sin(decl)) / (math.cos(_rad(lat)) * math.cos(decl))
    if not -1 <= cos_w <= 1:
        return None
    return _from_julian(j_transit + math.degrees(math.acos(cos_w)) / 360.0)


def minutes_from_sunset(lat: float, lon: float, t: datetime) -> Optional[int]:
    """Arrival minus the nearest sunset, in minutes (negative is before it);
    None when no sunset is within three hours."""
    best: Optional[float] = None
    for d in (-1, 0, 1):
        s = sunset(lat, lon, t + timedelta(days=d))
        if s is None:
            continue
        diff = (t - s).total_seconds() / 60.0
        if best is None or abs(diff) < abs(best):
            best = diff
    if best is None or abs(best) > 180:
        return None
    return int(round(best))
