"""The radar's model layers read from the HRRR store instead of Open-Meteo.

Point sampling is bilinear on the native 3 km grid; a map region's worth
of points is well under a millisecond once the fields are in the page
cache. Height contours resample the region onto a regular lattice (each
cell the mean of nine samples, so the 3 km detail doesn't alias into the
coarser lattice) and run the same marching squares as the isobars.
"""

from __future__ import annotations

import math
from datetime import datetime
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

from . import grib
from . import pressure_field
from .modelstore import ModelStore
from .models import ContourLine, FieldLevelPoint, FieldPoint, LevelWind

FEED = "hrrr"
LEVELS = (925, 850, 700, 600, 500)
KMH_PER_MS = 3.6

_GRIDS: Dict[Tuple, grib.LambertGrid] = {}


def grid(store: ModelStore, feed: str, cycle: datetime) -> Optional[grib.LambertGrid]:
    meta = store.grid(feed, cycle)
    if not meta:
        return None
    key = tuple(sorted(meta.items()))
    g = _GRIDS.get(key)
    if g is None:
        g = grib.LambertGrid.from_meta(meta)
        _GRIDS[key] = g
    return g


def _pair(store: ModelStore, un: str, vn: str, now: datetime):
    """u and v from the same cycle and hour, with that grid."""
    u = store.nearest(FEED, un, now)
    if u is None:
        return None
    _, cycle, fhr = u
    v = store.load(FEED, cycle, fhr, vn)
    g = grid(store, FEED, cycle)
    if v is None or g is None:
        return None
    return u[0], v, g, cycle, fhr


def _enough(values: np.ndarray) -> bool:
    """Most of the region is on the grid. Off it (the map panned past the
    HRRR domain), the caller falls back to the global model."""
    return np.isfinite(values).mean() >= 0.5


def field_points(store: ModelStore, lats: Sequence[float], lons: Sequence[float],
                 now: datetime) -> Optional[List[FieldPoint]]:
    got = _pair(store, "u10", "v10", now)
    if got is None:
        return None
    u, v, g, cycle, fhr = got
    la, lo = np.asarray(lats), np.asarray(lons)
    us, vs = g.sample(u, la, lo), g.sample(v, la, lo)
    if not _enough(us):
        return None
    spd, deg = grib.wind_speed_dir(us, vs)
    extras = {}
    for name in ("hpbl", "cape"):
        arr = store.load(FEED, cycle, fhr, name)
        extras[name] = g.sample(arr, la, lo) if arr is not None else None
    out: List[FieldPoint] = []
    for k in range(len(la)):
        if not math.isfinite(spd[k]):
            continue
        bl = extras["hpbl"][k] if extras["hpbl"] is not None else float("nan")
        cape = extras["cape"][k] if extras["cape"] is not None else float("nan")
        out.append(FieldPoint(
            lat=float(la[k]), lon=float(lo[k]),
            windKmh=round(float(spd[k]) * KMH_PER_MS, 1), windDeg=round(float(deg[k])),
            blM=round(float(bl)) if math.isfinite(bl) else None,
            capeJkg=round(float(cape)) if math.isfinite(cape) else None))
    return out


def _underground(store: ModelStore, g: grib.LambertGrid, cycle: datetime, fhr: int,
                 hpa: int, lats, lons) -> np.ndarray:
    """True where the level lies below the ground: surface pressure under
    the level's own (with 10 hPa to spare for the smoothing)."""
    psfc = store.load(FEED, cycle, fhr, "psfc")
    if psfc is None:
        return np.zeros(np.shape(lats), dtype=bool)
    ps = g.sample(psfc, lats, lons)
    return np.isfinite(ps) & (ps < hpa + 10)


def level_points(store: ModelStore, lats: Sequence[float], lons: Sequence[float],
                 now: datetime) -> Optional[List[FieldLevelPoint]]:
    la, lo = np.asarray(lats), np.asarray(lons)
    per_level = {}
    for p in LEVELS:
        got = _pair(store, f"u{p}", f"v{p}", now)
        if got is None:
            return None
        u, v, g, cycle, fhr = got
        us, vs = g.sample(u, la, lo), g.sample(v, la, lo)
        if not _enough(us):
            return None
        below = _underground(store, g, cycle, fhr, p, la, lo)
        us[below] = np.nan
        vs[below] = np.nan
        per_level[p] = grib.wind_speed_dir(us, vs)
    out: List[FieldLevelPoint] = []
    for k in range(len(la)):
        levels = [LevelWind(hPa=p, windKmh=round(float(spd[k]) * KMH_PER_MS, 1), windDeg=round(float(deg[k])))
                  for p, (spd, deg) in per_level.items() if math.isfinite(spd[k])]
        if levels:
            out.append(FieldLevelPoint(lat=float(la[k]), lon=float(lo[k]), levels=levels))
    return out


def height_interval(hpa: int) -> int:
    """Chart practice: 30 m at 700 hPa and below, 60 m above."""
    return 30 if hpa >= 700 else 60


def heights(store: ModelStore, hpa: int, lat: float, lon: float, lat_span: float, lon_span: float,
            now: datetime, cells: int = 40
            ) -> Optional[Tuple[List[ContourLine], int, datetime, int]]:
    """Height contours for a region: (lines, interval, cycle, forecast hour)."""
    found = store.nearest(FEED, f"hgt{hpa}", now)
    if found is None:
        return None
    field, cycle, fhr = found
    g = grid(store, FEED, cycle)
    if g is None:
        return None
    # A tenth past each edge so lines reach the screen's border.
    lat_span, lon_span = lat_span * 1.2, lon_span * 1.2
    ny = nx = cells
    lat0, lon0 = lat - lat_span / 2, lon - lon_span / 2
    dlat, dlon = lat_span / (ny - 1), lon_span / (nx - 1)
    jj, ii = np.mgrid[0:ny, 0:nx]
    acc = np.zeros((ny, nx))
    n = np.zeros((ny, nx))
    for sj in (-1 / 3, 0, 1 / 3):
        for si in (-1 / 3, 0, 1 / 3):
            la = (lat0 + (jj + sj) * dlat).ravel()
            lo = (lon0 + (ii + si) * dlon).ravel()
            vals = g.sample(field, la, lo)
            vals[_underground(store, g, cycle, fhr, hpa, la, lo)] = np.nan
            vals = vals.reshape(ny, nx)
            ok = np.isfinite(vals)
            acc[ok] += vals[ok]
            n[ok] += 1
    with np.errstate(invalid="ignore", divide="ignore"):
        mean = np.where(n >= 5, acc / np.maximum(n, 1), np.nan)
    if not np.isfinite(mean).any():
        return None
    values = [[None if not math.isfinite(x) else float(x) for x in row] for row in mean]
    pg = pressure_field.Grid(lat0=lat0, lon0=lon0, dlat=dlat, dlon=dlon, ny=ny, nx=nx, values=values)
    step = height_interval(hpa)
    lo_v, hi_v = np.nanmin(mean), np.nanmax(mean)
    lines: List[ContourLine] = []
    level = math.ceil(lo_v / step) * step
    while level <= hi_v:
        for line in pressure_field.contour(pg, level):
            if len(line) >= 2:
                lines.append(ContourLine(level=level, points=[[round(a, 4), round(b, 4)] for a, b in line]))
        level += step
    return lines, step, cycle, fhr
