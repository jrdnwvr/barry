"""/glance: the saved fields on one line each, for the Fields card."""

from __future__ import annotations

import pytest

from app.service import PressureService


@pytest.mark.asyncio
async def test_each_field_gets_one_line(client, upstream):
    service = PressureService(client)
    resp = await service.get_glance(["KLUK", "KI67"])
    ids = [i.station for i in resp.items]
    assert ids == ["KLUK", "KI67"]
    first = resp.items[0]
    assert first.cls and first.verdict
    assert first.altim is not None or first.slp is not None
    dumped = resp.model_dump(mode="json", by_alias=True)
    assert "class" in dumped["items"][0]


@pytest.mark.asyncio
async def test_a_field_that_cannot_be_read_is_left_out(client, upstream):
    service = PressureService(client)
    resp = await service.get_glance(["KLUK", "ZZZZ"])
    assert [i.station for i in resp.items] == ["KLUK"]


@pytest.mark.asyncio
async def test_glance_is_capped(client, upstream):
    service = PressureService(client)
    resp = await service.get_glance(["KLUK"] * 12)
    assert len(resp.items) == service.GLANCE_MAX


@pytest.mark.asyncio
async def test_the_route_rejects_junk_and_answers_for_real_ids(client):
    import httpx
    from app.main import app
    app.state.service = PressureService(client)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        r = await c.get("/glance?stations=KLUK,not%20a%20station")
        assert r.status_code == 422
        r = await c.get("/glance?stations=KLUK,KI67&tz=-240")
        assert r.status_code == 200
        assert [i["station"] for i in r.json()["items"]] == ["KLUK", "KI67"]
