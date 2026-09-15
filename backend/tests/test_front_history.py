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
