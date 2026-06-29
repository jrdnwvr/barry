"""Minimal station table: ICAO id -> name/lat/lon.

AWC returns name/lat/lon inline on every record, so this table is only needed for
(a) the graceful-degradation path, which must locate a station without AWC, and
(b) the client convenience endpoint /stations/nearest used for location->station
resolution (brief Phase 3). It is intentionally small; extend as needed or back
it with a real airport dataset later.
"""

from __future__ import annotations

from math import asin, cos, radians, sin, sqrt
from typing import Dict, List, Optional, Tuple

STATIONS: Dict[str, dict] = {
    "KLUK": {"name": "Cincinnati Lunken, OH", "lat": 39.103, "lon": -84.419},
    "KCVG": {"name": "Cincinnati/N. Kentucky Intl, KY", "lat": 39.044, "lon": -84.672},
    "KILN": {"name": "Wilmington, OH", "lat": 39.428, "lon": -83.792},
    "KJFK": {"name": "New York JFK, NY", "lat": 40.640, "lon": -73.779},
    "KSFO": {"name": "San Francisco Intl, CA", "lat": 37.619, "lon": -122.375},
    "KORD": {"name": "Chicago O'Hare, IL", "lat": 41.979, "lon": -87.904},
    "KSEA": {"name": "Seattle-Tacoma, WA", "lat": 47.449, "lon": -122.309},
    "KBOS": {"name": "Boston Logan, MA", "lat": 42.363, "lon": -71.006},
    "KDEN": {"name": "Denver Intl, CO", "lat": 39.862, "lon": -104.673},
    "KATL": {"name": "Atlanta Hartsfield, GA", "lat": 33.640, "lon": -84.427},
}


def get(station: str) -> Optional[dict]:
    return STATIONS.get(station.upper())


def _haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371.0
    dlat = radians(lat2 - lat1)
    dlon = radians(lon2 - lon1)
    a = sin(dlat / 2) ** 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlon / 2) ** 2
    return 2 * r * asin(sqrt(a))


def nearest(lat: float, lon: float) -> Optional[Tuple[str, dict, float]]:
    """Return (station_id, info, distance_km) for the closest known station."""
    best = None
    for sid, info in STATIONS.items():
        d = _haversine_km(lat, lon, info["lat"], info["lon"])
        if best is None or d < best[2]:
            best = (sid, info, d)
    return best
