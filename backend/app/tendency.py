"""3-hour pressure tendency: classification + continuous intensity.

This is the single source of truth for tendency thresholds on the Python side.
The Swift apps mirror these constants in Shared/Tendency.swift — keep the two in
sync by hand (there is intentionally no codegen; the table is small and stable).

See the project brief §4.1 for the canonical table.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Optional, Sequence

# --- Classification thresholds (hPa per 3 hours, signed; negative = falling) ---
#
#   d >= +1.5          rising_fast    green
#   +0.5 <= d < +1.5   rising         light green
#   -0.5 <  d < +0.5   steady         neutral/gray
#   -1.5 <  d <= -0.5  falling        pale amber
#   -3.0 <  d <= -1.5  falling_mod    amber
#   d <= -3.0          falling_fast   deep red
RISING_FAST = 1.5
RISING = 0.5
STEADY = -0.5
FALLING = -1.5
FALLING_MOD = -3.0

# Intensity gradient band: |d| is mapped from FALL_MIN -> FALL_MAX onto 0.0 -> 1.0
# (pale amber -> deep red), clamped outside that range. At the falling threshold
# (1.5 hPa) intensity is 0.0; at 4.0 hPa and beyond it is 1.0. This matches the
# brief's "pale amber at -1.5 -> deep red at -4+" intent.
#
# NOTE: the brief's example JSON shows delta3h -2.4 -> intensity 0.6, which is
# |d|/4.0 rather than this banded mapping ((2.4-1.5)/2.5 = 0.36). We use the
# banded mapping because it expresses the stated design intent (0 at the band
# floor, 1 at the band ceiling) and gives the complication a usable dynamic range
# across the falling classes. If you'd rather match the example literally, set
# INTENSITY_FLOOR = 0.0.
INTENSITY_FLOOR = 1.5
INTENSITY_CEIL = 4.0


@dataclass(frozen=True)
class Tendency:
    delta3h: float
    cls: str  # "class" is reserved; serialized as "class" in the API layer
    intensity: float


def classify(delta3h: float) -> str:
    """Map a signed 3-hour delta (hPa) to a tendency class."""
    d = delta3h
    if d >= RISING_FAST:
        return "rising_fast"
    if d >= RISING:
        return "rising"
    if d > STEADY:
        return "steady"
    if d > FALLING:
        return "falling"
    if d > FALLING_MOD:
        return "falling_mod"
    return "falling_fast"


def intensity(delta3h: float) -> float:
    """Continuous 0.0-1.0 magnitude for color intensity, based on |delta3h|.

    Mapped from INTENSITY_FLOOR..INTENSITY_CEIL hPa onto 0..1 and clamped.
    Returned for all classes; the complication only renders it for falling ones.
    """
    mag = abs(delta3h)
    span = INTENSITY_CEIL - INTENSITY_FLOOR
    raw = (mag - INTENSITY_FLOOR) / span
    return max(0.0, min(1.0, raw))


def tendency_from_delta(delta3h: float) -> Tendency:
    return Tendency(
        delta3h=round(delta3h, 2),
        cls=classify(delta3h),
        intensity=round(intensity(delta3h), 3),
    )


def delta3h_from_series(
    times: Sequence[datetime],
    values: Sequence[Optional[float]],
    *,
    now: Optional[datetime] = None,
    target_hours: float = 3.0,
    tolerance_hours: float = 1.5,
) -> Optional[float]:
    """Compute the 3-hour delta from a time series when presTend is unavailable.

    Returns (value at the most recent sample) - (value nearest ~3h before it).
    The earlier sample must fall within `tolerance_hours` of the target offset,
    otherwise we cannot honestly call it a 3-hour tendency and return None.

    `times`/`values` need not be sorted; None values are ignored.
    """
    pairs = [
        (t, v)
        for t, v in zip(times, values)
        if v is not None
    ]
    if len(pairs) < 2:
        return None
    pairs.sort(key=lambda p: p[0])

    latest_t, latest_v = pairs[-1]
    target_t = latest_t.timestamp() - target_hours * 3600.0

    best = None
    best_gap = None
    for t, v in pairs[:-1]:
        gap = abs(t.timestamp() - target_t)
        if best_gap is None or gap < best_gap:
            best_gap = gap
            best = (t, v)

    if best is None or best_gap is None:
        return None
    if best_gap > tolerance_hours * 3600.0:
        return None

    _, earlier_v = best
    return latest_v - earlier_v


def resolve_tendency(
    pres_tend: Optional[float],
    times: Sequence[datetime],
    values: Sequence[Optional[float]],
    *,
    now: Optional[datetime] = None,
) -> Optional[Tendency]:
    """Prefer the station-reported presTend; otherwise compute from the series.

    Returns None when neither source can produce an honest 3-hour delta.
    """
    if pres_tend is not None:
        return tendency_from_delta(pres_tend)
    delta = delta3h_from_series(times, values, now=now)
    if delta is None:
        return None
    return tendency_from_delta(delta)
