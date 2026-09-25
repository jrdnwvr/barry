"""The radar's model layers read from the HRRR store instead of Open-Meteo.

Point sampling is bilinear on the native 3 km grid; a map region's worth
of points is well under a millisecond once the fields are in the page
cache. Height contours resample the region onto a regular lattice (each
cell the mean of nine samples, so the 3 km detail doesn't alias into the
coarser lattice) and run the same marching squares as the isobars.
"""

from __future__ import annotations

import math
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

from . import grib
from . import pressure_field
from .modelstore import ModelStore
from .models import (AloftHour, AloftIceLevel, AloftIcing, AloftLevel, AloftSurface,
                     AloftTurbLevel, AloftTurbulence, ContourLine, FieldLevelPoint,
                     FieldPoint, LevelWind)

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


# ---- the Aloft column ---------------------------------------------------------

COL_FEEDS = ("hrrr-col", "hrrr-colx")
COL_LEVELS = (1000, 975, 950, 925, 900, 875, 850, 825, 800, 750, 700, 650, 600, 550, 500, 450, 400)
FT_PER_M = 3.28084
KT_PER_MS = 1.943844
# Cloud from relative humidity (Sundqvist: none below 80 percent, overcast
# at saturation) and from the model's own cloud water and ice, whichever
# says more: 50 percent once there is any condensate to speak of, 80 once
# there is a real amount.
RH_CRIT = 0.80
Q_TRACE, Q_CLOUD = 1e-6, 1e-5


def _find(store: ModelStore, valid: datetime):
    """(feed, cycle, fhr) for the newest cycle holding this valid hour, the
    hourly feed before the day-long one."""
    for feed in COL_FEEDS:
        for cycle in store.cycles(feed):
            fhr = int(round((valid - cycle).total_seconds() / 3600))
            if fhr in store.hours(feed, cycle):
                return feed, cycle, fhr
    return None


def cloud_pct(rh: float, qc: float, qi: float) -> int:
    r = max(0.0, min(1.0, rh / 100.0))
    c = 0.0 if r <= RH_CRIT else 1.0 - math.sqrt((1.0 - r) / (1.0 - RH_CRIT))
    q = max(0.0, qc) + max(0.0, qi)
    if q >= Q_CLOUD:
        c = max(c, 0.8)
    elif q >= Q_TRACE:
        c = max(c, 0.5)
    return int(round(100 * c))


def dew_point_c(t_c: float, rh: float) -> Optional[float]:
    """Magnus, over water."""
    if not (rh > 0):
        return None
    g = math.log(min(rh, 100.0) / 100.0) + 17.625 * t_c / (243.04 + t_c)
    return 243.04 * g / (17.625 - g)


def column(store: ModelStore, lat: float, lon: float, start: datetime, hours: int = 25
           ) -> Optional[List[AloftHour]]:
    """Hourly columns at a point from `start` (the top of an hour), from the
    column feeds. Levels under the ground are left out. None when fewer
    than twelve hours can be built, so the caller falls back."""
    from .sources.openmeteo import cloud_layers
    out: List[AloftHour] = []
    la, lo = np.array([lat]), np.array([lon])
    for h in range(hours):
        valid = start + timedelta(hours=h)
        found = _find(store, valid)
        if found is None:
            continue
        feed, cycle, fhr = found
        g = grid(store, feed, cycle)
        if g is None:
            continue

        def at(name: str) -> float:
            arr = store.load(feed, cycle, fhr, name)
            return float(g.sample(arr, la, lo)[0]) if arr is not None else float("nan")

        ground = at("zsfc")
        levels: List[AloftLevel] = []
        for p in COL_LEVELS:
            hgt, t = at(f"hgt{p}"), at(f"t{p}")
            if not (math.isfinite(hgt) and math.isfinite(t)):
                continue
            if math.isfinite(ground) and hgt < ground:
                continue
            t_c = t                                   # stored in Celsius
            rh = at(f"rh{p}")
            u, v = at(f"u{p}"), at(f"v{p}")
            spd, deg = grib.wind_speed_dir(u, v)
            levels.append(AloftLevel(
                hPa=p, ft=int(round(hgt * FT_PER_M)), tempC=round(t_c, 1),
                dewC=round(dew_point_c(t_c, rh), 1) if math.isfinite(rh) and dew_point_c(t_c, rh) is not None else None,
                dirDeg=round(float(deg)) if math.isfinite(float(spd)) else None,
                spdKt=round(float(spd) * KT_PER_MS, 1) if math.isfinite(float(spd)) else None,
                cloudPct=cloud_pct(rh, at(f"qc{p}"), at(f"qi{p}")) if math.isfinite(rh) else None,
            ))
        if len(levels) < 3:
            continue
        levels.sort(key=lambda lv: lv.ft)
        t2, td2 = at("t2"), at("td2")
        s_spd, s_deg = grib.wind_speed_dir(at("u10"), at("v10"))
        frz, hpbl = at("frz"), at("hpbl")
        out.append(AloftHour(
            t=valid, levels=levels, clouds=cloud_layers(levels),
            surface=AloftSurface(
                tempC=round(t2, 1) if math.isfinite(t2) else None,
                dewC=round(td2, 1) if math.isfinite(td2) else None,
                dirDeg=round(float(s_deg)) if math.isfinite(float(s_spd)) else None,
                spdKt=round(float(s_spd) * KT_PER_MS, 1) if math.isfinite(float(s_spd)) else None),
            freezingFt=int(round(frz * FT_PER_M)) if math.isfinite(frz) else None,
            blAglFt=int(round(hpbl * FT_PER_M)) if math.isfinite(hpbl) else None,
        ))
    return out if len(out) >= 12 else None


