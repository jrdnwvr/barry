"""Verdict composition (brief §4.2)."""

from datetime import datetime, timedelta, timezone

from app.interpreter import Reading
from app.models import ForecastHour
from app.verdict import build_verdict, find_precip_peak


def _reading(feature, trend="falling_mod", *, featureTime=None, caveats=()):
    return Reading(
        trend=trend,
        rate3h=-2.0,
        steadiness=0.9,
        feature=feature,
        featureTime=featureTime,
        confidence=0.8,
        caveats=tuple(caveats),
    )


def _fc(hour, precip):
    return ForecastHour(
        t=datetime(2026, 6, 28, hour, 0, tzinfo=timezone.utc),
        precip_prob=precip,
    )


def test_base_sentences():
    assert build_verdict("steady").startswith("Holding steady")
    assert build_verdict("rising_fast").startswith("Rising sharply")
    assert "storm system likely" in build_verdict("falling_fast")


def test_none_class_is_honest():
    assert "Not enough" in build_verdict(None)


def test_falling_enriched_with_precip_time():
    forecast = [_fc(10, 10), _fc(11, 20), _fc(15, 55)]
    out = build_verdict("falling_mod", forecast)
    assert "rain likely around 3 PM" in out


def test_rising_not_enriched_even_with_precip():
    forecast = [_fc(15, 80)]
    out = build_verdict("rising", forecast)
    assert "rain likely" not in out


def test_precip_peak_threshold():
    forecast = [_fc(10, 20), _fc(11, 40), _fc(12, 41)]
    peak = find_precip_peak(forecast)
    assert peak is not None and peak.precip_prob == 41  # 40 is not > 40


# --- feature-aware enrichment (Phase 2) ------------------------------------


def test_approaching_trough_includes_time_and_forecast_hedge():
    trough = datetime(2026, 6, 28, 22, 0, tzinfo=timezone.utc)
    r = _reading(
        "approaching_trough",
        trend="falling_mod",
        featureTime=trough,
        caveats=["forecast_derived"],
    )
    out = build_verdict("falling_mod", None, reading=r)
    assert "forecast to bottom out" in out
    assert "10 PM" in out
    assert "improving after" in out


def test_approaching_trough_with_local_offset():
    # Station longitude → local offset of -5h (US Eastern, ignoring DST). A UTC
    # trough at 22:00 should render as 5 PM local.
    trough = datetime(2026, 6, 28, 22, 0, tzinfo=timezone.utc)
    r = _reading("approaching_trough", featureTime=trough, caveats=["forecast_derived"])
    out = build_verdict("falling_mod", None, reading=r, local_hour_offset=-5.0)
    assert "5 PM" in out


def test_trough_passing_phrasing():
    r = _reading("trough_passing", trend="falling", featureTime=datetime(2026, 6, 28, 18, tzinfo=timezone.utc))
    out = build_verdict("falling", None, reading=r)
    assert "at/near bottom" in out
    assert "front passing now" in out


def test_rapid_fall_uses_storm_phrasing():
    r = _reading("rapid_fall", trend="falling_fast")
    out = build_verdict("falling_fast", None, reading=r)
    assert "storm system likely" in out
    assert "Secure loose items" in out


def test_rapid_rise_warns_of_gusty_winds():
    r = _reading("rapid_rise", trend="rising_fast")
    out = build_verdict("rising_fast", None, reading=r)
    assert "rising fast" in out.lower()
    assert "gusty winds" in out


def test_front_knee_phrasing():
    knee = datetime(2026, 6, 28, 16, tzinfo=timezone.utc)
    r = _reading("front_knee", trend="falling_mod", featureTime=knee)
    out = build_verdict("falling_mod", None, reading=r)
    assert "Sharp turn down" in out


def test_post_trough_recovery_says_improving():
    r = _reading("post_trough_recovery", trend="rising")
    out = build_verdict("rising", None, reading=r)
    assert "improving" in out


def test_ridge_peak_distinguishes_observed_vs_forecast():
    r_obs = _reading("ridge_peak", trend="steady")
    r_fc = _reading("ridge_peak", trend="steady", caveats=["forecast_derived"])
    assert "ridge top" in build_verdict("steady", None, reading=r_obs)
    assert "forecast to peak" in build_verdict("steady", None, reading=r_fc)


def test_diurnal_only_defers_to_steady_base():
    r = _reading("diurnal_only", trend="steady")
    out = build_verdict("steady", None, reading=r)
    assert out == "Holding steady — conditions stable."


def test_feature_enrichment_still_layers_precip():
    trough = datetime(2026, 6, 28, 21, 0, tzinfo=timezone.utc)
    r = _reading("approaching_trough", trend="falling_mod", featureTime=trough,
                 caveats=["forecast_derived"])
    forecast = [_fc(20, 35), _fc(21, 55)]
    out = build_verdict("falling_mod", forecast, reading=r)
    assert "forecast to bottom out" in out
    assert "rain likely around 9 PM" in out
