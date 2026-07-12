"""Front watch — regional isallobaric analysis (the "front arrival ETA" feature).

The app's thesis, applied sideways: a RING of stations says where a pressure
change is and which way it's sliding. We take every METAR in a box around the
user's station, compute each station's own 3-hour delta, and read the field two
ways: a plane fit for the large-scale tilt, and the motion of the fall-weighted
centroid between two epochs for how the pattern is actually moving.

Division of labor, stated plainly in the copy so neither half borrows the other's
credibility:
  - DETECTION belongs to the user's own tendency (the hero). The backtest
    (backend/backtest/RESULTS.md) showed the ring adds no detection skill over
    the center station's own fall, so "approaching" REQUIRES the local fall and
    the ring only explains it.
  - DIRECTION comes from observations: the centroid track when the pattern's
    motion is measurable, else the gradient when the fit is coherent, else the
    banner honestly says the direction isn't clear. Measured accuracy is about
    a compass quadrant — the copy says "roughly" and means it.
  - TIMING comes from the model (the interpreter's trough time). The
    observational ETA candidate (centroid closing speed) ran ~6 h early in the
    backtest, because falls lead the trough itself; it was not shipped.

POLICY: front statuses are banner-grade evidence (roughly 6 in 10 preceded a
real pressure dip within a day in a year of Ohio Valley replay). They must
NEVER feed notifications/StormAlerter — alerts stay on the own-tendency signal.

Statuses:
  approaching  falling here AND a coherent regional fall pattern -> context
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

# --- Tunables (thresholds backtested — see backend/backtest/RESULTS.md) -------

MIN_RING_STATIONS = 5     # fewer reporting stations than this -> no spatial call
MAX_RING_KM = 240.0       # ignore stations beyond this (different weather regime)
MIN_COHERENCE = 0.30      # plane-fit R² floor for a GRADIENT direction claim only
MIN_GRADIENT = 0.3        # hPa/3h per 100 km. 0.5 missed a quarter of southern-
                          # plains frontal troughs (sharp mesoscale patterns fit
                          # to a weak plane over 240 km); 0.3 catches them and
                          # held up in all five backtest climates
MIN_FALL = -1.5           # somebody in the ring must actually be falling this
                          # hard (was -1.0; the deeper bar buys back the FAR and
                          # duty that the lower gradient threshold would cost)
OWN_FALL_MAX = -0.5       # "approaching" requires the center itself falling —
                          # detection stays the hero's job, the ring explains it
RISING_BEHIND = 0.5       # own delta at/above this + falls downstream = "passed"
MAX_COMPASS_STATIONS = 24 # payload cap for the client's compass view

# Centroid track (direction v2): the fall-weighted centroid's motion between two
# epochs. Backtest: 59 deg median error inside 3 h of arrival where the gradient
# reads 132 deg — and the mirror image far out, hence track-first with gradient
# fallback.
TRACK_LAG_H = 4.0         # epoch spacing; needs an hours>=8 bbox fetch
TRACK_MIN_SHIFT_KM = 15.0 # less displacement than this is wobble, not motion
CENTROID_MIN_WEIGHT = 1.5 # total fall-weight below this = no real fall region

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
    at: Optional[datetime] = None,
) -> List[RingStation]:
    """Turn a parse_records() dict (from a bbox fetch) into the tendency ring.

    `at` evaluates the ring as of an earlier epoch (only obs at/before it, with
    staleness judged against it) — the second sample the centroid track needs,
    carved from the same bbox response instead of server-side state.
    """
    epoch = at if at is not None else now
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
        series = [pt for pt in p.get("series", []) if pt.t <= epoch]
        d = _delta3h(series, epoch)
        if d is None:
            continue
        bearing = (math.degrees(math.atan2(dx, dy)) + 360.0) % 360.0
        out.append(RingStation(id=sid, bearing_deg=round(bearing, 1),
                               distance_km=round(dist, 1), delta3h=d))
    out.sort(key=lambda s: s.distance_km)
    return out[:MAX_COMPASS_STATIONS]


def _xy(s: RingStation) -> Tuple[float, float]:
    rad = math.radians(s.bearing_deg)
    return s.distance_km * math.sin(rad), s.distance_km * math.cos(rad)


def fall_centroid(ring: Sequence[RingStation]) -> Optional[Tuple[float, float]]:
    """Fall-weighted centroid of the ring — where the falling air 'is'.
    Weight = how far below -0.5 hPa/3h a station sits; too little total weight
    means there's no real fall region to locate."""
    wx = wy = wsum = 0.0
    for s in ring:
        w = max(0.0, -s.delta3h - 0.5)
        if w <= 0.0:
            continue
        x, y = _xy(s)
        wx += w * x
        wy += w * y
        wsum += w
    if wsum < CENTROID_MIN_WEIGHT:
        return None
    return wx / wsum, wy / wsum


