"""Front watch enrichment: the nearest WPC-analyzed front and its motion."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app import front
from app.models import FrontFrame, FrontLine
from app.service import PressureService

T0 = datetime(2026, 9, 14, 15, tzinfo=timezone.utc)


def frame(hours, fronts):
    return FrontFrame(hours=hours, valid=T0 + timedelta(hours=hours), fronts=fronts)


def test_distance_is_to_the_segment_not_the_vertices():
    # A front running north-south 100 km west of the station: nearest point is
    # mid-segment, not one of the endpoints 300 km away.
    line = [[42.0, -85.6], [36.0, -85.6]]
    d, brg = front._dist_to_polyline_km(39.1, -84.4, line)
    assert 95 <= d <= 110
    assert 255 <= brg <= 285   # due west-ish


def test_nearest_picks_closest_and_reports_direction():
    far = FrontLine(type="warm", points=[[48.0, -100.0], [45.0, -95.0]])
    near = FrontLine(type="cold", points=[[42.0, -86.0], [36.0, -86.0]])
    nf = front.nearest_wpc_front([frame(0, [far, near])], 39.1, -84.4)
    assert nf is not None
    assert nf.type == "cold"
    assert nf.cardinal == "west"
    assert nf.approaching is None      # no prog frame supplied


def test_beyond_range_is_none():
    far = FrontLine(type="cold", points=[[48.0, -100.0], [45.0, -95.0]])
    assert front.nearest_wpc_front([frame(0, [far])], 39.1, -84.4) is None


def test_prog_closing_gives_eta():
    now_line = FrontLine(type="cold", points=[[42.0, -87.0], [36.0, -87.0]])   # ~225 km W
    later = FrontLine(type="cold", points=[[42.0, -85.6], [36.0, -85.6]])      # ~100 km W at +12 h
    nf = front.nearest_wpc_front([frame(0, [now_line]), frame(12, [later])], 39.1, -84.4)
    assert nf.approaching is True
    # Closing ~125 km per 12 h from ~225 km out -> ~21-22 h.
    assert 19 <= nf.etaHours <= 24
    assert nf.etaAt == T0 + timedelta(hours=nf.etaHours)


def test_prog_retreating_is_not_approaching():
    now_line = FrontLine(type="cold", points=[[42.0, -86.0], [36.0, -86.0]])
    later = FrontLine(type="cold", points=[[42.0, -88.0], [36.0, -88.0]])
    nf = front.nearest_wpc_front([frame(0, [now_line]), frame(12, [later])], 39.1, -84.4)
    assert nf.approaching is False
    assert nf.etaHours is None


def test_unmatched_prog_front_leaves_motion_unknown():
    now_line = FrontLine(type="cold", points=[[42.0, -86.0], [36.0, -86.0]])
    elsewhere = FrontLine(type="cold", points=[[30.0, -110.0], [25.0, -108.0]])
    nf = front.nearest_wpc_front([frame(0, [now_line]), frame(12, [elsewhere])], 39.1, -84.4)
    assert nf.approaching is None


@pytest.mark.asyncio
async def test_front_watch_carries_nearest_front(client, upstream, monkeypatch):
    import app.service as service_mod
    monkeypatch.setattr(service_mod, "_run_interpreter", lambda p, f: (None, 0.0))
    upstream.bbox_pattern = "west_falls"
    service = PressureService(client)
    resp = await service.get_front("KLUK", 39.103, -84.419)
    nf = resp.nearestFront
    # The sample analysis's East Coast cold front passes ~450 km due south.
    assert nf is not None and nf.type == "cold"
    assert 400 <= nf.distanceKm <= 550 and nf.cardinal == "south"
    assert nf.approaching is None      # sample prog has no matching front
