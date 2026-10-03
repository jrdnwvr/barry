"""The last twenty minutes of lightning flashes, in memory, and what can be
read off it: a binned slice for the map, and the nearest flash to a point
with the storm's drift.

Only credible flashes are read off it. GLM reports the odd flash in clear
air (a pilot saw "lightning nearby" under a clear sky, 2026-09-26), so a
flash counts when the radar backs it, echo of BACKED_DBZ or more within
about 10 km (lightning needs a strong convective core), or, where the radar
shows nothing or cannot see, when it is one of GROUP_MIN flashes within
GROUP_KM over the window. Measured on 2026-09-26 against the MRMS
composite: of 4,088 flashes inside radar coverage, 93 percent had 30 dBZ or
more within 5 km; of the 101 with no other flash within 20 km, 22 had no
echo at all. One backed flash is enough; a lone flash in clear air is not.

Fed by the GLM poll (sources/glm.py) once a minute. Pure data structure
with no I/O so the geometry tests without a network.
"""

from __future__ import annotations

import math
from datetime import datetime
from typing import Callable, Dict, List, Optional, Sequence, Tuple

from .models import LightningCell, LightningCluster, LightningFrameOut, LightningNearby, LightningResponse
from .sources.glm import Flash

WINDOW_S = 1200.0           # 20 minutes of flashes
HISTORY_S = 6.5 * 3600.0    # credible flashes kept this long, for the radar's clock
HISTORY_STEP_S = 600        # the frames the history is served in
BIN_DEG = 0.02              # ~2 km cells on the map
MAX_CELLS = 2500            # densest / newest cells per slice
RADIUS_KM = 160.9           # 100 statute miles, same as the METAR search
CLUSTER_MIN_FLASHES = 3     # smaller groups are noise, not a storm
BACKED_DBZ = 30.0           # radar echo that makes a single flash believable
GROUP_KM = 20.0             # an unbacked flash needs company this close...
GROUP_MIN = 3               # ...this many flashes, itself included
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
    def __init__(self, echo_at: Optional[Callable[[float, float, float], Optional[float]]] = None) -> None:
        self._flashes: List[Flash] = []
        self.seen: Dict[str, str] = {}          # satellite -> last key taken
        self.last_fetch: Optional[datetime] = None
        self.files = 0
        self.bytes = 0
        # The strongest radar echo, dBZ, near (lat, lon) at unix time t, or
        # None where the radar cannot say (no frame near t, out of coverage).
        self.echo_at = echo_at
        self._backed: set = set()
        self._credible: Optional[List[Flash]] = None     # None: to be worked out
        # Every flash once believed, kept HISTORY_S: what the map's
        # lightning follows the radar's clock back through (frames).
        self._history: List[Flash] = []
        self._in_history: set = set()
        # When the history began: a mark whose window reaches before it
        # would read as a quiet sky when it is really an unknown one.
        self._history_since: Optional[float] = None

    def __len__(self) -> int:
        return len(self._flashes)

    def add(self, flashes: Sequence[Flash], now: datetime) -> None:
        if self._history_since is None:
            self._history_since = now.timestamp()
        cutoff = now.timestamp() - WINDOW_S
        self._flashes = [f for f in self._flashes if f.t >= cutoff]
        self._flashes.extend(f for f in flashes if f.t >= cutoff and f.t <= now.timestamp() + 120)
        self._credible = None

    def prune(self, now: datetime) -> None:
        cutoff = now.timestamp() - WINDOW_S
        self._flashes = [f for f in self._flashes if f.t >= cutoff]
        self._backed = {f for f in self._backed if f.t >= cutoff}
        self._credible = None
        old = now.timestamp() - HISTORY_S
        if self._history and self._history[0].t < old:
            self._history = [f for f in self._history if f.t >= old]
            self._in_history = set(self._history)

    # ---- Which flashes to believe ------------------------------------------

    def credible(self) -> List[Flash]:
        """The flashes the radar backs, and those in a group of GROUP_MIN
        within GROUP_KM; worked out once per change to the store (a backed
        flash stays backed; the rest are checked again against newer radar)."""
        if self._credible is not None:
            return self._credible
        if self.echo_at is not None:
            for f in self._flashes:
                if f in self._backed:
                    continue
                try:
                    e = self.echo_at(f.lat, f.lon, f.t)
                except Exception:
                    e = None
                if e is not None and e >= BACKED_DBZ:
                    self._backed.add(f)
        cell = GROUP_KM / 111.0
        bins: Dict[Tuple[int, int], List[Flash]] = {}
        for f in self._flashes:
            bins.setdefault((int(math.floor(f.lat / cell)), int(math.floor(f.lon / cell))), []).append(f)
        out: List[Flash] = []
        for f in self._flashes:
            if f in self._backed:
                out.append(f)
                continue
            bi, bj = int(math.floor(f.lat / cell)), int(math.floor(f.lon / cell))
            n = 0
            # Longitude cells shrink toward the pole; two either side covers 20 km to 60 degrees.
            for di in (-1, 0, 1):
                for dj in (-2, -1, 0, 1, 2):
                    for o in bins.get((bi + di, bj + dj), ()):
                        if _haversine_km(f.lat, f.lon, o.lat, o.lon) <= GROUP_KM:
                            n += 1
                            if n >= GROUP_MIN:
                                break
                    if n >= GROUP_MIN:
                        break
                if n >= GROUP_MIN:
                    break
            if n >= GROUP_MIN:
                out.append(f)
        self._credible = out
        for f in out:
            if f not in self._in_history:
                self._in_history.add(f)
                self._history.append(f)
        return out

    @property
    def dropped(self) -> int:
        """Flashes in the window not believed (lone, and the radar shows no storm)."""
        return len(self._flashes) - len(self.credible())

    def fresh(self, now: datetime, max_age_s: float = 300.0) -> bool:
        return self.last_fetch is not None and (now - self.last_fetch).total_seconds() <= max_age_s

    def recent(self, now: datetime) -> List[Flash]:
        """Every credible flash still in the window, for callers with their
        own shape to test against (the route's corridor)."""
        cutoff = now.timestamp() - WINDOW_S
        return [f for f in self.credible() if f.t >= cutoff]

    # ---- Map slice ----------------------------------------------------------

    def cells(self, lat: float, lon: float, half: float, now: datetime) -> List[LightningCell]:
        """Flashes inside ±half degrees, binned to BIN_DEG cells: centre,
        count, and the age of the newest flash in the cell."""
        lon_half = half / max(0.2, math.cos(math.radians(lat)))
        bins: Dict[Tuple[int, int], List[float]] = {}
        t_now = now.timestamp()
        for f in self.credible():
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

    def frames(self, lat: float, lon: float, half: float, now: datetime,
               hours: float = 6.0) -> List[LightningFrameOut]:
        """The flashes once believed inside ±half degrees, as the cells of
        a window ending at each ten-minute mark from `hours` back to the
        last mark before now: what the map's lightning shows for a moment
        of the radar's clock. Ages are from the mark."""
        lon_half = half / max(0.2, math.cos(math.radians(lat)))
        self.credible()
        near = [f for f in self._history if abs(f.lat - lat) <= half and abs(f.lon - lon) <= lon_half]
        near.sort(key=lambda f: f.t)
        last = int(now.timestamp() // HISTORY_STEP_S) * HISTORY_STEP_S
        first = last - int(hours * 3600)
        if self._history_since is None:
            return []
        # Only marks whose whole window the history saw.
        first = max(first, int(math.ceil((self._history_since + WINDOW_S) / HISTORY_STEP_S)) * HISTORY_STEP_S)
        out: List[LightningFrameOut] = []
        for mark in range(first, last + 1, HISTORY_STEP_S):
            bins: Dict[Tuple[int, int], List[float]] = {}
            for f in near:
                if f.t <= mark - WINDOW_S:
                    continue
                if f.t > mark:
                    break
                k = (int(math.floor(f.lat / BIN_DEG)), int(math.floor(f.lon / BIN_DEG)))
                b = bins.get(k)
                if b is None:
                    bins[k] = [1.0, f.t]
                else:
                    b[0] += 1
                    if f.t > b[1]:
                        b[1] = f.t
            cells = [LightningCell(lat=round((k[0] + 0.5) * BIN_DEG, 4), lon=round((k[1] + 0.5) * BIN_DEG, 4),
                                   count=int(v[0]), ageSec=max(0, int(mark - v[1])))
                     for k, v in bins.items()]
            if len(cells) > MAX_CELLS:
                cells.sort(key=lambda c: (c.ageSec, -c.count))
                cells = cells[:MAX_CELLS]
            out.append(LightningFrameOut(time=mark, cells=cells))
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
        for f in self.credible():
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
