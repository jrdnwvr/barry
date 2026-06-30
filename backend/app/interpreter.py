"""Trend interpreter (brief §4.3) — pure rule-based pressure curve analysis.

Takes a mixed observed+forecast pressure time series and emits a structured
`Reading`: what the curve *means*, not just the latest tendency. The verdict
sentence, chart annotations, and complication intensity downstream all consume
this single result.

Deliberately I/O-free and stdlib-only so the same pipeline can be ported to
Swift verbatim and validated against the same fixtures (`tests/test_interpreter.py`).

Pipeline, in order (brief §4.3.2):
    resample (30 min) → de-tide (S2 sinusoid) → smooth (3-pt MA) →
    slope+steadiness (LSQ over trailing 3h) → derivative + feature scan →
    classify trend (shared §4.1 thresholds) → confidence + caveats.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import List, Optional, Sequence, Tuple

from .tendency import classify

# --- Pipeline tunables (module-level so tests can reason about them) --------

RESAMPLE_MIN = 30                  # even-cadence interpolation step
GAP_MIN = 120                       # spacing > this is a gap — never interpolate across
SMOOTH_K = 3                        # centered moving-average window (odd)
SLOPE_WINDOW_HOURS = 3.0            # trailing window for rate3h / steadiness
SHORT_WINDOW_HOURS = 3.0            # nominal trailing span the slope window targets
SHORT_WINDOW_MIN_HOURS = 2.0       # genuine recent coverage below this → "short_window"
SHORT_WINDOW_MIN_POINTS = 4        # ...or fewer than this many points in the slope window
KNEE_LOOKBACK_HOURS = 3.0           # only call knees within this much past
KNEE_RATIO = 3.0                    # |slope_after| / |slope_before| above this
KNEE_MIN_RATE = 0.7                 # post-knee slope must be at least this (hPa/h)
KNEE_MAX_BEFORE = 0.4               # pre-knee slope must be at most this (hPa/h)
RAPID_FALL_RATE = 1.0               # |hPa/h| over RAPID_FALL_HOURS = rapid_fall
RAPID_FALL_HOURS = 2.0
DIURNAL_AMPLITUDE_HPA = 1.2         # S2 sinusoid amplitude (brief §4.3.2)
DIURNAL_FLATNESS_HPA = 0.6          # de-tided range below this is "no real signal"
DIURNAL_CORR_MIN = 0.85             # raw↔tide correlation to call diurnal_only
TROUGH_NEAR_HOURS = 1.0             # zero crossing within this of now → trough_passing
RIDGE_NEAR_HOURS = 1.0              # same for ridge_peak
FORECAST_LEAD_HOURS = 1.0           # featureTime beyond now + this → forecast_derived


@dataclass(frozen=True)
class Sample:
    t: datetime
    p: float
    observed: bool = True


@dataclass(frozen=True)
class Reading:
    trend: str
    rate3h: float
    steadiness: float
    feature: str
    featureTime: Optional[datetime]
    confidence: float
    caveats: Tuple[str, ...] = ()


# --- Helpers ----------------------------------------------------------------


def _aware(t: datetime) -> datetime:
    return t if t.tzinfo is not None else t.replace(tzinfo=timezone.utc)


def tide(t: datetime, *, local_hour_offset: float = 0.0) -> float:
    """S2 semidiurnal atmospheric tide (brief §4.3.2): ~±1.2 hPa cosine peaking
    around 10am/10pm local solar time, troughing at 4am/4pm. Exact amplitude
    varies by latitude/season; we use a fixed first approximation."""
    h = t.hour + t.minute / 60.0 + t.second / 3600.0 + local_hour_offset
    phase = 2.0 * math.pi * (h - 10.0) / 12.0
    return DIURNAL_AMPLITUDE_HPA * math.cos(phase)


def _lsq(xs: Sequence[float], ys: Sequence[float]) -> Tuple[float, float, float]:
    """Linear least-squares fit y = a + b·x. Returns (a, b, R²)."""
    n = len(xs)
    if n < 2:
        return (ys[0] if ys else 0.0, 0.0, 0.0)
    mx = sum(xs) / n
    my = sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    if sxx <= 0:
        return (my, 0.0, 0.0)
    b = sxy / sxx
    a = my - b * mx
    syy = sum((y - my) ** 2 for y in ys)
    if syy <= 0:
        r2 = 1.0
    else:
        ss_res = sum((y - (a + b * x)) ** 2 for x, y in zip(xs, ys))
        r2 = max(0.0, 1.0 - ss_res / syy)
    return (a, b, r2)


def _slope(seg: Sequence[Sample]) -> float:
    if len(seg) < 2:
        return 0.0
    xs = [(s.t - seg[0].t).total_seconds() / 3600.0 for s in seg]
    ys = [s.p for s in seg]
    _, b, _ = _lsq(xs, ys)
    return b


def _correlation(xs: Sequence[float], ys: Sequence[float]) -> float:
    n = len(xs)
    if n < 2:
        return 0.0
    mx = sum(xs) / n
    my = sum(ys) / n
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    dx = math.sqrt(sum((x - mx) ** 2 for x in xs))
    dy = math.sqrt(sum((y - my) ** 2 for y in ys))
    if dx == 0 or dy == 0:
        return 0.0
    return num / (dx * dy)


def _segment(samples: Sequence[Sample]) -> List[List[Sample]]:
    """Split samples into segments separated by gaps > GAP_MIN."""
    if not samples:
        return []
    s = sorted(samples, key=lambda x: x.t)
    out: List[List[Sample]] = [[s[0]]]
    for prev, cur in zip(s[:-1], s[1:]):
        gap_min = (cur.t - prev.t).total_seconds() / 60.0
        if gap_min > GAP_MIN:
            out.append([cur])
        else:
            out[-1].append(cur)
    return out


def _resample_segment(seg: Sequence[Sample]) -> List[Sample]:
    """Linear-interpolate one segment to a RESAMPLE_MIN even cadence."""
    if len(seg) < 2:
        return list(seg)
    start, end = seg[0].t, seg[-1].t
    step = timedelta(minutes=RESAMPLE_MIN)
    out: List[Sample] = []
    i = 0
    t = start
    while t <= end:
        while i + 1 < len(seg) and seg[i + 1].t < t:
            i += 1
        a = seg[i]
        b = seg[min(i + 1, len(seg) - 1)]
        span = (b.t - a.t).total_seconds()
        if span <= 0:
            p, obs = a.p, a.observed
        else:
            frac = (t - a.t).total_seconds() / span
            p = a.p + frac * (b.p - a.p)
            obs = a.observed and b.observed
        out.append(Sample(t=t, p=p, observed=obs))
        t += step
    return out


def _smooth(seg: Sequence[Sample]) -> List[Sample]:
    """Centered moving average with window SMOOTH_K. Endpoints shrink the window."""
    if SMOOTH_K <= 1 or len(seg) < 2:
        return list(seg)
    half = SMOOTH_K // 2
    out: List[Sample] = []
    for i, s in enumerate(seg):
        lo = max(0, i - half)
        hi = min(len(seg), i + half + 1)
        vals = [seg[j].p for j in range(lo, hi)]
        out.append(Sample(t=s.t, p=sum(vals) / len(vals), observed=s.observed))
    return out


def _derivative(seg: Sequence[Sample]) -> List[Tuple[datetime, float]]:
    """Centered first derivative (hPa/hr) for each sample."""
    out: List[Tuple[datetime, float]] = []
    for i, s in enumerate(seg):
        if i == 0:
            a, b = seg[0], seg[min(1, len(seg) - 1)]
        elif i == len(seg) - 1:
            a, b = seg[max(0, i - 1)], seg[-1]
        else:
            a, b = seg[i - 1], seg[i + 1]
        dt_hr = (b.t - a.t).total_seconds() / 3600.0
        d = (b.p - a.p) / dt_hr if dt_hr > 0 else 0.0
        out.append((s.t, d))
    return out


# --- Feature scan ----------------------------------------------------------


def _scan_features(
    smoothed: Sequence[Sample],
    raw_seg: Sequence[Sample],
    *,
    now: datetime,
    local_hour_offset: float,
) -> Tuple[str, Optional[datetime]]:
    """Locate the dominant feature near `now`. Returns (feature, featureTime)."""
    if len(smoothed) < 3:
        return ("none", None)

    raw_ps = [s.p for s in raw_seg]
    det_ps = [s.p for s in smoothed]
    raw_range = max(raw_ps) - min(raw_ps)
    det_range = max(det_ps) - min(det_ps)

    # Diurnal-only: de-tided is flat AND the raw curve correlates strongly with
    # the tide sinusoid → the wobble *is* the tide, not weather.
    if det_range <= DIURNAL_FLATNESS_HPA:
        tide_vals = [tide(s.t, local_hour_offset=local_hour_offset) for s in raw_seg]
        corr = _correlation(raw_ps, tide_vals)
        if corr >= DIURNAL_CORR_MIN and raw_range > DIURNAL_FLATNESS_HPA:
            return ("diurnal_only", None)
        return ("none", None)

    deriv = _derivative(smoothed)

    troughs: List[datetime] = []
    ridges: List[datetime] = []
    for i in range(1, len(deriv)):
        _, d_prev = deriv[i - 1]
        t, d = deriv[i]
        if d_prev < 0 <= d:
            troughs.append(t)
        elif d_prev > 0 >= d:
            ridges.append(t)

    nearest_trough = _nearest(troughs, now)
    nearest_ridge = _nearest(ridges, now)

    # 1. trough_passing — front/low center at/near now
    if nearest_trough is not None and abs((nearest_trough - now).total_seconds()) <= TROUGH_NEAR_HOURS * 3600:
        return ("trough_passing", nearest_trough)

    # 2. front_knee — sudden steepen within the recent past
    knee_time = _scan_knee(smoothed, now=now)
    if knee_time is not None:
        return ("front_knee", knee_time)

    # 3. rapid_fall / rapid_rise — sustained steep slope over the trailing window.
    # Sign-aware: a fast rise (gust front / strong post-frontal clearing) is its own
    # signal, not a "fall". RAPID_FALL_RATE is the magnitude threshold for both.
    rf_start = now - timedelta(hours=RAPID_FALL_HOURS)
    rf_win = [s for s in smoothed if rf_start <= s.t <= now]
    if len(rf_win) >= 3:
        rf_slope = _slope(rf_win)
        if rf_slope <= -RAPID_FALL_RATE:
            return ("rapid_fall", None)
        if rf_slope >= RAPID_FALL_RATE:
            return ("rapid_rise", None)

    # 4. approaching_trough — next trough is in the future
    if nearest_trough is not None and nearest_trough > now:
        return ("approaching_trough", nearest_trough)

    # 5. ridge_peak — most recent ridge near or just past now
    if nearest_ridge is not None and abs((nearest_ridge - now).total_seconds()) <= RIDGE_NEAR_HOURS * 3600:
        return ("ridge_peak", nearest_ridge)

    # 6. post_trough_recovery — recent past trough + currently rising
    if nearest_trough is not None and nearest_trough < now:
        recent = [s for s in smoothed if s.t >= now - timedelta(hours=2)]
        if _slope(recent) > 0.3:
            return ("post_trough_recovery", nearest_trough)

    return ("none", None)


def _scan_knee(smoothed: Sequence[Sample], *, now: datetime) -> Optional[datetime]:
    """Return the time of the most recent knee within the lookback window."""
    knee_time: Optional[datetime] = None
    earliest = now - timedelta(hours=KNEE_LOOKBACK_HOURS)
    for s in smoothed:
        t = s.t
        if t < earliest or t > now:
            continue
        before = [x for x in smoothed if t - timedelta(hours=1.5) <= x.t < t]
        after = [x for x in smoothed if t <= x.t <= t + timedelta(hours=1.5)]
        if len(before) < 3 or len(after) < 3:
            continue
        sb = _slope(before)
        sa = _slope(after)
        if abs(sa) < KNEE_MIN_RATE:
            continue
        if abs(sb) > KNEE_MAX_BEFORE:
            continue
        if abs(sa) < KNEE_RATIO * max(abs(sb), 0.1):
            continue
        knee_time = t  # keep the most recent match
    return knee_time


def _nearest(times: Sequence[datetime], now: datetime) -> Optional[datetime]:
    if not times:
        return None
    return min(times, key=lambda t: abs((t - now).total_seconds()))


# --- Main entry -------------------------------------------------------------


def interpret(
    samples: Sequence[Sample],
    *,
    now: Optional[datetime] = None,
    local_hour_offset: float = 0.0,
) -> Reading:
    """Pure function: turn a pressure time series into a structured Reading.

    `samples` may mix observed (past) and forecast (future) points; the boundary
    is `now` (defaulting to the latest sample). `local_hour_offset` lets the
    caller align timestamps with local solar time for the de-tide step (e.g.
    pass -5.0 for US Eastern timezone-naive timestamps in winter).
    """
    if not samples:
        return Reading("steady", 0.0, 0.0, "none", None, 0.0, ())

    samples = sorted(
        (Sample(_aware(s.t), s.p, s.observed) for s in samples),
        key=lambda s: s.t,
    )
    if now is None:
        now = samples[-1].t
    else:
        now = _aware(now)

    caveats: List[str] = []

    segs = _segment(samples)
    if len(segs) > 1:
        caveats.append("sparse")

    # Pick the segment containing `now` (preferred) or the longest segment.
    chosen = next((s for s in segs if s[0].t <= now <= s[-1].t), None)
    if chosen is None:
        chosen = max(segs, key=len)

    seg = _resample_segment(chosen)
    detided = [
        Sample(s.t, s.p - tide(s.t, local_hour_offset=local_hour_offset), s.observed)
        for s in seg
    ]
    smoothed = _smooth(detided)

    # --- slope + steadiness over trailing window ---
    window_start = now - timedelta(hours=SLOPE_WINDOW_HOURS)
    win = [s for s in smoothed if window_start <= s.t <= now]
    if len(win) < 3:
        win = smoothed[-3:] if len(smoothed) >= 3 else list(smoothed)
        if len(win) < 2:
            return Reading("steady", 0.0, 0.0, "none", None, 0.0, tuple(caveats))
    xs = [(s.t - win[0].t).total_seconds() / 3600.0 for s in win]
    ys = [s.p for s in win]
    _, slope_per_hr, r2 = _lsq(xs, ys)
    rate3h = slope_per_hr * 3.0
    steadiness = r2

    # Flag "short_window" only when recent history is genuinely thin — not merely
    # because the newest sample lags real-time `now` (METARs run 20-40 min behind
    # and the 30-min resample grid shaves the span). Coverage is measured from the
    # oldest available sample in the chosen segment to `now`.
    coverage_hours = (now - chosen[0].t).total_seconds() / 3600.0
    if coverage_hours < SHORT_WINDOW_MIN_HOURS or len(win) < SHORT_WINDOW_MIN_POINTS:
        caveats.append("short_window")

    # --- feature scan over the de-tided + smoothed segment ---
    feature, feature_time = _scan_features(
        smoothed, seg, now=now, local_hour_offset=local_hour_offset
    )

    if (
        feature_time is not None
        and (feature_time - now).total_seconds() > FORECAST_LEAD_HOURS * 3600
    ):
        caveats.append("forecast_derived")

    trend = classify(rate3h)

    # --- confidence ---
    confidence = 1.0
    if "short_window" in caveats:
        confidence *= 0.5
    if "sparse" in caveats:
        confidence *= 0.7
    if "forecast_derived" in caveats:
        confidence *= 0.7
    if feature in {"approaching_trough", "trough_passing", "ridge_peak", "front_knee"} and steadiness < 0.5:
        confidence *= 0.7
    confidence = max(0.0, min(1.0, confidence))

    return Reading(
        trend=trend,
        rate3h=round(rate3h, 2),
        steadiness=round(steadiness, 3),
        feature=feature,
        featureTime=feature_time,
        confidence=round(confidence, 2),
        caveats=tuple(caveats),
    )
