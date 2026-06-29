"""Tendency math — the core domain logic, verified without any network."""

from datetime import datetime, timedelta, timezone

import pytest

from app.tendency import (
    classify,
    delta3h_from_series,
    intensity,
    resolve_tendency,
    tendency_from_delta,
)


@pytest.mark.parametrize(
    "d,expected",
    [
        (2.0, "rising_fast"),
        (1.5, "rising_fast"),
        (1.0, "rising"),
        (0.5, "rising"),
        (0.0, "steady"),
        (-0.4, "steady"),
        (-0.5, "falling"),
        (-1.4, "falling"),
        (-1.5, "falling_mod"),   # brief: -3.0 < d <= -1.5 is falling_mod (closed at -1.5)
        (-1.6, "falling_mod"),
        (-3.0, "falling_fast"),  # brief: d <= -3.0 is falling_fast (closed at -3.0)
        (-3.1, "falling_fast"),
        (-5.0, "falling_fast"),
    ],
)
def test_classify_boundaries(d, expected):
    assert classify(d) == expected


def test_classify_steady_band_is_open_at_both_ends():
    # -0.5 < d < +0.5 is steady; the edges belong to falling / rising
    assert classify(-0.49) == "steady"
    assert classify(0.49) == "steady"
    assert classify(0.5) == "rising"
    assert classify(-0.5) == "falling"


def test_intensity_band_mapping():
    assert intensity(-1.5) == pytest.approx(0.0)   # band floor -> palest
    assert intensity(-4.0) == pytest.approx(1.0)   # band ceil -> deepest
    assert intensity(-2.75) == pytest.approx(0.5)  # midpoint
    assert intensity(-6.0) == pytest.approx(1.0)   # clamped above
    assert intensity(-0.5) == pytest.approx(0.0)   # clamped below
    # intensity is magnitude-based, so sign doesn't matter
    assert intensity(2.75) == pytest.approx(0.5)


def test_tendency_from_delta_rounds():
    t = tendency_from_delta(-2.4)
    assert t.cls == "falling_mod"
    assert t.delta3h == -2.4
    assert 0.0 <= t.intensity <= 1.0


def test_delta_from_series_basic():
    base = datetime(2026, 6, 28, 7, 0, tzinfo=timezone.utc)
    times = [base + timedelta(hours=h) for h in range(4)]
    values = [1012.0, 1011.2, 1010.4, 1009.6]
    # newest (t+3h) - sample ~3h earlier (t+0) = 1009.6 - 1012.0
    d = delta3h_from_series(times, values)
    assert d == pytest.approx(-2.4)


def test_delta_from_series_handles_gaps_and_nones():
    base = datetime(2026, 6, 28, 7, 0, tzinfo=timezone.utc)
    times = [base + timedelta(hours=h) for h in (0, 1, 3)]
    values = [1015.0, None, 1012.0]
    d = delta3h_from_series(times, values)
    assert d == pytest.approx(-3.0)


def test_delta_from_series_rejects_when_no_3h_anchor():
    # only two samples 30 min apart -> can't honestly call it a 3h tendency
    base = datetime(2026, 6, 28, 7, 0, tzinfo=timezone.utc)
    times = [base, base + timedelta(minutes=30)]
    values = [1015.0, 1014.0]
    assert delta3h_from_series(times, values) is None


def test_resolve_prefers_pres_tend():
    base = datetime(2026, 6, 28, 7, 0, tzinfo=timezone.utc)
    times = [base + timedelta(hours=h) for h in range(4)]
    values = [1012.0, 1011.2, 1010.4, 1009.6]  # series delta would be -2.4
    t = resolve_tendency(-0.2, times, values)  # but presTend says -0.2
    assert t.delta3h == -0.2
    assert t.cls == "steady"


def test_resolve_falls_back_to_series():
    base = datetime(2026, 6, 28, 7, 0, tzinfo=timezone.utc)
    times = [base + timedelta(hours=h) for h in range(4)]
    values = [1012.0, 1011.2, 1010.4, 1009.6]
    t = resolve_tendency(None, times, values)
    assert t.delta3h == pytest.approx(-2.4)
    assert t.cls == "falling_mod"


def test_resolve_returns_none_when_unknowable():
    assert resolve_tendency(None, [], []) is None
