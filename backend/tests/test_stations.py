"""Radar station layer: /metars wind observations around a point."""

from __future__ import annotations

import pytest

from app.service import PressureService


@pytest.mark.asyncio
async def test_station_obs_convert_to_knots(client, upstream):
    upstream.bbox_pattern = "west_falls"
    service = PressureService(client)
    resp = await service.get_station_obs(39.103, -84.419)
    assert len(resp.stations) == 8
    s = resp.stations[0]
    # Fixture records carry wspd 10 kt -> stored as 18.5 km/h -> back to 10 kt.
    assert s.windKt == 10
    assert s.windDir == 230
    assert s.gustKt is None
    assert s.obsTime is not None


@pytest.mark.asyncio
async def test_station_obs_cached_per_grid_cell(client, upstream):
    upstream.bbox_pattern = "west_falls"
    service = PressureService(client)
    await service.get_station_obs(39.103, -84.419)
    n = len([c for c in upstream.awc_calls if c.url.params.get("bbox")])
    await service.get_station_obs(39.15, -84.40)   # same 0.2° cell
    assert len([c for c in upstream.awc_calls if c.url.params.get("bbox")]) == n


@pytest.mark.asyncio
async def test_metars_carry_detail_fields(client, upstream):
    upstream.bbox_pattern = "west_falls"
    resp = await PressureService(client).get_station_obs(39.103, -84.419)
    st = resp.stations[0]
    assert st.raw and st.raw.startswith(st.id)
    assert st.name
    assert st.visibilitySM == 10.0
    assert st.ceilingFt == 4500 and st.ceilingCover == "BKN"
