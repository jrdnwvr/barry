"""Observed METAR signals (C2) and the explanation block (C1)."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app import explain, signals
from app.interpreter import Reading
from app.models import ForecastHour, SeriesPoint
from app.service import PressureService

NOW = datetime(2026, 9, 15, 20, 0, tzinfo=timezone.utc)


def pt(hours_ago, **kw):
    return SeriesPoint(t=NOW - timedelta(hours=hours_ago), **kw)


def test_wind_shift_gust_and_temp_drop_detected():
    series = [
        pt(3.0, windKmh=15, windDir=210, temp=27, fltCat="VFR"),
        pt(2.0, windKmh=18, windDir=220, temp=27, fltCat="VFR"),
        pt(1.0, windKmh=20, windDir=300, gustKmh=40, temp=23, fltCat="MVFR"),
    ]
    kinds = {s.kind: s for s in signals.detect(series, NOW)}
    assert kinds["wind_shift"].detail["veer"] and kinds["wind_shift"].detail["fromDeg"] == 220
    assert kinds["gust_onset"].detail["gustKmh"] == 40
    assert kinds["temp_drop"].detail["dropC"] == 4
    assert kinds["category_change"].detail == {"fromCat": "VFR", "toCat": "MVFR", "worse": True}


def test_light_winds_and_old_reports_are_not_signals():
    series = [
        pt(2.0, windKmh=5, windDir=100),       # too light to have a direction
        pt(1.0, windKmh=6, windDir=280),
        pt(9.0, windKmh=30, windDir=100),      # outside the lookback
        pt(7.5, windKmh=30, windDir=280),
    ]
    assert signals.detect(series, NOW) == []


def _reading(trend="falling_mod", feature="approaching_trough"):
    return Reading(trend, -2.0, 0.9, feature, NOW + timedelta(hours=4), 0.9, ())


def _hour(h, **kw):
    base = dict(pressure_msl=1010.0, windspeed=10.0, winddir=200.0, windgust=None,
                precip_prob=5)
    base.update(kw)
    return ForecastHour(t=NOW + timedelta(hours=h), **base)


def test_explanation_supports_a_fall_with_model_rain_shift_and_gusts():
    forecast = [_hour(0), _hour(1), _hour(2, precip_prob=60), _hour(3, winddir=300.0),
                _hour(4, windgust=45.0)]
    series = [pt(2.0, windKmh=15, windDir=200, temp=25), pt(1.0, windKmh=15, windDir=205, temp=25)]
    out = explain.build(_reading(), forecast, series, NOW, local_hour_offset=-5)
    kinds = [s.kind for s in out.supporting]
    assert kinds == ["rain", "model_wind_shift", "model_gusts"]
    assert out.conflicting == []
    assert out.summary.startswith("The model puts rain in from 5 PM and swings the wind to 300°")
    assert all(s.source == "model" for s in out.supporting)


def test_explanation_names_disagreement_when_model_stays_calm():
    forecast = [_hour(h, windspeed=8.0, precip_prob=5) for h in range(8)]
    out = explain.build(_reading("falling_fast", "rapid_fall"), forecast, [], NOW)
    assert [s.kind for s in out.conflicting] == ["model_calm"]
    assert out.summary == "The model keeps the next hours dry and calm."


def test_observed_signals_come_first_and_read_as_metar():
    series = [pt(2.0, windKmh=20, windDir=210), pt(1.0, windKmh=25, windDir=310)]
    out = explain.build(_reading(), None, series, NOW, local_hour_offset=-5)
    assert out.supporting[0].source == "metar"
    assert out.summary.startswith("Wind veered from 210° to 310° at 2 PM")


def test_nothing_to_say_gives_no_block():
    assert explain.build(_reading(), None, [], NOW) is None
    assert explain.build(None, None, [], NOW) is None


import pytest


@pytest.mark.asyncio
async def test_combined_carries_series_fields_and_explanation(client):
    combined = await PressureService(client).get_combined("KLUK")
    last = combined.pressure.series[-1]
    assert last.windKmh is not None and last.windDir == 230 and last.temp == 27.0
    assert last.fltCat == "VFR" and last.ceilingFt == 4500
    # The fixture forecast is dry and calm-ish; whatever it says, the block
    # must be well-formed or absent, never an error.
    ex = combined.reading.explanation if combined.reading else None
    assert ex is None or (ex.summary and (ex.supporting or ex.conflicting))


def test_confidence_rises_with_agreement_and_falls_on_disagreement():
    from app.models import ExplanationOut, SignalOut
    sup = [SignalOut(kind="rain", at=NOW, text="", source="model"),
           SignalOut(kind="wind_shift", at=NOW, text="", source="metar")]
    conf, cav = explain.adjust_confidence(0.7, ExplanationOut(summary="", supporting=sup))
    assert conf == 0.9 and cav == []
    conf, cav = explain.adjust_confidence(1.0, ExplanationOut(summary="", supporting=sup))
    assert conf == 1.0                                   # never past 1
    calm = [SignalOut(kind="model_calm", at=NOW, text="", source="model")]
    conf, cav = explain.adjust_confidence(1.0, ExplanationOut(summary="", conflicting=calm))
    assert conf == 0.8 and cav == ["model_disagrees"]
    assert explain.adjust_confidence(0.6, None) == (0.6, [])
