"""Front watch — regional isallobaric analysis (the "front arrival ETA" feature).

The app's thesis, applied sideways: one station's falling pressure says something
is coming; a RING of stations says where it is and which way it's sliding. We take
every METAR in a box around the user's station, compute each station's own 3-hour
pressure delta, and fit a plane to that tendency field. A coherent gradient with
real falls on one side is the observational signature of an approaching change.

Division of labor, stated plainly in the copy so neither half borrows the other's
credibility:
  - DIRECTION comes from observations (the tendency-field gradient).
  - TIMING comes from the model (the interpreter's trough time on the merged
    observed+forecast curve) — surface obs alone don't give a speed in v1.

Statuses:
  approaching  coherent falls upstream, we're not rising -> change headed this way
  passed       coherent falls downstream while we rise -> it moved through
  passing      the interpreter says the trough is on us right now
  forecast     the model expects a trough but nearby stations don't confirm yet
  none         quiet field (the client renders nothing)
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Sequence, Tuple

from .models import FrontResponse, FrontStationOut

# --- Tunables ----------------------------------------------------------------

MIN_RING_STATIONS = 5     # fewer reporting stations than this -> no spatial call
MAX_RING_KM = 240.0       # ignore stations beyond this (different weather regime)
MIN_COHERENCE = 0.30      # plane-fit R² below this = incoherent scatter, no call
MIN_GRADIENT = 0.5        # hPa/3h per 100 km — weaker than this isn't a pattern
MIN_FALL = -1.0           # somebody in the ring must actually be falling this hard
RISING_BEHIND = 0.5       # own delta at/above this + falls downstream = "passed"
MAX_COMPASS_STATIONS = 24 # payload cap for the client's compass view

# Per-station 3h delta extraction
SPAN_MIN_H = 2.0          # accept an ob pair spanning 2-4h, scaled to /3h
SPAN_MAX_H = 4.0
STALE_OB_MIN = 90.0       # newest ob older than this -> station excluded
MAX_ABS_DELTA = 8.0       # |delta| beyond this is a broken sensor, not weather

KM_PER_DEG_LAT = 111.32

_CARDINALS = [
    "north", "northeast", "east", "southeast",
    "south", "southwest", "west", "northwest",
]


def cardinal(bearing_deg: float) -> str:
    return _CARDINALS[int(((bearing_deg % 360.0) + 22.5) // 45) % 8]


@dataclass(frozen=True)
class RingStation:
    id: str
    bearing_deg: float   # compass bearing from the user's station (0 = north)
    distance_km: float
    delta3h: float       # this station's OWN 3h pressure change (hPa)


# --- Per-station tendency ----------------------------------------------------


def _delta3h(series: Sequence, now: datetime) -> Optional[float]:
    """A station's own 3h pressure change from its METAR series.

    Prefers SLP; falls back to altimeter (fine for a delta — elevation is
    constant). Both ends of the pair must come from the SAME field so a
    station that reports SLP intermittently can't fake a jump. The pair may
    span 2-4h (AWOS cadence varies); the delta is scaled to a per-3h rate.
    """
    for field in ("slp", "altim"):
        vals = [(p.t, getattr(p, field)) for p in series if getattr(p, field) is not None]
        if len(vals) < 2:
            continue
        t_new, v_new = vals[-1]
        if (now - t_new).total_seconds() / 60.0 > STALE_OB_MIN:
            continue
        target = t_new - timedelta(hours=3.0)
        t_old, v_old = min(vals[:-1], key=lambda x: abs((x[0] - target).total_seconds()))
        span_h = (t_new - t_old).total_seconds() / 3600.0
        if not (SPAN_MIN_H <= span_h <= SPAN_MAX_H):
            continue
        d = (v_new - v_old) / span_h * 3.0
        if abs(d) > MAX_ABS_DELTA:
            return None
        return round(d, 2)
    return None


def ring_stations(
    parsed: Dict[str, dict],
    *,
    origin_lat: float,
    origin_lon: float,
    exclude: str,
    now: datetime,
) -> List[RingStation]:
    """Turn a parse_records() dict (from a bbox fetch) into the tendency ring."""
    out: List[RingStation] = []
    cos_lat = math.cos(math.radians(origin_lat))
    for sid, p in parsed.items():
        if sid == exclude:
            continue
        lat, lon = p.get("lat"), p.get("lon")
        if lat is None or lon is None:
            continue
        dx = (lon - origin_lon) * KM_PER_DEG_LAT * cos_lat  # km east
        dy = (lat - origin_lat) * KM_PER_DEG_LAT            # km north
        dist = math.hypot(dx, dy)
        if dist > MAX_RING_KM:
            continue
        d = _delta3h(p.get("series", []), now)
        if d is None:
            continue
        bearing = (math.degrees(math.atan2(dx, dy)) + 360.0) % 360.0
        out.append(RingStation(id=sid, bearing_deg=round(bearing, 1),
                               distance_km=round(dist, 1), delta3h=d))
    out.sort(key=lambda s: s.distance_km)
    return out[:MAX_COMPASS_STATIONS]


# --- Plane fit ---------------------------------------------------------------


def _plane_fit(pts: Sequence[Tuple[float, float, float]]) -> Optional[Tuple[float, float, float]]:
    """Least-squares plane d = a + gx·x + gy·y over (x_km, y_km, delta3h) points.

    Returns (gx, gy, R²) — the tendency gradient in hPa/3h per km — or None when
    the geometry is degenerate (too few points / collinear stations).
    """
    n = len(pts)
    if n < 3:
        return None
    sx = sum(p[0] for p in pts)
    sy = sum(p[1] for p in pts)
    sd = sum(p[2] for p in pts)
    sxx = sum(p[0] * p[0] for p in pts)
    syy = sum(p[1] * p[1] for p in pts)
    sxy = sum(p[0] * p[1] for p in pts)
    sxd = sum(p[0] * p[2] for p in pts)
    syd = sum(p[1] * p[2] for p in pts)

    # Normal equations, solved by Cramer's rule (same approach as the client's
    # range-analysis tide fit — small, exact, no dependencies).
    det = (n * (sxx * syy - sxy * sxy)
           - sx * (sx * syy - sxy * sy)
           + sy * (sx * sxy - sxx * sy))
    if abs(det) < 1e-9:
        return None
    a = (sd * (sxx * syy - sxy * sxy)
         - sx * (sxd * syy - sxy * syd)
         + sy * (sxd * sxy - sxx * syd)) / det
    gx = (n * (sxd * syy - sxy * syd)
          - sd * (sx * syy - sxy * sy)
          + sy * (sx * syd - sxd * sy)) / det
    gy = (n * (sxx * syd - sxd * sxy)
          - sx * (sx * syd - sxd * sy)
          + sd * (sx * sxy - sxx * sy)) / det

    mean = sd / n
    ss_tot = sum((p[2] - mean) ** 2 for p in pts)
    if ss_tot <= 0:
        return None
    ss_res = sum((p[2] - (a + gx * p[0] + gy * p[1])) ** 2 for p in pts)
    r2 = max(0.0, 1.0 - ss_res / ss_tot)
    return gx, gy, r2


# --- Narrative ---------------------------------------------------------------


def _join(ids: Sequence[str]) -> str:
    if len(ids) >= 2:
        return f"{ids[0]} and {ids[1]}"
    return ids[0]


def _copy(status: str, direction: Optional[str], strongest: Sequence[str]) -> Tuple[Optional[str], Optional[str]]:
    if status == "approaching":
        where = f" from the {direction}" if direction else ""
        at = f" at {_join(strongest)}" if strongest else " at stations nearby"
        return (
            f"Change moving in{where}",
            f"Pressure is falling{at}. The falls are spreading in"
            f"{where}, and this kind of pattern usually brings the weather with it.",
        )
    if status == "passed":
        where = f" to the {direction}" if direction else " downstream"
        return (
            "The change moved through",
            f"Pressure is rising here while stations{where} are still falling. "
            "Whatever came through looks to be moving away.",
        )
    if status == "passing":
        return (
            "Low point is on you",
            "Pressure here is bottoming out now. Wind shifts and any weather "
            "usually ride through with the trough over the next few hours.",
        )
    if status == "forecast":
        return (
            "Trough in the forecast",
            "The model expects a pressure dip here, but nearby stations aren't "
            "showing coherent falls yet. Treat the timing as a guess until the "
            "falls show up.",
        )
    return None, None


# --- Main entry --------------------------------------------------------------


def analyze(
    *,
    station: str,
    ring: Sequence[RingStation],
    own_delta3h: Optional[float],
    reading,
    now: datetime,
) -> FrontResponse:
    """Classify the regional tendency field into a FrontResponse.

    `reading` is the interpreter's Reading for the user's station (or None); its
    trough feature supplies the ETA and the "passing right now" signal.
    """
    feature = reading.feature if reading is not None else "none"
    eta = None
    if reading is not None and reading.featureTime is not None and feature in (
        "approaching_trough", "trough_passing",
    ):
        eta = reading.featureTime

    # Tendency field: ring stations at their offsets, own station at the origin.
    pts = [
        (s.distance_km * math.sin(math.radians(s.bearing_deg)),
         s.distance_km * math.cos(math.radians(s.bearing_deg)),
         s.delta3h)
        for s in ring
    ]
    if own_delta3h is not None:
        pts.append((0.0, 0.0, own_delta3h))

    fit = _plane_fit(pts) if len(ring) >= MIN_RING_STATIONS else None
    gradient = coherence = falls_bearing = None
    if fit is not None:
        gx, gy, r2 = fit
        coherence = round(r2, 2)
        mag = math.hypot(gx, gy)
        gradient = round(mag * 100.0, 2)  # hPa/3h per 100 km
        if mag > 1e-6:
            # The gradient points toward rises; the falls (and the front that
            # rides them) lie the other way.
            falls_bearing = round((math.degrees(math.atan2(-gx, -gy)) + 360.0) % 360.0, 1)

    min_fall = min((s.delta3h for s in ring), default=None)
    strongest = [s.id for s in sorted(ring, key=lambda s: s.delta3h)[:2] if s.delta3h <= MIN_FALL]

    obs_ok = (
        fit is not None
        and falls_bearing is not None
        and coherence >= MIN_COHERENCE
        and gradient >= MIN_GRADIENT
        and min_fall is not None
        and min_fall <= MIN_FALL
    )

    if feature == "trough_passing":
        status = "passing"
    elif obs_ok and own_delta3h is not None and own_delta3h >= RISING_BEHIND:
        status = "passed"
    elif obs_ok:
        status = "approaching"
    elif feature == "approaching_trough" and eta is not None:
        status = "forecast"
    else:
        status = "none"

    # A direction is only worth stating when the field is coherent — a low-R²
    # gradient still has *some* bearing, but it's noise wearing a compass.
    if not obs_ok:
        falls_bearing = None
    direction = cardinal(falls_bearing) if falls_bearing is not None else None
    headline, detail = _copy(status, direction, strongest)

    if status == "none":
        return FrontResponse(station=station, status="none", cachedAt=now)

    return FrontResponse(
        station=station,
        status=status,
        headline=headline,
        detail=detail,
        bearingDeg=falls_bearing,
        cardinal=direction,
        eta=eta,
        maxFall3h=min_fall,
        ownDelta3h=own_delta3h,
        gradient=gradient,
        coherence=coherence,
        stations=[
            FrontStationOut(id=s.id, bearingDeg=s.bearing_deg,
                            distanceKm=s.distance_km, tendency3h=s.delta3h)
            for s in ring
        ],
        cachedAt=now,
    )
