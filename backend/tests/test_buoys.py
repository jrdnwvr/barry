"""NDBC buoys on the station layer: parsed from latest_obs, added to a
station slice only when asked for, one fetch for everyone."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from app.service import PressureService
from app.sources import ndbc
from conftest import sample_ndbc_latest


def test_parse_keeps_fresh_rows_with_wind_or_pressure():
    now = datetime(2026, 9, 24, 21, 10, tzinfo=timezone.utc)
    rows = ndbc.parse(sample_ndbc_latest(now), now=now)
    ids = [r.id for r in rows]
    assert ids == ["45007", "OHCM1", "46026"]          # STALE is five hours old
    b = rows[0]
    assert b.kind == "buoy"
    assert b.windKt == pytest.approx(11.7, abs=0.1)     # 6.0 m/s
    assert b.gustKt == pytest.approx(16.5, abs=0.1)
    assert b.windDir == 240
    assert b.slp == 1012.4 and b.presTend == -1.6
    assert b.waveFt == pytest.approx(3.9, abs=0.1) and b.wavePeriodS == 6
    assert b.waterTempC == 19.5 and b.temp == 18.2 and b.dewpoint == 12.0
    coastal = rows[1]
    assert coastal.windKt is None and coastal.slp == 1013.0


@pytest.mark.asyncio
async def test_buoys_join_the_slice_only_when_asked(client, upstream):
    service = PressureService(client)
    plain = await service.get_station_obs(39.1, -84.5, half=3.0)
    assert all(s.kind == "metar" for s in plain.stations)
    with_buoys = await service.get_station_obs_with_buoys(39.1, -84.5, half=3.0)
    buoy_ids = [s.id for s in with_buoys.stations if s.kind == "buoy"]
    assert buoy_ids == ["OHCM1", "45007"]                # nearest first; the Pacific one is outside the box
    await service.get_station_obs_with_buoys(39.2, -84.4, half=3.0)
    assert upstream.ndbc_calls == 1                     # one fetch serves everyone


@pytest.mark.asyncio
async def test_a_down_ndbc_leaves_the_stations(client, upstream):
    upstream.ndbc_fail = True
    service = PressureService(client)
    resp = await service.get_station_obs_with_buoys(39.1, -84.5, half=3.0)
    assert resp.stations and all(s.kind == "metar" for s in resp.stations)
