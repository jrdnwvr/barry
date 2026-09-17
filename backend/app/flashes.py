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

from .models import LightningCell, LightningNearby, LightningResponse
from .sources.glm import Flash

WINDOW_S = 1200.0           # 20 minutes of flashes
BIN_DEG = 0.02              # ~2 km cells on the map
MAX_CELLS = 2500            # densest / newest cells per slice
RADIUS_KM = 160.9           # 100 statute miles, same as the METAR search
MOTION_MIN_FLASHES = 5      # per half-window before a drift is claimed
MOTION_MIN_KM = 3.0         # centroid must move this far to be called motion
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

    def response(self, lat: float, lon: float, half: float, now: datetime) -> LightningResponse:
        return LightningResponse(cells=self.cells(lat, lon, half, now), windowSec=int(WINDOW_S),
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
        mid = t_now - WINDOW_S / 2
        old = [f for f, _ in near if f.t < mid]
        new = [f for f, _ in near if f.t >= mid]
        if len(old) >= MOTION_MIN_FLASHES and len(new) >= MOTION_MIN_FLASHES:
            o = (sum(f.lat for f in old) / len(old), sum(f.lon for f in old) / len(old))
            n = (sum(f.lat for f in new) / len(new), sum(f.lon for f in new) / len(new))
            if _haversine_km(*o, *n) >= MOTION_MIN_KM:
                mv = _bearing_deg(*o, *n)
                moving = cardinal(mv)
                to_user = _bearing_deg(n[0], n[1], lat, lon)
                diff = abs((mv - to_user + 540.0) % 360.0 - 180.0)
                closer = _haversine_km(lat, lon, *n) < _haversine_km(lat, lon, *o)
                toward = True if (diff <= 45.0 and closer) else (False if diff >= 135.0 else None)

        return LightningNearby(
            station="GLM", name="GOES lightning mapper",
            distanceMi=int(round(dist * 0.621371)), bearingDeg=round(brg, 1),
            cardinal=cardinal(brg), status="strikes",
            at=datetime.fromtimestamp(best.t, tz=now.tzinfo),
            moving=moving, towardYou=toward, continuesUntil=continues_until,
            source="glm", flashes=len(near),
        )
