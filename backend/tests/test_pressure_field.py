"""Isobars/isallobars from the station table."""

from __future__ import annotations

import math

import pytest

from app import pressure_field as pf
from app.models import StationObs
from app.service import PressureService


def linear_table(n=12, slope_hpa_per_deg_lat=4.0, tend=None):
    """A clean linear pressure field over a 6x6° box around 39N 84W."""
    out = []
    for j in range(n):
        for i in range(n):
            lat = 36.0 + 6.0 * j / (n - 1)
            lon = -87.0 + 6.0 * i / (n - 1)
            slp = 1012.0 + slope_hpa_per_deg_lat * (lat - 39.0)
            out.append(StationObs(id=f"S{j}{i}", lat=lat, lon=lon, slp=round(slp, 1),
                                  presTend=tend(lat, lon) if tend else None))
    return out


def test_isobars_follow_a_linear_field():
    isobars, _, pgrid, _ = pf.build(linear_table(), 39.0, -84.0, 3.0, 3.0)
    assert pgrid is not None and pgrid.ny * pgrid.nx <= 1700 and pgrid.values[0][0] is not None
    levels = sorted({c.level for c in isobars})
    assert 1008.0 in levels and 1012.0 in levels and 1016.0 in levels
    # The 1012 line lies along 39°N (the field is 1012 there).
    line = max((c for c in isobars if c.level == 1012.0), key=lambda c: len(c.points))
    lats = [p[0] for p in line.points]
    assert max(abs(v - 39.0) for v in lats) < 0.35
    assert len(line.points) >= 5


def test_outlier_station_does_not_draw_a_bullseye():
    table = linear_table()
    table.append(StationObs(id="BAD", lat=39.0, lon=-84.0, slp=1040.0))    # broken barometer
    isobars, _, _, _ = pf.build(table, 39.0, -84.0, 3.0, 3.0)
    assert not any(c.level >= 1024.0 for c in isobars)


def test_isallobars_mark_a_falling_region():
    table = linear_table()
    tend_pts = [(s.lat, s.lon, -2.5 if s.lon < -84.0 else 0.0) for s in table]
    _, isallobars, _, tgrid = pf.build(table, 39.0, -84.0, 3.0, 3.0, tend_pts=tend_pts)
    assert tgrid is not None
    levels = {c.level for c in isallobars}
    assert -1.0 in levels and -2.0 in levels and 1.0 not in levels
    line = max((c for c in isallobars if c.level == -1.0), key=lambda c: len(c.points))
    assert max(abs(p[1] + 84.0) for p in line.points) < 0.6      # runs along 84°W


def test_too_few_stations_gives_no_lines():
    isobars, isallobars, pgrid, tgrid = pf.build(linear_table(n=2), 39.0, -84.0, 3.0, 3.0)
    assert isobars == [] and isallobars == [] and pgrid is None and tgrid is None


@pytest.mark.asyncio
async def test_endpoint_shape_and_cache(client, upstream):
    service = PressureService(client)
    a = await service.get_pressure_field(39.1, -84.5, 3.2, 3.2)
    b = await service.get_pressure_field(39.12, -84.48, 3.15, 3.24)
    assert a.cachedAt == b.cachedAt and upstream.bulk_calls == 1
    assert a.stations > 0


def test_flat_day_gets_2_hpa_isobars():
    isobars, _, _, _ = pf.build(linear_table(slope_hpa_per_deg_lat=1.0), 39.0, -84.0, 3.0, 3.0)
    levels = sorted({c.level for c in isobars})
    assert levels and all(l % 2 == 0 for l in levels) and any(l % 4 != 0 for l in levels)


def test_tendency_points_from_history(client):
    from datetime import datetime, timedelta, timezone
    from test_front_history import ring_table
    service = PressureService(client)
    now = datetime.now(timezone.utc)
    for h in (3, 2, 1, 0):
        at = now - timedelta(hours=h)
        service._record_snapshot(ring_table(at, 3 - h), at)
    pts = service._tendency_points(now)
    assert len(pts) == 8
    west = [v for (la, lo, v) in pts if lo < -84.419]
    assert all(abs(v + 2.4) < 0.3 for v in west)          # 0.8 hPa/h falls -> -2.4 per 3 h
