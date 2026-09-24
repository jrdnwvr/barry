"""Winds at the altitude slider's stops: every level for every grid point,
one upstream call per region cell, ten variables so it counts once per point."""
import httpx
import pytest

from app.service import PressureService
from app.sources import openmeteo as om


@pytest.mark.asyncio
async def test_levels_for_every_point_in_one_call(client, upstream):
    s = PressureService(client)
    r = await s.get_field_levels(39.1, -84.4, 4.0, 6.0)
    assert len(r.points) == 35
    p = r.points[0]
    assert [lv.hPa for lv in p.levels] == [925, 850, 700, 600, 500]
    assert p.levels[0].windKmh == 20 and p.levels[-1].windKmh == 60 and p.levels[-1].windDeg == 260
    await s.get_field_levels(39.12, -84.41, 4.1, 6.1)          # same quantized region
    assert upstream.field_level_calls == 1
    assert len(om.FIELD_LEVELS) * 2 <= 10                     # one call per location in Open-Meteo's counting


@pytest.mark.asyncio
async def test_the_route_and_its_failure(client, upstream):
    from app.main import app
    s = PressureService(client)
    app.state.service = s
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        r = await c.get("/radar/field/levels?lat=39.1&lon=-84.4&latSpan=4&lonSpan=6")
        assert r.status_code == 200 and len(r.json()["points"]) == 35
        assert (await c.get("/radar/field/levels?lat=39.1&lon=-84.4&latSpan=inf&lonSpan=6")).status_code == 422
        upstream.om_fail = True
        s.cache._store.clear()
        assert (await c.get("/radar/field/levels?lat=20&lon=-100&latSpan=4&lonSpan=6")).status_code == 503
