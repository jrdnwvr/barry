"""The column: levels in feet and knots, cloud layers from runs of cover,
icing where cloud is below freezing, one upstream call per cell per hour."""
import httpx
import pytest

from app.models import AloftLevel
from app.service import PressureService
from app.sources import openmeteo as om
from conftest import sample_aloft


class _Req:
    class url:
        params = {"latitude": "39.1", "longitude": "-84.4"}


def test_parse_gives_feet_knots_and_layers():
    from datetime import datetime, timezone
    hours = om.parse_aloft(sample_aloft(_Req()), now=datetime.now(timezone.utc))
    assert len(hours) == 3
    h = hours[0]
    assert [lv.hPa for lv in h.levels] == [1000, 975, 950, 925, 900, 850, 800, 700, 600, 500, 400]
    assert h.levels[0].ft == 361 and h.levels[-1].ft == 23950          # 110 m and 7,300 m
    assert h.levels[5].spdKt == pytest.approx(10 + 1470 / 200)
    assert h.freezingFt == 8858 and h.blAglFt == 2953
    assert h.surface.tempC == 16 and h.surface.spdKt == 10
    assert [(c.baseFt, c.coverPct, c.icing) for c in h.clouds] == [(2592, 80, False), (14108, 40, True)]
    deck, thin = h.clouds
    assert deck.topFt == 4823                                        # the top of the 850 level
    assert thin.topFt == 14108 + (18701 - 14108) // 2                # a lone level: half way to the next


def test_layers_from_runs_of_cover():
    def lv(ft, cloud, temp=10.0):
        return AloftLevel(hPa=900, ft=ft, tempC=temp, cloudPct=cloud)
    levels = [lv(1000, 10), lv(2000, 60), lv(3000, 90), lv(4000, 20), lv(5000, 55, -5.0), lv(6000, 10)]
    layers = om.cloud_layers(levels)
    assert [(c.baseFt, c.topFt, c.coverPct, c.icing) for c in layers] == [(2000, 3000, 90, False), (5000, 5500, 55, True)]
    assert om.cloud_layers([lv(1000, 10), lv(2000, 10)]) == []
    top = om.cloud_layers([lv(1000, 10), lv(2000, 70)])
    assert top[0].topFt == 3000                                       # the highest level: a nominal thousand


@pytest.mark.asyncio
async def test_one_call_per_cell_per_hour_and_a_route(client, upstream):
    s = PressureService(client)
    a = await s.get_aloft(39.12, -84.43)
    b = await s.get_aloft(39.08, -84.38)                                # same tenth-degree cell
    assert a.hours and a is b and upstream.aloft_calls == 1
    await s.get_aloft(40.0, -84.4)
    assert upstream.aloft_calls == 2
    from app.main import app
    app.state.service = s
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        r = await c.get("/aloft?lat=39.1&lon=-84.4")
        assert r.status_code == 200
        body = r.json()
        assert body["hours"][0]["clouds"][0]["coverPct"] == 80 and body["hours"][0]["levels"][0]["hPa"] == 1000
        assert (await c.get("/aloft?lat=91&lon=0")).status_code == 422
        upstream.om_fail = True
        s.cache._store.clear()
        assert (await c.get("/aloft?lat=45&lon=-100")).status_code == 503
