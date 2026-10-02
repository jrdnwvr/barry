"""Isobars and isallobars from Barry's own station data (pure Python).

Every station's sea-level pressure (and 3 h tendency) is already in the bulk
METAR table. This grids those points with a Gaussian-weighted inverse-
distance fit, drops obvious outliers first (a single bad barometer would
otherwise draw a bullseye), and runs marching squares to produce contour
polylines: isobars every 4 hPa, isallobars at ±1/2/3 hPa per 3 h. The
gridding and the outlier check are numpy (since 2026-10-02: a continental
view took seconds in plain loops, and the timeline asks for six past hours
of it); the contouring is plain Python on at most about 1,600 cells.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

from .models import ContourLine, FieldExtremum, GridOut, StationObs

KM_PER_DEG = 111.32
ISOBAR_STEP = 4.0
ISOBAR_RADIUS_KM = 110.0        # Gaussian half-width: synoptic-scale smoothing
ISALLOBAR_RADIUS_KM = 140.0
ISALLOBAR_STEP = 1.0            # every whole hPa per 3 h, no cap (the NWS chart style)
EXTREMUM_MIN = 1.0              # H/L marks only where the change is at least this
EXTREMUM_RADIUS_CELLS = 4       # local max/min over a (2r+1)^2 neighborhood
MARGIN_DEG = 1.5                # stations beyond the box still shape its edges
MAX_CELLS = 1600
OUTLIER_HPA = 5.0               # vs the mean of the nearest neighbors
OUTLIER_TEND = 2.5
MIN_WEIGHT = 0.05               # below this a cell has no real data nearby
MIN_STATIONS = 8                # fewer than this and the field is a guess
SLP_MIN, SLP_MAX = 940.0, 1070.0


@dataclass
class Grid:
    lat0: float
    lon0: float
    dlat: float
    dlon: float
    ny: int
    nx: int
    values: List[List[Optional[float]]]   # [row][col], None = no data


def _reject_outliers(pts: List[Tuple[float, float, float]], tol: float, k: int = 5):
    """Drop points that disagree with the mean of their k nearest neighbors."""
    if len(pts) <= k + 1:
        return pts
    p = np.asarray(pts, dtype=np.float64)
    la, lo, v = p[:, 0], p[:, 1], p[:, 2]
    cos_lat = np.cos(np.radians(la))
    keep = np.zeros(len(p), dtype=bool)
    # A few hundred rows of the distance table at a time: the whole table
    # for a continental view is tens of megabytes.
    for r0 in range(0, len(p), 256):
        r1 = min(len(p), r0 + 256)
        d2 = (la[r0:r1, None] - la[None, :]) ** 2 + ((lo[r0:r1, None] - lo[None, :]) * cos_lat[r0:r1, None]) ** 2
        d2[np.arange(r1 - r0), np.arange(r0, r1)] = np.inf
        near = np.argpartition(d2, k - 1, axis=1)[:, :k]
        keep[r0:r1] = np.abs(v[r0:r1] - v[near].mean(axis=1)) <= tol
    return [pt for pt, ok in zip(pts, keep) if ok]


def grid_field(pts: Sequence[Tuple[float, float, float]], lat: float, lon: float,
               lat_span: float, lon_span: float, radius_km: float) -> Optional[Grid]:
    """Gaussian IDW onto a regular lat/lon grid over the box (+margin)."""
    if len(pts) < MIN_STATIONS:
        return None
    half_lat, half_lon = lat_span / 2 + MARGIN_DEG, lon_span / 2 + MARGIN_DEG
    step = max(0.15, math.sqrt((2 * half_lat) * (2 * half_lon) / MAX_CELLS))
    ny = int((2 * half_lat) / step) + 1
    nx = int((2 * half_lon) / step) + 1
    lat0, lon0 = lat - half_lat, lon - half_lon
    cos_lat = math.cos(math.radians(lat))
    r2 = (radius_km / KM_PER_DEG) ** 2
    cutoff2 = 9 * r2                          # 3 half-widths: contribution ~ e^-9
    p = np.asarray(pts, dtype=np.float64)
    dx2 = ((p[:, 1][None, :] - (lon0 + np.arange(nx) * step)[:, None]) * cos_lat) ** 2      # (nx, points)
    values: List[List[Optional[float]]] = []
    for j in range(ny):
        d2 = dx2 + (p[:, 0] - (lat0 + j * step)) ** 2
        w = np.where(d2 > cutoff2, 0.0, np.exp(-d2 / r2))
        wsum = w.sum(axis=1)
        vsum = w @ p[:, 2]
        values.append([float(vs / ws) if ws >= MIN_WEIGHT else None for vs, ws in zip(vsum, wsum)])
    return Grid(lat0=lat0, lon0=lon0, dlat=step, dlon=step, ny=ny, nx=nx, values=values)


def _interp(a: float, b: float, level: float) -> float:
    return 0.5 if a == b else (level - a) / (b - a)


def contour(grid: Grid, level: float) -> List[List[Tuple[float, float]]]:
    """Marching squares -> chained polylines of (lat, lon)."""
    segs: List[Tuple[Tuple[float, float], Tuple[float, float]]] = []
    v = grid.values
    for j in range(grid.ny - 1):
        for i in range(grid.nx - 1):
            c = (v[j][i], v[j][i + 1], v[j + 1][i + 1], v[j + 1][i])   # bl, br, tr, tl (row j = south)
            if any(x is None for x in c):
                continue
            bl, br, tr, tl = c  # type: ignore[misc]
            idx = (bl >= level) | ((br >= level) << 1) | ((tr >= level) << 2) | ((tl >= level) << 3)
            if idx in (0, 15):
                continue
            lat_s, lat_n = grid.lat0 + j * grid.dlat, grid.lat0 + (j + 1) * grid.dlat
            lon_w, lon_e = grid.lon0 + i * grid.dlon, grid.lon0 + (i + 1) * grid.dlon
            # Edge crossings: south, east, north, west.
            s = (lat_s, lon_w + _interp(bl, br, level) * grid.dlon)
            e = (lat_s + _interp(br, tr, level) * grid.dlat, lon_e)
            n = (lat_n, lon_w + _interp(tl, tr, level) * grid.dlon)
            w = (lat_s + _interp(bl, tl, level) * grid.dlat, lon_w)
            table = {
                1: [(w, s)], 2: [(s, e)], 3: [(w, e)], 4: [(e, n)], 6: [(s, n)], 7: [(w, n)],
                8: [(n, w)], 9: [(n, s)], 11: [(n, e)], 12: [(e, w)], 13: [(e, s)], 14: [(s, w)],
            }
            if idx in (5, 10):
                center = (bl + br + tr + tl) / 4
                if (idx == 5) == (center >= level):
                    segs += [(w, n), (e, s)] if idx == 5 else [(w, s), (e, n)]
                else:
                    segs += [(w, s), (e, n)] if idx == 5 else [(w, n), (e, s)]
            else:
                segs += table[idx]
    return _chain(segs)


def _key(p: Tuple[float, float]) -> Tuple[int, int]:
    return (round(p[0] * 1e5), round(p[1] * 1e5))


def _chain(segs) -> List[List[Tuple[float, float]]]:
    """Join segments end to end into polylines."""
    ends: Dict[Tuple[int, int], List[int]] = {}
    for n, (a, b) in enumerate(segs):
        ends.setdefault(_key(a), []).append(n)
        ends.setdefault(_key(b), []).append(n)
    used = [False] * len(segs)
    lines = []
    for n in range(len(segs)):
        if used[n]:
            continue
        used[n] = True
        a, b = segs[n]
        line = [a, b]
        for direction in (1, -1):
            while True:
                tip = line[-1] if direction == 1 else line[0]
                nxt = next((m for m in ends.get(_key(tip), []) if not used[m]), None)
                if nxt is None:
                    break
                used[nxt] = True
                sa, sb = segs[nxt]
                other = sb if _key(sa) == _key(tip) else sa
                if direction == 1:
                    line.append(other)
                else:
                    line.insert(0, other)
        if len(line) >= 3:
            lines.append([(round(p[0], 4), round(p[1], 4)) for p in line])
    return lines


def extrema(g: Optional[Grid], min_abs: float = EXTREMUM_MIN,
            radius: int = EXTREMUM_RADIUS_CELLS) -> List[FieldExtremum]:
    """H (local maximum) and L (local minimum) marks of a gridded field, the
    way the NWS isallobar chart labels its centers. A cell qualifies when it
    beats every neighbor within `radius` cells and |value| >= min_abs."""
    if g is None:
        return []
    out: List[FieldExtremum] = []
    v = g.values
    # Cells within `radius` of the grid edge can't be judged (their
    # neighborhood is cut off) and the edge lies outside the requested box
    # anyway, so they never become marks.
    for j in range(radius, g.ny - radius):
        for i in range(radius, g.nx - radius):
            c = v[j][i]
            if c is None or abs(c) < min_abs:
                continue
            is_max = is_min = True
            for dj in range(-radius, radius + 1):
                for di in range(-radius, radius + 1):
                    if dj == 0 and di == 0:
                        continue
                    jj, ii = j + dj, i + di
                    if 0 <= jj < g.ny and 0 <= ii < g.nx:
                        n = v[jj][ii]
                        if n is None:
                            continue
                        if n >= c:
                            is_max = False
                        if n <= c:
                            is_min = False
                    if not is_max and not is_min:
                        break
                if not is_max and not is_min:
                    break
            if (is_max and c > 0) or (is_min and c < 0):
                out.append(FieldExtremum(kind="H" if is_max else "L",
                                         lat=round(g.lat0 + j * g.dlat, 3),
                                         lon=round(g.lon0 + i * g.dlon, 3),
                                         value=round(c, 1)))
    return out


def to_grid_out(g: Optional[Grid], digits: int = 1) -> Optional[GridOut]:
    """The gridded field itself, for the app's shaded overlay. None cells
    become null; values rounded to keep the payload small (a tenth is
    plenty for shading; the timeline's grids, which the app contours and
    slides between, carry a hundredth)."""
    if g is None:
        return None
    return GridOut(lat0=g.lat0, lon0=g.lon0, dlat=g.dlat, dlon=g.dlon, ny=g.ny, nx=g.nx,
                   values=[[None if v is None else round(v, digits) for v in row] for row in g.values])


def isobar_step(g: Optional[Grid]) -> float:
    """Standard 4 hPa spacing; on a flat day (range under 8 hPa) the 2 hPa
    intermediates too, so the map still shows the gradient."""
    vals = [x for row in g.values for x in row if x is not None] if g is not None else []
    return ISOBAR_STEP if not vals or (max(vals) - min(vals)) >= 8.0 else ISOBAR_STEP / 2


def isobar_lines(g: Optional[Grid], step: Optional[float] = None, digits: Optional[int] = None) -> List[ContourLine]:
    """The isobars of a gridded pressure field. `step` fixes the spacing
    (a run of frames shares one, or lines would come and go between them);
    `digits` rounds the points for a payload that carries many frames."""
    if g is None:
        return []
    vals = [x for row in g.values for x in row if x is not None]
    if not vals:
        return []
    step = step or isobar_step(g)
    out: List[ContourLine] = []
    level = math.floor(min(vals) / step) * step
    hi = math.ceil(max(vals) / step) * step
    while level <= hi:
        for line in contour(g, level):
            pts = [[p[0], p[1]] if digits is None else [round(p[0], digits), round(p[1], digits)] for p in line]
            out.append(ContourLine(level=level, points=pts))
        level += step
    return out


def slp_points(points: Sequence[Tuple[float, float, Optional[float]]], lat: float, lon: float,
               lat_span: float, lon_span: float) -> List[Tuple[float, float, float]]:
    """The (lat, lon, sea-level hPa) points that shape a region's field:
    inside the box and its margin, plausible, outliers dropped."""
    half_lat, half_lon = lat_span / 2 + MARGIN_DEG, lon_span / 2 + MARGIN_DEG
    return _reject_outliers(
        [(la, lo, v) for (la, lo, v) in points
         if v is not None and SLP_MIN <= v <= SLP_MAX
         and abs(la - lat) <= half_lat and abs(lo - lon) <= half_lon],
        OUTLIER_HPA)


def pressure_grid(points: Sequence[Tuple[float, float, Optional[float]]], lat: float, lon: float,
                  lat_span: float, lon_span: float) -> Optional[Grid]:
    """Sea-level pressure gridded over a region, as build() grids it."""
    return grid_field(slp_points(points, lat, lon, lat_span, lon_span), lat, lon, lat_span, lon_span,
                      ISOBAR_RADIUS_KM)


def build(table: Sequence[StationObs], lat: float, lon: float,
          lat_span: float, lon_span: float,
          tend_pts: Optional[Sequence[Tuple[float, float, float]]] = None,
          ) -> Tuple[List[ContourLine], List[ContourLine], Optional[GridOut], Optional[GridOut], List[FieldExtremum]]:
    """(isobars, isallobars, pressure grid, tendency grid, tendency H/L) for the region.
    `tend_pts` (lat, lon, hPa per 3 h) normally come from the server's
    snapshot history; the bulk file's own tendency column is nearly empty
    outside synoptic hours, so it's only the fallback."""
    half_lat, half_lon = lat_span / 2 + MARGIN_DEG, lon_span / 2 + MARGIN_DEG
    cos_lat = max(0.2, math.cos(math.radians(lat)))
    inside = [s for s in table
              if abs(s.lat - lat) <= half_lat and abs(s.lon - lon) * cos_lat <= half_lon * cos_lat]
    slp_pts = slp_points([(s.lat, s.lon, s.slp) for s in inside], lat, lon, lat_span, lon_span)
    if tend_pts is None:
        tend_pts = [(s.lat, s.lon, s.presTend) for s in inside
                    if s.presTend is not None and abs(s.presTend) <= 15]
    tend_pts = _reject_outliers(
        [(la, lo, v) for (la, lo, v) in tend_pts
         if abs(la - lat) <= half_lat and abs(lo - lon) <= half_lon and abs(v) <= 15],
        OUTLIER_TEND)

    g = grid_field(slp_pts, lat, lon, lat_span, lon_span, ISOBAR_RADIUS_KM)
    isobars = isobar_lines(g)

    isallobars: List[ContourLine] = []
    g2 = grid_field(tend_pts, lat, lon, lat_span, lon_span, ISALLOBAR_RADIUS_KM)
    if g2 is not None:
        vals = [x for row in g2.values for x in row if x is not None]
        if vals:
            lo = math.floor(min(vals) / ISALLOBAR_STEP) * ISALLOBAR_STEP
            hi = math.ceil(max(vals) / ISALLOBAR_STEP) * ISALLOBAR_STEP
            level = lo
            while level <= hi:
                if abs(level) >= ISALLOBAR_STEP / 2:          # no zero line
                    for line in contour(g2, level):
                        isallobars.append(ContourLine(level=level, points=[[p[0], p[1]] for p in line]))
                level += ISALLOBAR_STEP
    return isobars, isallobars, to_grid_out(g), to_grid_out(g2), extrema(g2)
