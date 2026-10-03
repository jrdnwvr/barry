"""A4: the front watch ring comes from bulk-snapshot history once it's deep
enough; the bbox fetch is only the cold-start path."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app.models import StationObs
from app.service import HISTORY_MIN_H, PressureService

ORIGIN = (39.103, -84.419)


def ring_table(at: datetime, hours_into_event: float) -> list[StationObs]:
    """Eight stations ~80 km around Lunken; the west half falls 0.8 hPa/h."""
    out = []
    for i in range(8):
        ang = i * 45.0
        import math
        lat = ORIGIN[0] + 0.72 * math.cos(math.radians(ang))
        lon = ORIGIN[1] + 0.92 * math.sin(math.radians(ang))
        west = 180 < ang < 360
        slp = 1015.0 - (0.8 * hours_into_event if west else 0.1 * hours_into_event)
        out.append(StationObs(id=f"KH{i}X", lat=lat, lon=lon, slp=round(slp, 1),
                              altim=round(slp + 0.5, 1), obsTime=at))
    return out


@pytest.mark.asyncio
async def test_ring_from_history_makes_no_bbox_call(client, upstream):
    service = PressureService(client)
    now = datetime.now(timezone.utc).replace(second=0, microsecond=0)
    # Nine hourly snapshots, the last one fresh.
    for h in range(9, -1, -1):
        at = now - timedelta(hours=h)
        service._record_snapshot(ring_table(at, 9 - h), at)
    assert service.history_span_h(now) >= HISTORY_MIN_H

    resp = await service.get_front("KLUK")
    assert not any(r.url.params.get("bbox") for r in upstream.awc_calls)
    assert len(resp.stations) == 8
    # The west half is the falling half.
    west = [s for s in resp.stations if 180 < s.bearingDeg < 360]
    assert all(s.tendency3h < -1.5 for s in west)
    assert resp.status in {"approaching", "passing", "forecast", "none", "passed"}


@pytest.mark.asyncio
async def test_cold_history_falls_back_to_bbox(client, upstream):
    upstream.bbox_pattern = "west_falls"
    service = PressureService(client)
    now = datetime.now(timezone.utc)
    service._record_snapshot(ring_table(now, 0), now)          # one snapshot: too shallow
    resp = await service.get_front("KLUK")
    assert any(r.url.params.get("bbox") for r in upstream.awc_calls)
    assert resp.stations


def test_snapshots_are_rate_limited_and_pruned(client):
    service = PressureService(client)
    now = datetime.now(timezone.utc)
    service._record_snapshot(ring_table(now - timedelta(hours=11), 0), now - timedelta(hours=11))
    service._record_snapshot(ring_table(now, 1), now)
    service._record_snapshot(ring_table(now, 1), now + timedelta(minutes=5))   # too soon
    assert len(service._bulk_history) == 1                                        # old one pruned, quick one skipped
    parsed = service._parsed_from_history(*ORIGIN)
    assert len(parsed) == 8 and all(len(v["series"]) == 1 for v in parsed.values())


@pytest.mark.asyncio
async def test_each_stations_reports_over_the_last_hours_are_served(client):
    """Four snapshots an hour apart hold two reports a station (METARs are
    hourly; the snapshots every 25 minutes repeat them): the series gives
    each report once, oldest first, with its wind and category, nearest
    station first; a snapshot from before the wind was kept is skipped,
    and so is a report older than the window."""
    service = PressureService(client)
    now = datetime(2026, 10, 2, 22, 0, tzinfo=timezone.utc)
    old = now - timedelta(hours=8)
    # An old-format snapshot (five fields), as the files held before.
    service._bulk_history.append((old, {"KLUK": (old, 1013.0, None, 39.1, -84.42)}))
    for h in (3, 2, 1, 0):
        at = now - timedelta(hours=h)
        obs_t = at.replace(minute=53) - timedelta(hours=1) if h else at.replace(minute=53) - timedelta(hours=1)
        table = [StationObs(id="KLUK", lat=39.1, lon=-84.42, obsTime=obs_t, windKt=8 + h, windDir=270, fltCat="VFR", slp=1013.0),
                 StationObs(id="KCVG", lat=39.05, lon=-84.67, obsTime=obs_t, windKt=12, windDir=250, gustKt=20, fltCat="MVFR", altim=1012.0),
                 StationObs(id="KSEA", lat=47.45, lon=-122.3, obsTime=obs_t, windKt=5, windDir=180, fltCat="IFR", slp=1010.0)]
        service._record_snapshot(table, at)
        service._record_snapshot(table, at + timedelta(minutes=30))     # the same reports again
    series = service.get_station_series(39.1, -84.4, half=1.0)
    assert [s.id for s in series.stations] == ["KLUK", "KCVG"]
    luk = series.stations[0]
    assert len(luk.reports) == 4 and [r.windKt for r in luk.reports] == [11, 10, 9, 8]
    assert luk.reports[-1].windDir == 270 and luk.reports[-1].fltCat == "VFR" and luk.reports[-1].gustKt is None
    assert series.stations[1].reports[0].gustKt == 20 and series.stations[1].reports[0].fltCat == "MVFR"
    assert all(r.t > int(old.timestamp()) for r in luk.reports)
    # The old-format snapshot still serves the ring and the past isobars.
    assert service._snapshot_points(old)[1] == [(39.1, -84.42, 1013.0)]

    from app.main import app
    import httpx
    app.state.service = service
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        r = await c.get("/metars/series?lat=39.1&lon=-84.4&half=1")
        assert r.status_code == 200 and [s["id"] for s in r.json()["stations"]] == ["KLUK", "KCVG"]
        assert "gustKt" not in r.json()["stations"][0]["reports"][0]
