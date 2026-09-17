"""Radar station layer: /metars served from the server's bulk METAR table."""

from __future__ import annotations

import pytest

from app.service import STATIONS_MAX, PressureService
from app.sources import aviationweather as awc
from conftest import metar_cache_row, sample_metar_cache


def test_cache_parser_reads_real_layout():
    stations = {s.id: s for s in awc.parse_metar_cache(sample_metar_cache())}
    assert "KQFV" not in stations                 # bogus -99.99 position dropped
    cvg = stations["KCVG"]
    assert cvg.windKt == 8 and cvg.gustKt == 15 and cvg.windDir == 120
    assert cvg.ceilingFt == 4000 and cvg.ceilingCover == "BKN"   # lowest BKN/OVC
    assert cvg.visibilitySM == 6 and cvg.fltCat == "MVFR"
    assert abs(cvg.altim - 1021.9) < 0.5            # 30.18 inHg -> hPa
    assert cvg.raw.startswith("METAR KCVG")
    assert stations["KLUK"].visibilitySM == 10 and stations["KLUK"].ceilingCover == "CLR"
    assert stations["KILN"].windDir is None         # VRB
    assert stations["KILN"].ceilingFt == 800
    assert stations["KSFO"].obsTime is not None
    # AWC's literal "null" category: derived from the rest of the report and flagged.
    assert stations["KSFO"].fltCat == "VFR" and stations["KSFO"].fltCatDerived is True
    assert stations["KCVG"].fltCatDerived is False


@pytest.mark.asyncio
async def test_slice_comes_from_bulk_without_bbox_calls(client, upstream):
    service = PressureService(client)
    resp = await service.get_station_obs(39.103, -84.419, half=3.0)
    ids = {s.id for s in resp.stations}
    assert ids == {"KLUK", "KCVG", "KILN"}          # KSFO is outside the box
    assert upstream.bulk_calls == 1
    assert not any(r.url.params.get("bbox") for r in upstream.awc_calls)


@pytest.mark.asyncio
async def test_bulk_table_is_shared_across_points(client, upstream):
    service = PressureService(client)
    await service.get_station_obs(39.103, -84.419)
    resp = await service.get_station_obs(37.6, -122.4)
    assert {s.id for s in resp.stations} == {"KSFO"}
    assert upstream.bulk_calls == 1                 # one pull served both


@pytest.mark.asyncio
async def test_dense_area_is_thinned_to_a_grid(client, upstream):
    # 900 stations on a 30x30 lattice inside the box.
    upstream.bulk_extra_rows = [
        metar_cache_row(f"KT{i:03d}", 39.0 + (i // 30) * 0.15, -85.0 + (i % 30) * 0.15)
        for i in range(900)
    ]
    resp = await PressureService(client).get_station_obs(41.0, -83.0, half=3.0)
    assert len(resp.stations) <= STATIONS_MAX + 15
    assert len(resp.stations) > 100               # thinned, not gutted


@pytest.mark.asyncio
async def test_falls_back_to_bbox_when_bulk_is_down(client, upstream):
    upstream.bulk_fail = True
    upstream.bbox_pattern = "west_falls"
    resp = await PressureService(client).get_station_obs(39.103, -84.419)
    assert len(resp.stations) == 8
    assert resp.stations[0].windKt == 10            # km/h -> kt on the old path
    assert any(r.url.params.get("bbox") for r in upstream.awc_calls)
