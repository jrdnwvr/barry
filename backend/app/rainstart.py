"""When rain reaches a point: the "rain starts at" line.

From the newest MRMS rain-rate grid (PrecipRate: every two minutes, mm/h
at the ground from the hybrid scan with the reflectivity relation chosen
per precipitation type, so a bright band or hail aloft does not count as
rain) and the motion the radar nowcast finds between the last two
composites. The rain that will be over a point in t minutes is the rain
now t minutes upstream along that motion, so the point is traced back
through the motion field two minutes at a time, up to ninety, and the
first step that lands in rain is when it starts; a point in rain now is
traced the same way for when it clears. Extrapolation knows nothing of
growth or decay, which is why the horizon is short: light rain
extrapolates well to about two hours and heavy rain to about 45 minutes
(Pulkkinen et al. 2019). Every "starts at" call is kept and scored against
what the radar then showed (service._score_rain_calls, /models/scores).
"""

from __future__ import annotations

import math
from datetime import datetime, timedelta
from typing import Optional, Tuple

import numpy as np

from . import radar
from .models import RainOut
from .sources.mrms import RATE_STEP_MMH

ON_MMH = 0.2                # rain reaching the ground; MRMS reports to 0.1
LIGHT_MAX_MMH = 2.5         # NWS: light under 2.5 mm/h, moderate to 7.6, heavy above
MODERATE_MAX_MMH = 7.6
MAX_MIN = 90
STEP_MIN = 2
CLEAR_MIN = 20              # dry this long after rain counts as clearing
RADIUS = 2                  # grid points each way: a 5 by 5 window, about 5 km on the MRMS grid
MIN_SPEED_KMH = 3.0         # slower than this the echo is going nowhere we can time
KM_PER_DEG = 111.2
MI_PER_KM = 0.621371

_CARDINALS = ("north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest")


def cardinal(bearing_deg: float) -> str:
    return _CARDINALS[int(((bearing_deg % 360.0) + 22.5) // 45) % 8]


def intensity(mmh: float) -> str:
    return "light" if mmh < LIGHT_MAX_MMH else "moderate" if mmh < MODERATE_MAX_MMH else "heavy"


def _window_max(codes: np.ndarray, r: float, c: float) -> Optional[float]:
    """The strongest rate, mm/h, within RADIUS points of a grid position;
    None off the grid."""
    ri, ci = int(round(r)), int(round(c))
    h, w = codes.shape
    if not (0 <= ri < h and 0 <= ci < w):
        return None
    win = codes[max(0, ri - RADIUS):ri + RADIUS + 1, max(0, ci - RADIUS):ci + RADIUS + 1]
    return float(win.max()) * RATE_STEP_MMH


def outlook(codes: np.ndarray, grid: dict, vy: np.ndarray, vx: np.ndarray,
            lat: float, lon: float, now: datetime, as_of: datetime) -> Optional[RainOut]:
    """Rain at (lat, lon) now or within MAX_MIN minutes, or None. `codes`
    is the rain-rate grid (tenths of mm/h), `vy`/`vx` the block motion
    from radar.motion (pooled points per frame step), `as_of` the grid's
    time, which the trace starts from."""
    dlat, dlon = float(grid["dlat"]), float(grid["dlon"])
    r0 = (float(grid["lat0"]) + dlat / 2 - lat) / dlat
    c0 = (lon - (float(grid["lon0"]) - dlon / 2)) / dlon
    here = _window_max(codes, r0, c0)
    if here is None:
        return None
    scale = radar.BLOCK * 2 ** radar.MOTION_LEVEL              # full-resolution points per motion block
    per_min = 2 ** radar.MOTION_LEVEL / (radar.RadarStore.STEP_S / 60.0)   # pooled points a step -> points a minute
    nby, nbx = vy.shape
    coslat = math.cos(math.radians(lat))

    def motion_at(r: float, c: float) -> Tuple[float, float]:
        br = min(max(int(r // scale), 0), nby - 1)
        bc = min(max(int(c // scale), 0), nbx - 1)
        return float(vy[br, bc]) * per_min, float(vx[br, bc]) * per_min      # rows, cols per minute

    def kmh(vr: float, vc: float) -> float:
        return math.hypot(vr * dlat * KM_PER_DEG, vc * dlon * KM_PER_DEG * coslat) * 60.0

    def heading(vr: float, vc: float) -> float:
        # Rows grow southward, so north is -vr.
        return math.degrees(math.atan2(vc * dlon * coslat, -vr * dlat)) % 360.0

    vr0, vc0 = motion_at(r0, c0)
    speed0 = kmh(vr0, vc0)
    raining = here >= ON_MMH
    if not raining and speed0 < MIN_SPEED_KMH:
        return None

    r, c, t = r0, c0, 0
    start: Optional[int] = None
    start_pos: Optional[Tuple[float, float]] = None
    end: Optional[int] = None
    peak = here if raining else 0.0
    dry = 0
    while t < MAX_MIN:
        vr, vc = motion_at(r, c)
        r -= vr * STEP_MIN
        c -= vc * STEP_MIN
        t += STEP_MIN
        rate = _window_max(codes, r, c)
        if rate is None:
            break
        if not raining and start is None:
            if rate >= ON_MMH:
                start, start_pos, peak = t, (r, c), rate
            continue
        since = t - (start or 0)
        if rate >= ON_MMH:
            dry = 0
            if since <= CLEAR_MIN:
                peak = max(peak, rate)
        else:
            dry += STEP_MIN
            if dry >= CLEAR_MIN:
                end = t - dry + STEP_MIN
                break
    if not raining and start is None:
        return None

    moving = cardinal(heading(vr0, vc0)) if speed0 >= MIN_SPEED_KMH else None
    mph = int(round(speed0 * MI_PER_KM)) if moving else None
    ends_at = as_of + timedelta(minutes=end) if end is not None else None
    if ends_at is not None and ends_at <= now:
        ends_at = None
    tail = " Clearing by about {end}." if ends_at is not None else ""
    word = intensity(peak).capitalize()
    if raining:
        motion_txt = f"moving {moving} at {mph} mph" if moving else "nearly stationary"
        return RainOut(status="now", endsAt=ends_at, intensity=intensity(peak), moving=moving,
                       speedMph=mph, detail=f"{word} rain here, {motion_txt}.{tail}",
                       asOf=as_of)
    rs, cs = start_pos
    lat_s = float(grid["lat0"]) + dlat / 2 - rs * dlat
    lon_s = float(grid["lon0"]) - dlon / 2 + cs * dlon
    dy_km, dx_km = (lat_s - lat) * KM_PER_DEG, (lon_s - lon) * KM_PER_DEG * coslat
    dist_mi = math.hypot(dy_km, dx_km) * MI_PER_KM
    frm = cardinal(math.degrees(math.atan2(dx_km, dy_km)))
    where = f"{int(round(dist_mi))} mi to the {frm}" if dist_mi >= 1.5 else f"just to the {frm}"
    starts_at = max(now, as_of + timedelta(minutes=start))
    return RainOut(status="soon", startsAt=starts_at, endsAt=ends_at, intensity=intensity(peak),
                   distanceMi=int(round(dist_mi)), fromCardinal=frm, moving=moving, speedMph=mph,
                   detail=f"{word} rain {where}, moving {moving} at {mph} mph.{tail}", asOf=as_of)
