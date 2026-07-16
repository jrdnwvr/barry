"""HRRR forecast-radar metadata: the IEM run resolver + /radar/hrrr."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app.service import PressureService
from app.sources import iem


def _stamp(hours_back: int) -> str:
    run = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    return (run - timedelta(hours=hours_back)).strftime("%Y%m%d%H%M")


@pytest.mark.asyncio
async def test_resolves_current_hour_run(client, upstream):
    upstream.hrrr_run = _stamp(0)
    run = await iem.latest_hrrr_run(client)
    assert run is not None
    assert run.strftime("%Y%m%d%H%M") == upstream.hrrr_run


@pytest.mark.asyncio
async def test_walks_back_to_a_lagged_run(client, upstream):
    # HRRR lands on IEM 1-2 h after init; the resolver must walk back to it.
    upstream.hrrr_run = _stamp(2)
    run = await iem.latest_hrrr_run(client)
    assert run is not None
    assert run.strftime("%Y%m%d%H%M") == upstream.hrrr_run


@pytest.mark.asyncio
async def test_no_run_within_window_is_none(client, upstream):
    upstream.hrrr_run = _stamp(12)  # older than the walk-back window
    assert await iem.latest_hrrr_run(client) is None


@pytest.mark.asyncio
async def test_iem_down_is_none_not_crash(client, upstream):
    upstream.iem_fail = True
    assert await iem.latest_hrrr_run(client) is None


@pytest.mark.asyncio
async def test_service_caches_the_run(client, upstream):
    upstream.hrrr_run = _stamp(1)
    service = PressureService(client)
    first = await service.get_hrrr_meta()
    assert first.run.strftime("%Y%m%d%H%M") == upstream.hrrr_run
    # Second call is served from cache — no new IEM traffic.
    n_before = len(upstream.iem_calls)
    await service.get_hrrr_meta()
    assert len(upstream.iem_calls) == n_before


@pytest.mark.asyncio
async def test_service_raises_when_unavailable(client, upstream):
    service = PressureService(client)  # hrrr_run stays None
    with pytest.raises(LookupError):
        await service.get_hrrr_meta()
