"""The column: cloud layers from runs of cover, icing where cloud is below
freezing, and nothing when no run is held (the HRRR feeds are tested in
test_hrrr_feed)."""
import httpx
import pytest

from app import modelfields
from app.models import AloftLevel
from app.service import PressureService


def test_layers_from_runs_of_cover():
    def lv(ft, cloud, temp=10.0):
        return AloftLevel(hPa=900, ft=ft, tempC=temp, cloudPct=cloud)
    levels = [lv(1000, 10), lv(2000, 60), lv(3000, 90), lv(4000, 20), lv(5000, 55, -5.0), lv(6000, 10)]
    layers = modelfields.cloud_layers(levels)
    assert [(c.baseFt, c.topFt, c.coverPct, c.icing) for c in layers] == [(2000, 3000, 90, False), (5000, 5500, 55, True)]
    assert modelfields.cloud_layers([lv(1000, 10), lv(2000, 10)]) == []
    top = modelfields.cloud_layers([lv(1000, 10), lv(2000, 70)])
    assert top[0].topFt == 3000                                       # the highest level: a nominal thousand


@pytest.mark.asyncio
async def test_no_run_held_is_a_503_not_a_stand_in(client, upstream):
    s = PressureService(client)
    with pytest.raises(LookupError):
        await s.get_aloft(39.12, -84.43)
    from app.main import app
    app.state.service = s
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        assert (await c.get("/aloft?lat=39.1&lon=-84.4")).status_code == 503
        assert (await c.get("/aloft?lat=91&lon=0")).status_code == 422
    # The feed is off in this fixture; with it on and nothing held it reads no-data.
    assert ("aloft", "off", "39.1,-84.4") in {(e["kind"], e["reason"], e["where"]) for e in s.fallbacks.events()}
