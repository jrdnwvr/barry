"""The last twenty minutes of lightning flashes, in memory, and what can be
read off it: a binned slice for the map, and the nearest flash to a point
with the storm's drift.

Fed by the GLM poll (sources/glm.py) once a minute. Pure data structure
with no I/O so the geometry tests without a network.
"""

from __future__ import annotations

import math
from datetime import datetime
from typing import Dict, List, Optional, Sequence, Tuple

from .models import LightningCell, LightningCluster, LightningNearby, LightningResponse
from .sources.glm import Flash

WINDOW_S = 1200.0           # 20 minutes of flashes
BIN_DEG = 0.02              # ~2 km cells on the map
MAX_CELLS = 2500            # densest / newest cells per slice
RADIUS_KM = 160.9           # 100 statute miles, same as the METAR search
CLUSTER_MIN_FLASHES = 3     # smaller groups are noise, not a storm
CLUSTER_RECENT_S = 300.0    # "recent" flashes: the last five minutes
MOTION_MIN_FLASHES = 5      # per half-window before a drift is claimed
MOTION_MIN_KM = 3.0         # centroid must move this far to be called motion
ETA_MIN_KMH = 8.0           # slower than this and "arrival" is a guess
ETA_MAX_H = 6.0             # beyond this the cluster will not be the same storm
_COMPASS = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]


def _haversine_km(lat1, lon1, lat2, lon2) -> float:
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def _bearing_deg(lat1, lon1, lat2, lon2) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    x = math.sin(dl) * math.cos(p2)
    y = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(x, y)) + 360.0) % 360.0


