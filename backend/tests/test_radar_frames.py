"""/radar/frames with nothing held: an error the route turns into a 503,
never a stand-in (RainViewer stood in until 2026-10-03)."""

from __future__ import annotations

import httpx
import pytest

from app.service import PressureService


@pytest.mark.asyncio
async def test_no_frames_held_is_an_error_and_a_503(client, upstream, monkeypatch):
    monkeypatch.setenv("BARRY_MRMS", "1")
    s = PressureService(client)
    with pytest.raises(LookupError):
        await s.get_radar_frames()
    from app.main import app
    app.state.service = s
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        assert (await c.get("/radar/frames")).status_code == 503
