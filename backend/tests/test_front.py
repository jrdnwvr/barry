"""Front watch: the regional tendency-field analysis (front.py + /front)."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app import front
from app.front import RingStation, analyze, cardinal, ring_stations
from app.interpreter import Reading
from app.service import PressureService

NOW = datetime(2026, 7, 11, 18, 0, tzinfo=timezone.utc)


def ring_field(fn):
    """8 stations at 100 km, tendency assigned by fn(x_east_km, y_north_km)."""
    import math

    out = []
    for i, bearing in enumerate(range(0, 360, 45)):
        x = 100.0 * math.sin(math.radians(bearing))
        y = 100.0 * math.cos(math.radians(bearing))
        out.append(RingStation(id=f"KR{i}A", bearing_deg=float(bearing),
                               distance_km=100.0, delta3h=round(fn(x, y), 2)))
    return out


def reading(feature="none", feature_time=None):
    return Reading(trend="falling", rate3h=-1.0, steadiness=0.9,
                   feature=feature, featureTime=feature_time,
                   confidence=0.9, caveats=())


# ---- classification ---------------------------------------------------------


def test_west_falls_reads_as_approaching_from_west():
    ring = ring_field(lambda x, y: -1.0 + 0.015 * x)  # falls strongest west
    eta = NOW + timedelta(hours=5)
    resp = analyze(station="KLUK", ring=ring, own_delta3h=-0.8,
                   reading=reading("approaching_trough", eta), now=NOW)
    assert resp.status == "approaching"
    assert resp.cardinal == "west"
    assert 250 <= resp.bearingDeg <= 290
    assert resp.eta == eta
    assert resp.maxFall3h == pytest.approx(-2.5, abs=0.05)
    # The strongest-falling station ids drive the copy.
    assert "KR6A" in resp.detail  # bearing 270 = due west
    assert "west" in resp.detail
    assert len(resp.stations) == 8


def test_flat_field_is_none():
    ring = ring_field(lambda x, y: 0.1 if x > 0 else -0.1)
    resp = analyze(station="KLUK", ring=ring, own_delta3h=0.1,
                   reading=reading(), now=NOW)
    assert resp.status == "none"
    assert resp.headline is None
    assert resp.stations == []  # quiet response stays tiny


def test_rising_behind_falls_downstream_reads_as_passed():
    ring = ring_field(lambda x, y: -1.0 - 0.015 * x)  # falls strongest east
    resp = analyze(station="KLUK", ring=ring, own_delta3h=1.2,
                   reading=reading(), now=NOW)
    assert resp.status == "passed"
    assert resp.cardinal == "east"
    assert "rising here" in resp.detail


def test_model_trough_without_obs_is_forecast_only():
    ring = ring_field(lambda x, y: 0.1 if x > 0 else -0.1)  # incoherent
    eta = NOW + timedelta(hours=6)
    resp = analyze(station="KLUK", ring=ring, own_delta3h=-0.2,
                   reading=reading("approaching_trough", eta), now=NOW)
    assert resp.status == "forecast"
    assert resp.eta == eta
    assert "model" in resp.detail.lower()


def test_trough_passing_wins_over_field():
    ring = ring_field(lambda x, y: -1.0 + 0.015 * x)
    resp = analyze(station="KLUK", ring=ring, own_delta3h=-2.0,
                   reading=reading("trough_passing", NOW), now=NOW)
    assert resp.status == "passing"


def test_too_few_stations_never_calls_direction():
    ring = ring_field(lambda x, y: -1.0 + 0.015 * x)[:3]
    resp = analyze(station="KLUK", ring=ring, own_delta3h=-0.8,
                   reading=reading(), now=NOW)
    assert resp.status == "none"


def test_weak_gradient_is_none():
    # Coherent but tiny: 0.1 hPa/3h per 100 km is noise, not a front.
    ring = ring_field(lambda x, y: -0.05 + 0.001 * x)
    resp = analyze(station="KLUK", ring=ring, own_delta3h=-0.05,
                   reading=reading(), now=NOW)
    assert resp.status == "none"


def test_cardinal_words():
    assert cardinal(0) == "north"
    assert cardinal(90) == "east"
    assert cardinal(270) == "west"
    assert cardinal(292.4) == "west"
    assert cardinal(292.6) == "northwest"
    assert cardinal(359) == "north"


# ---- per-station delta extraction ------------------------------------------


def test_ring_stations_scale_and_fallback(client, upstream):
    # Direct exercise of the bbox -> ring path via the fixture's synthetic field.
    import asyncio

    from app.sources import aviationweather as awc

    upstream.bbox_pattern = "west_falls"
    parsed = asyncio.get_event_loop().run_until_complete(
        awc.fetch_metars_bbox(39.103, -84.419, client, hours=4)
    )
    now = datetime.now(timezone.utc)
    ring = ring_stations(parsed, origin_lat=39.103, origin_lon=-84.419,
                         exclude="KLUK", now=now)
    assert len(ring) == 8
    west = min(ring, key=lambda s: s.delta3h)
    assert 250 <= west.bearing_deg <= 290
    assert west.delta3h == pytest.approx(-2.5, abs=0.1)
    # Altimeter-only stations still yield deltas (SLP fallback).
    east = max(ring, key=lambda s: s.delta3h)
    assert east.delta3h == pytest.approx(0.5, abs=0.1)


def test_stale_station_excluded():
    from app.models import SeriesPoint

    old = datetime.now(timezone.utc) - timedelta(hours=5)
    series = [
        SeriesPoint(t=old - timedelta(hours=3), altim=1015.0),
        SeriesPoint(t=old, altim=1013.0),
    ]
    assert front._delta3h(series, datetime.now(timezone.utc)) is None


def test_garbage_delta_discarded():
    from app.models import SeriesPoint

    now = datetime.now(timezone.utc)
    series = [
        SeriesPoint(t=now - timedelta(hours=3), altim=1015.0),
        SeriesPoint(t=now, altim=1035.0),  # +20 hPa/3h = broken sensor
    ]
    assert front._delta3h(series, now) is None


# ---- service integration ----------------------------------------------------


@pytest.mark.asyncio
async def test_get_front_end_to_end(client, upstream):
    upstream.bbox_pattern = "west_falls"
    upstream.om_trough = True
    service = PressureService(client)
    resp = await service.get_front("KLUK", 39.103, -84.419)
    assert resp.status == "approaching"
    assert resp.cardinal == "west"
    assert resp.eta is not None          # interpreter trough on the merged curve
    assert len(resp.stations) == 8
    assert resp.station == "KLUK"


@pytest.mark.asyncio
async def test_get_front_quiet_day(client, upstream):
    upstream.bbox_pattern = "flat"
    service = PressureService(client)
    resp = await service.get_front("KLUK", 39.103, -84.419)
    # Own station falls -2.4 so the interpreter may still flag its own curve
    # (trough/forecast), but an incoherent regional field must NEVER claim a
    # direction — that's the guarantee that keeps the compass honest.
    assert resp.status not in ("approaching", "passed")
    assert resp.bearingDeg is None


@pytest.mark.asyncio
async def test_get_front_caches(client, upstream):
    upstream.bbox_pattern = "west_falls"
    service = PressureService(client)
    await service.get_front("KLUK", 39.103, -84.419)
    bbox_calls = [c for c in upstream.awc_calls if c.url.params.get("bbox")]
    assert len(bbox_calls) == 1
    await service.get_front("KLUK", 39.103, -84.419)
    bbox_calls = [c for c in upstream.awc_calls if c.url.params.get("bbox")]
    assert len(bbox_calls) == 1  # served from cache


@pytest.mark.asyncio
async def test_get_front_survives_bbox_failure(client, upstream):
    upstream.bbox_pattern = None  # AWC returns an empty body for the bbox
    upstream.om_trough = True
    service = PressureService(client)
    resp = await service.get_front("KLUK", 39.103, -84.419)
    # No regional field, but the model trough still gives an honest heads-up.
    assert resp.status == "forecast"
    assert resp.eta is not None
