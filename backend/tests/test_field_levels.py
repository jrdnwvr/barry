"""Winds at the altitude slider's stops: from the HRRR store (test_hrrr_feed
and test_radar_timeline cover a held run); with no run held, no points and
no stand-in."""
import httpx
import pytest

from app.service import PressureService


@pytest.mark.asyncio
async def test_no_run_held_gives_no_points(client, upstream):
    s = PressureService(client)
    r = await s.get_field_levels(39.1, -84.4, 4.0, 6.0)
    assert r.points == [] and r.source is None
    g = await s.get_field_grid(39.1, -84.4, 4.0, 6.0)
    assert g.points == [] and g.source is None
    from app.main import app
    app.state.service = s
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        r = await c.get("/radar/field/levels?lat=39.1&lon=-84.4&latSpan=4&lonSpan=6")
        assert r.status_code == 200 and r.json()["points"] == []
        assert (await c.get("/radar/field/levels?lat=39.1&lon=-84.4&latSpan=inf&lonSpan=6")).status_code == 422
