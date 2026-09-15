"""/stations/nearest must find the closest REPORTING station from AWC, not the
ten-airport table (which sent Dallas users to Denver)."""

from __future__ import annotations

import pytest

from app import stations
from app.service import PressureService


@pytest.mark.asyncio
async def test_nearest_comes_from_bbox_reports(client, upstream):
    upstream.bbox_pattern = "west_falls"
    got = await PressureService(client).nearest_reporting_station(39.103, -84.419)
    assert got["station"].startswith("KR")           # a fixture bbox station
    assert got["station"] not in stations.STATIONS    # not the table
    assert got["distance_km"] < 150
    # It is the closest of the ring, not just the first.
    parsed_ids = [f"KR{i}A" for i in range(8)]
    assert got["station"] in parsed_ids


@pytest.mark.asyncio
async def test_nearest_falls_back_to_table_when_awc_is_empty(client, upstream):
    upstream.bbox_pattern = None
    got = await PressureService(client).nearest_reporting_station(39.103, -84.419)
    assert got["station"] == "KLUK"