def _bearing(dx: float, dy: float) -> float:
    return (math.degrees(math.atan2(dx, dy)) + 360.0) % 360.0


def track_bearing(ring: Sequence[RingStation],
                  ring_prev: Sequence[RingStation]) -> Optional[float]:
    """'Coming from' bearing from the fall centroid's motion between the two
    epochs. None when either centroid is missing or the displacement is within
    wobble range — in which case the gradient (or silence) takes over."""
    c1 = fall_centroid(ring)
    c0 = fall_centroid(ring_prev)
    if c1 is None or c0 is None:
        return None
    mx, my = c1[0] - c0[0], c1[1] - c0[1]
    if math.hypot(mx, my) < TRACK_MIN_SHIFT_KM:
        return None
    return round(_bearing(-mx, -my), 1)


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


# Honest odds line, from the backtest (backend/backtest/RESULTS.md): in a year
# of Ohio Valley replay, ~6 in 10 of these calls preceded a real pressure dip
# within a day. One region, one year — hence "roughly".
_ODDS = ("In testing, roughly six of ten patterns like this brought a real "
         "pressure dip within a day. The rest slid past or fizzled.")


def _copy(status: str, direction: Optional[str], strongest: Sequence[str]) -> Tuple[Optional[str], Optional[str]]:
    if status == "approaching":
        at = f" at {_join(strongest)}" if strongest else " at stations nearby"
        if direction:
            return (
                f"Change moving in from the {direction}",
                f"Pressure is falling here and{at}. The pattern is sliding in "
                f"roughly from the {direction}. {_ODDS}",
            )
        return (
            "Pressure falling across the area",
            f"Pressure is falling here and{at}, but which way the pattern is "
            f"moving isn't clear from the station field yet. {_ODDS}",
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
    ring_prev: Sequence[RingStation] = (),
) -> FrontResponse:
    """Classify the regional tendency field into a FrontResponse.

    `reading` is the interpreter's Reading for the user's station (or None); its
    trough feature supplies the ETA and the "passing right now" signal.
    `ring_prev` is the same ring evaluated TRACK_LAG_H earlier — it powers the
    centroid track; without it direction falls back to the gradient.
    """
    feature = reading.feature if reading is not None else "none"
    eta = None
    if reading is not None and reading.featureTime is not None and feature in (
        "approaching_trough", "trough_passing",
    ):
        eta = reading.featureTime

    # Tendency field: ring stations at their offsets, own station at the origin.
    pts = [(*_xy(s), s.delta3h) for s in ring]
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
            falls_bearing = round(_bearing(-gx, -gy), 1)

    min_fall = min((s.delta3h for s in ring), default=None)
    strongest = [s.id for s in sorted(ring, key=lambda s: s.delta3h)[:2] if s.delta3h <= MIN_FALL]

    # Is there a real regional fall pattern at all? (Coherence deliberately NOT
    # in this gate — the backtest showed it filters nothing here. It survives
    # below as a floor for gradient-based direction claims only.)
    regional_falls = (
        len(ring) >= MIN_RING_STATIONS
        and gradient is not None and gradient >= MIN_GRADIENT
        and min_fall is not None and min_fall <= MIN_FALL
    )

    if feature == "trough_passing":
        status = "passing"
    elif regional_falls and own_delta3h is not None and own_delta3h >= RISING_BEHIND:
        status = "passed"
    elif regional_falls and own_delta3h is not None and own_delta3h <= OWN_FALL_MAX:
        # Detection stays the hero's job: the ring only explains a fall the
        # user's own station is already showing.
        status = "approaching"
    elif feature == "approaching_trough" and eta is not None:
        status = "forecast"
    else:
        status = "none"

    # Direction, by measured reliability: the centroid track when the pattern's
    # motion is real; else the gradient, but only while the plane fit is
    # coherent; else say nothing rather than guess (a late-stage gradient
    # bearing backtested WORSE than random).
    bearing = None
    if status == "approaching":
        bearing = track_bearing(ring, ring_prev)
        if bearing is None and coherence is not None and coherence >= MIN_COHERENCE:
            bearing = falls_bearing
    elif status == "passed":
        # "Where are the falls now" — the centroid's position beats a plane
        # fit for pointing at the departing fall region.
        c = fall_centroid(ring)
        if c is not None:
            bearing = round(_bearing(c[0], c[1]), 1)
        elif coherence is not None and coherence >= MIN_COHERENCE:
            bearing = falls_bearing

    direction = cardinal(bearing) if bearing is not None else None
    headline, detail = _copy(status, direction, strongest)

    if status == "none":
        return FrontResponse(station=station, status="none", cachedAt=now)

    return FrontResponse(
        station=station,
        status=status,
        headline=headline,
        detail=detail,
        bearingDeg=bearing,
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
