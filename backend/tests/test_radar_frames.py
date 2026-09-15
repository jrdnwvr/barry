"""/radar/frames: RainViewer's frame list, trimmed and shared."""

from __future__ import annotations

import pytest

from app.service import PressureService


@pytest.mark.asyncio
async def test_frames_trimmed_to_timeline(client, upstream):
    resp = await PressureService(client).get_radar_frames()
    assert resp.host == "https://tilecache.rainviewer.com"
    assert len(resp.frames) == 7 + 2                 # last 7 past + the 2 nowcast on offer
    assert [f.nowcast for f in resp.frames] == [False] * 7 + [True] * 2
    times = [f.time for f in resp.frames]
    assert times == sorted(times)
    assert resp.frames[6].path == "/v2/radar/p12"    # the newest observed frame
    assert resp.frames[7].path == "/v2/radar/n00"


@pytest.mark.asyncio
async def test_one_upstream_call_serves_everyone(client, upstream):
    service = PressureService(client)
    await service.get_radar_frames()
    await service.get_radar_frames()
    assert upstream.rv_calls == 1


@pytest.mark.asyncio
async def test_failure_surfaces(client, upstream):
    upstream.rv_fail = True
    with pytest.raises(Exception):
        await PressureService(client).get_radar_frames()