def cardinal(deg: float) -> str:
    return _COMPASS[int(((deg + 22.5) % 360) // 45)]


def _convex_hull(points: Sequence[Tuple[float, float]]) -> List[Tuple[float, float]]:
    """Andrew's monotone chain; the result is closed (first point repeated)."""
    pts = sorted(set(points))
    if len(pts) <= 2:
        return list(pts) + list(pts[:1])

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower: List[Tuple[float, float]] = []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    upper: List[Tuple[float, float]] = []
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    hull = lower[:-1] + upper[:-1]
    return hull + hull[:1]


class FlashStore:
    def __init__(self) -> None:
        self._flashes: List[Flash] = []
        self.seen: Dict[str, str] = {}          # satellite -> last key taken
        self.last_fetch: Optional[datetime] = None
        self.files = 0
        self.bytes = 0

    def __len__(self) -> int:
        return len(self._flashes)

    def add(self, flashes: Sequence[Flash], now: datetime) -> None:
        cutoff = now.timestamp() - WINDOW_S
        self._flashes = [f for f in self._flashes if f.t >= cutoff]
        self._flashes.extend(f for f in flashes if f.t >= cutoff and f.t <= now.timestamp() + 120)

    def prune(self, now: datetime) -> None:
        cutoff = now.timestamp() - WINDOW_S
        self._flashes = [f for f in self._flashes if f.t >= cutoff]

    def fresh(self, now: datetime, max_age_s: float = 300.0) -> bool:
        return self.last_fetch is not None and (now - self.last_fetch).total_seconds() <= max_age_s

    def recent(self, now: datetime) -> List[Flash]:
        """Every flash still in the window, for callers with their own shape
        to test against (the route's corridor)."""
        cutoff = now.timestamp() - WINDOW_S
        return [f for f in self._flashes if f.t >= cutoff]

    # ---- Map slice ----------------------------------------------------------

    def cells(self, lat: float, lon: float, half: float, now: datetime) -> List[LightningCell]:
        """Flashes inside ±half degrees, binned to BIN_DEG cells: centre,
        count, and the age of the newest flash in the cell."""
        lon_half = half / max(0.2, math.cos(math.radians(lat)))
        bins: Dict[Tuple[int, int], List[float]] = {}
        t_now = now.timestamp()
        for f in self._flashes:
            if abs(f.lat - lat) > half or abs(f.lon - lon) > lon_half:
                continue
            k = (int(math.floor(f.lat / BIN_DEG)), int(math.floor(f.lon / BIN_DEG)))
            b = bins.get(k)
            if b is None:
                bins[k] = [1.0, f.t]
            else:
                b[0] += 1
                if f.t > b[1]:
                    b[1] = f.t
        out = [LightningCell(lat=round((k[0] + 0.5) * BIN_DEG, 4), lon=round((k[1] + 0.5) * BIN_DEG, 4),
                             count=int(v[0]), ageSec=max(0, int(t_now - v[1])))
               for k, v in bins.items()]
        if len(out) > MAX_CELLS:
            out.sort(key=lambda c: (c.ageSec, -c.count))
            out = out[:MAX_CELLS]
        return out

    def clusters(self, cells: Sequence[LightningCell], now: datetime) -> List[LightningCluster]:
        """Touching cells (8-neighbourhood on the bin grid) grouped into
        storms, each wrapped in the convex hull of its cells' corners so the
        outline sits just outside the flashes."""
        by_key = {(int(round(c.lat / BIN_DEG - 0.5)), int(round(c.lon / BIN_DEG - 0.5))): c for c in cells}
        seen: set = set()
        out: List[LightningCluster] = []
        for start in by_key:
            if start in seen:
                continue
            stack, group = [start], []
            seen.add(start)
            while stack:
                k = stack.pop()
                group.append(k)
                for di in (-1, 0, 1):
                    for dj in (-1, 0, 1):
                        n = (k[0] + di, k[1] + dj)
                        if n in by_key and n not in seen:
                            seen.add(n)
                            stack.append(n)
            flashes = sum(by_key[k].count for k in group)
            if flashes < CLUSTER_MIN_FLASHES:
                continue
            corners = []
            for (i, j) in group:
                for (a, b) in ((0, 0), (0, 1), (1, 0), (1, 1)):
                    corners.append(((i + a) * BIN_DEG, (j + b) * BIN_DEG))
            hull = _convex_hull(corners)
            recent = sum(by_key[k].count for k in group if by_key[k].ageSec <= CLUSTER_RECENT_S)
            newest = min(by_key[k].ageSec for k in group)
            out.append(LightningCluster(points=[[round(p[0], 4), round(p[1], 4)] for p in hull],
                                        flashes=flashes, recent=recent, newestAgeSec=newest))
        out.sort(key=lambda c: -c.flashes)
        return out

    def response(self, lat: float, lon: float, half: float, now: datetime) -> LightningResponse:
        cells = self.cells(lat, lon, half, now)
        return LightningResponse(cells=cells, clusters=self.clusters(cells, now), windowSec=int(WINDOW_S),
                                 binDeg=BIN_DEG, coverage=self.fresh(now), cachedAt=now)

    # ---- Nearest flash + drift -----------------------------------------------

    def nearest(self, lat: float, lon: float, now: datetime,
                continues_until: Optional[datetime] = None) -> Optional[LightningNearby]:
        """The closest flash within RADIUS_KM, how many flashes fell inside
        that circle over the window, and whether the cluster is drifting
        toward the point (centroid of the newer half against the older half)."""
        t_now = now.timestamp()
        near: List[Tuple[Flash, float]] = []
        for f in self._flashes:
            if abs(f.lat - lat) > 1.6 or abs(f.lon - lon) > 2.2:
                continue   # cheap box before the trig
            d = _haversine_km(lat, lon, f.lat, f.lon)
            if d <= RADIUS_KM:
                near.append((f, d))
        if not near:
            return None
        best, dist = min(near, key=lambda fd: fd[1])
        brg = _bearing_deg(lat, lon, best.lat, best.lon)

        toward: Optional[bool] = None
        moving: Optional[str] = None
        speed_kmh: Optional[float] = None
        eta = None
        mid = t_now - WINDOW_S / 2
        old = [f for f, _ in near if f.t < mid]
        new = [f for f, _ in near if f.t >= mid]
        if len(old) >= MOTION_MIN_FLASHES and len(new) >= MOTION_MIN_FLASHES:
            o = (sum(f.lat for f in old) / len(old), sum(f.lon for f in old) / len(old))
            n = (sum(f.lat for f in new) / len(new), sum(f.lon for f in new) / len(new))
            moved_km = _haversine_km(*o, *n)
            if moved_km >= MOTION_MIN_KM:
                mv = _bearing_deg(*o, *n)
                moving = cardinal(mv)
                to_user = _bearing_deg(n[0], n[1], lat, lon)
                diff = abs((mv - to_user + 540.0) % 360.0 - 180.0)
                closer = _haversine_km(lat, lon, *n) < _haversine_km(lat, lon, *o)
                toward = True if (diff <= 45.0 and closer) else (False if diff >= 135.0 else None)
                # Centroids are half a window apart in time.
                speed_kmh = round(moved_km / (WINDOW_S / 2 / 3600.0), 1)
                if toward and speed_kmh >= ETA_MIN_KMH:
                    hours = _haversine_km(lat, lon, *n) / speed_kmh
                    if hours <= ETA_MAX_H:
                        from datetime import timedelta
                        eta = now + timedelta(hours=hours)

        return LightningNearby(
            station="GLM", name="GOES lightning mapper",
            distanceMi=int(round(dist * 0.621371)), bearingDeg=round(brg, 1),
            cardinal=cardinal(brg), status="strikes",
            at=datetime.fromtimestamp(best.t, tz=now.tzinfo),
            moving=moving, towardYou=toward, continuesUntil=continues_until,
            source="glm", flashes=len(near), speedKmh=speed_kmh, etaAt=eta,
        )
