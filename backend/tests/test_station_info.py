"""Station directory (A5): names on /metars and nearest, and /stations/search."""

from __future__ import annotations

import pytest

from app.service import PressureService


@pytest.mark.asyncio
async def test_names_flow_into_slice_and_nearest(client, upstream):
    service = PressureService(client)
    resp = await service.get_station_obs(39.103, -84.419)
    names = {s.id: s.name for s in resp.stations}
    assert names["KLUK"] == "Cincinnati/Lunken Fld, OH, US"
    assert names["KCVG"].startswith("Cincinnati/N Kentucky")
    near = await service.nearest_reporting_station(39.103, -84.419)
    assert near["name"] == "Cincinnati/Lunken Fld, OH, US"
    assert upstream.info_calls == 1                      # one pull, held a day


@pytest.mark.asyncio
async def test_search_by_id_prefix_then_name_metar_only(client, upstream):
    service = PressureService(client)
    got = await service.search_stations("kc")
    assert [r["station"] for r in got] == ["KCVG"]
    got = await service.search_stations("cincinnati")
    assert [r["station"] for r in got] == ["KLUK", "KCVG"]   # by position of the match
    assert await service.search_stations("taf") == []       # TAF-only sites don't report
    assert await service.search_stations("k") == []          # too short


@pytest.mark.asyncio
async def test_directory_outage_degrades_to_ids(client, upstream):
    upstream.info_fail = True
    service = PressureService(client)
    resp = await service.get_station_obs(39.103, -84.419)
    assert all(s.name is None for s in resp.stations)
    assert await service.search_stations("kluk") == []