def column_key(store: ModelStore) -> str:
    """Changes whenever either column feed gains a cycle."""
    parts = []
    for feed in COL_FEEDS:
        c = store.cycles(feed)
        parts.append(c[0].strftime("%Y%m%d%H") if c else "-")
    return ":".join(parts)


# ---- turbulence and icing now -------------------------------------------------

HAZARD_TOP_FT = 30000
HAZARD_MAX_AGE = timedelta(minutes=90)


def _levels(store: ModelStore, feed: str, prefix: str, valid: datetime) -> List[int]:
    names = store.hours(feed, valid).get(0, [])
    out = []
    for n in names:
        if n.startswith(prefix + "_"):
            try:
                out.append(int(n.split("_", 1)[1]))
            except ValueError:
                continue
    return sorted(out)


def hazards(store: ModelStore, lat: float, lon: float, now: datetime
            ) -> Tuple[Optional[AloftTurbulence], Optional[AloftIcing]]:
    la, lo = np.array([lat]), np.array([lon])
    turb = ice = None
    runs = store.cycles("gtg")
    if runs and now - runs[0] <= HAZARD_MAX_AGE:
        t = runs[0]
        g = grid(store, "gtg", t)
        levels = []
        for ft in _levels(store, "gtg", "edr", t):
            if ft > HAZARD_TOP_FT:
                continue
            arr = store.load("gtg", t, 0, f"edr_{ft}")
            v = float(g.sample(arr, la, lo)[0]) if arr is not None and g is not None else float("nan")
            if math.isfinite(v):
                levels.append(AloftTurbLevel(ft=ft, edr=round(max(0.0, v), 3)))
        if levels:
            turb = AloftTurbulence(t=t, levels=levels)
    runs = store.cycles("cip")
    if runs and now - runs[0] <= HAZARD_MAX_AGE:
        t = runs[0]
        g = grid(store, "cip", t)
        levels = []
        for ft in _levels(store, "cip", "icp", t):
            if ft > HAZARD_TOP_FT or g is None:
                continue
            vals = {}
            for pre in ("icp", "ics", "sld"):
                arr = store.load("cip", t, 0, f"{pre}_{ft}")
                vals[pre] = float(g.sample(arr, la, lo)[0]) if arr is not None else float("nan")
            if not math.isfinite(vals["icp"]):
                continue
            levels.append(AloftIceLevel(
                ft=ft, prob=round(max(0.0, vals["icp"]), 2),
                severity=int(round(vals["ics"])) if math.isfinite(vals["ics"]) else 0,
                sld=round(vals["sld"], 2) if math.isfinite(vals["sld"]) else None))
        if levels:
            ice = AloftIcing(t=t, levels=levels)
    return turb, ice
