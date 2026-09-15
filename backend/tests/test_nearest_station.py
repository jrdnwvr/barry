"""/stations/nearest: closest REPORTING station from the bulk METAR table,
with the old bbox query and the built-in table only as fallbacks."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app import stations
from app.models import StationObs
from app.service import PressureService, _nearest_in_table


@pytest.mark.asyncio
async def test_nearest_from_bulk_table_no_awc_query(client, upstream):
    got = await PressureService(client).nearest_reporting_station(39.103, -84.419)
    assert got["station"] == "KLUK" and got["distance_km"] < 1
    assert not any(r.url.params.get("bbox") for r in upstream.awc_calls)


@pytest.mark.asyncio
async def test_nearest_prefers_a_station_with_pressure(client, upstream):
    # A closer station with no altimeter must lose to one that reports pressure.
    upstream.bulk_extra_rows = [
        '"METAR KNOP 151650Z 27007KT 10SM CLR 20/10",KNOP,2026-09-15T16:50:00.000Z,39.1030,-84.4190,20,10,270,7,,10+,,,,,TRUE,,,,,,,CLR,,,,,,,,VFR,,,,,,,,,,,,METAR,100',
    ]
    got = await PressureService(client).nearest_reporting_station(39.103, -84.419)
    assert got["station"] == "KLUK"


def test_fresh_report_beats_a_closer_stale_one():
    now = datetime(2026, 9, 15, 17, 0, tzinfo=timezone.utc)
    stale = StationObs(id="KOLD", lat=39.10, lon=-84.42, altim=1013.0,
                       obsTime=now - timedelta(hours=9))
    fresh = StationObs(id="KNEW", lat=39.30, lon=-84.42, altim=1013.0,
                       obsTime=now - timedelta(minutes=20))
    got = _nearest_in_table([stale, fresh], 39.10, -84.42, now)
    assert got["station"] == "KNEW"
    # With nothing fresh around, the stale one is still better than nothing.
    assert _nearest_in_table([stale], 39.10, -84.42, now)["station"] == "KOLD"


@pytest.mark.asyncio
async def test_falls_back_to_bbox_then_table(client, upstream):
    upstream.bulk_fail = True
    upstream.bbox_pattern = "west_falls"
    got = await PressureService(client).nearest_reporting_station(39.103, -84.419)
    assert got["station"].startswith("KR") and got["station"] not in stations.STATIONS

    upstream.bbox_pattern = None
    got = await PressureService(client).nearest_reporting_station(47.6, -122.3)
    assert got["station"] == "KSEA"
