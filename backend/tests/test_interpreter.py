"""Trend interpreter — 10 synthetic-curve fixtures (brief §4.3.4).

These assert the interpreter *contract* against deterministic hand-built series.
The same fixtures will be ported to Swift verbatim so the two implementations
cannot drift.
"""

from __future__ import annotations

import random
from datetime import datetime, timedelta, timezone

import pytest

from app.interpreter import Sample, interpret, tide

NOW = datetime(2026, 6, 28, 18, 0, tzinfo=timezone.utc)


def _series(p_at_hr, *, t0_hr=-6.0, t1_hr=6.0, step_min=15):
    """Generate samples spaced `step_min` apart from t0..t1 (hours relative to NOW)."""
    out = []
    n_steps = int(((t1_hr - t0_hr) * 60.0) // step_min) + 1
    for i in range(n_steps):
        hr = t0_hr + i * (step_min / 60.0)
        t = NOW + timedelta(hours=hr)
        out.append(Sample(t=t, p=p_at_hr(hr), observed=(hr <= 0.0)))
    return out


def _with_tide(p_raw):
    """Layer the natural pressure tide on top of a raw shape so the synthetic
    fixtures look like real-world data the de-tide step is calibrated for."""
    def wrapped(hr):
        return p_raw(hr) + tide(NOW + timedelta(hours=hr))
    return wrapped


# 1. Clean V trough, bottom +0h.
def test_clean_v_trough():
    def p(hr):
        if hr <= 0:
            return 1015.0 + (1006.0 - 1015.0) * (hr - (-6.0)) / 6.0
        return 1006.0 + (1012.0 - 1006.0) * hr / 6.0

    r = interpret(_series(_with_tide(p)), now=NOW)
    assert r.feature == "trough_passing", f"feature={r.feature}"
    assert r.featureTime is not None
    assert abs((r.featureTime - NOW).total_seconds()) <= 3600
    assert r.trend in ("falling", "falling_mod", "falling_fast")
    assert r.confidence >= 0.5


# 2. Approaching trough, bottom +4h (in the forecast half).
def test_approaching_trough():
    def p(hr):
        # 1015 at -6h, linear fall to 1006 at +4h, then rise.
        if hr <= 4.0:
            return 1015.0 - 9.0 * (hr - (-6.0)) / 10.0
        return 1006.0 + 6.0 * (hr - 4.0) / 6.0

    r = interpret(_series(_with_tide(p), t0_hr=-6.0, t1_hr=8.0), now=NOW)
    assert r.feature == "approaching_trough", f"feature={r.feature}"
    assert r.featureTime is not None
    delta_hr = (r.featureTime - NOW).total_seconds() / 3600.0
    assert 2.5 <= delta_hr <= 5.5, f"trough at {delta_hr}h"
    assert "forecast_derived" in r.caveats


# 3. Rapid sustained fall — no bottom in window.
def test_rapid_sustained_fall():
    def p(hr):
        if hr <= -4.0:
            return 1015.0
        return 1015.0 - 5.0 * (hr - (-4.0)) / 4.0

    r = interpret(_series(_with_tide(p), t0_hr=-6.0, t1_hr=0.0), now=NOW)
    assert r.trend == "falling_fast", f"trend={r.trend} rate3h={r.rate3h}"
    assert r.feature == "rapid_fall", f"feature={r.feature}"


# 4. Pure diurnal wobble — THE anti-false-alarm test (brief §4.3.4 #4).
def test_diurnal_only_no_false_alarm():
    def p(hr):
        return 1014.0 + tide(NOW + timedelta(hours=hr))

    r = interpret(_series(p, t0_hr=-12.0, t1_hr=0.0, step_min=30), now=NOW)
    assert r.feature == "diurnal_only", f"feature={r.feature}"
    assert r.trend == "steady", f"trend={r.trend} rate3h={r.rate3h}"


# 5. Diurnal + real fall superimposed — de-tide must remove the wobble.
def test_diurnal_plus_real_fall():
    def p(hr):
        # 1014 + tide(t) + linear ramp -3 hPa across 6h.
        return 1014.0 + tide(NOW + timedelta(hours=hr)) - 0.5 * (hr - (-6.0))

    r = interpret(_series(p, t0_hr=-6.0, t1_hr=0.0), now=NOW)
    assert r.trend in ("falling", "falling_mod"), f"trend={r.trend} rate3h={r.rate3h}"
    assert -1.8 <= r.rate3h <= -1.2, f"rate3h={r.rate3h}"


# 6. Flat + noise — no spurious feature/ETA.
def test_flat_with_noise():
    rng = random.Random(42)
    def p_raw(hr):
        return 1014.0 + rng.uniform(-0.3, 0.3)

    r = interpret(_series(_with_tide(p_raw), t0_hr=-6.0, t1_hr=0.0), now=NOW)
    # With tide layered in, either "none" (no signal) or "diurnal_only" (only
    # the tide moved) is an honest answer — both mean "no weather story".
    assert r.feature in ("none", "diurnal_only"), f"feature={r.feature}"
    assert r.trend == "steady"
    if r.feature == "none":
        assert r.featureTime is None


# 7. Front knee at -2h.
def test_front_knee():
    def p(hr):
        if hr <= -2.0:
            return 1014.0
        return 1014.0 - 3.0 * (hr - (-2.0))  # 3 hPa/h after the knee

    r = interpret(_series(_with_tide(p), t0_hr=-6.0, t1_hr=0.0), now=NOW)
    assert r.feature == "front_knee", f"feature={r.feature}"
    knee_off = (r.featureTime - NOW).total_seconds() / 3600.0
    assert -2.75 <= knee_off <= -1.0, f"knee at {knee_off}h"
    assert r.trend in ("falling", "falling_mod", "falling_fast")


# 8. Ridge peak at -1h.
def test_ridge_peak():
    def p(hr):
        if hr <= -1.0:
            return 1010.0 + (1014.0 - 1010.0) * (hr - (-6.0)) / 5.0
        return 1014.0 - 1.0 * (hr - (-1.0))

    r = interpret(_series(_with_tide(p), t0_hr=-6.0, t1_hr=0.0), now=NOW)
    assert r.feature == "ridge_peak", f"feature={r.feature}"


# 9. Short window — 90 minutes of falling data, low confidence.
def test_short_window_low_confidence():
    def p(hr):
        return 1014.0 - 2.0 * (hr - (-1.5)) / 1.5  # 2 hPa fall over 90 min

    r = interpret(_series(_with_tide(p), t0_hr=-1.5, t1_hr=0.0, step_min=15), now=NOW)
    assert "short_window" in r.caveats
    assert r.confidence <= 0.6


# 9b. Normal hourly-reporting station — last sample ~30 min old, points every
# 30 min over 3h. The window span is only ~2.5h (newest sample lags `now` and the
# resample grid shaves it), but genuine coverage is 3h, so NO short_window.
def test_hourly_station_no_short_window():
    def p(hr):
        return 1014.0 - 0.5 * (hr - (-3.0))  # gentle steady fall

    samples = _series(_with_tide(p), t0_hr=-3.0, t1_hr=-0.5, step_min=30)
    r = interpret(samples, now=NOW)
    assert "short_window" not in r.caveats, f"caveats={r.caveats}"
    assert r.confidence > 0.6, f"confidence={r.confidence}"


# 9c. Genuinely thin history — under 2h of recent data still trips short_window
# even though points are dense.
def test_under_two_hours_still_short_window():
    def p(hr):
        return 1014.0 - 1.0 * (hr - (-1.75))

    samples = _series(_with_tide(p), t0_hr=-1.75, t1_hr=0.0, step_min=15)
    r = interpret(samples, now=NOW)
    assert "short_window" in r.caveats, f"caveats={r.caveats}"


# 10. Gappy data — 3h hole mid-series — no phantom feature spanning the gap.
def test_gappy_data_no_phantom_feature():
    samples = []
    # Segment 1: -6h..-4h flat at 1015 (+ tide).
    t = NOW + timedelta(hours=-6)
    while t <= NOW + timedelta(hours=-4):
        samples.append(Sample(t, 1015.0 + tide(t), observed=True))
        t += timedelta(minutes=30)
    # 3h gap (-4h..-1h).
    # Segment 2: -1h..0h flat at 1015 (+ tide).
    t = NOW + timedelta(hours=-1)
    while t <= NOW:
        samples.append(Sample(t, 1015.0 + tide(t), observed=True))
        t += timedelta(minutes=30)

    r = interpret(samples, now=NOW)
    assert "sparse" in r.caveats
    # With only a flat segment, the interpreter must not invent a feature.
    assert r.feature in ("none", "diurnal_only"), f"feature={r.feature}"
