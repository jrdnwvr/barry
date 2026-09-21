"""Abuse regressions: each asserts what reached upstream, not just a status."""
import asyncio

import httpx
import pytest

from app.cache import StationRegistry
from app.guards import InvalidStation, RateGate, RateLimited
from app.service import PressureService


def test_gate_is_a_token_bucket():
    t = [0.0]
    g = RateGate(per_minute=2, clock=lambda: t[0])
    assert g.take() and g.take() and not g.take()
    t[0] += 30.0                      # half a minute refills one token
    assert g.take() and not g.take()


@pytest.mark.asyncio
async def test_junk_station_never_reaches_upstream(client, upstream):
    s = PressureService(client)
    for bad in ("../etc", "K", "KLUK,KCVG", "KLUKX", "", "@OH"):
        with pytest.raises(InvalidStation):
            await s.get_pressure(bad)
    assert upstream.awc_calls == []
    assert await s.registry.active() == []


@pytest.mark.asyncio
async def test_hours_sweep_is_one_upstream_call(client, upstream):
    s = PressureService(client)
    for h in range(1, 25):
        resp = await s.get_pressure("KLUK", hours=h)
        assert resp.station == "KLUK"
    assert len(upstream.awc_calls) == 1
    short = await s.get_pressure("KLUK", hours=3)
    full = await s.get_pressure("KLUK", hours=24)
    assert len(short.series) <= len(full.series)


@pytest.mark.asyncio
async def test_registry_only_admits_stations_that_answered(client, upstream):
    s = PressureService(client)
    await s.get_pressure("ZZZZ")            # valid shape, no data: degrades
    assert "ZZZZ" not in await s.registry.active()
    await s.get_pressure("KLUK")
    assert "KLUK" in await s.registry.active()


@pytest.mark.asyncio
async def test_registry_is_capped():
    t = [0.0]
    r = StationRegistry(cap=3, clock=lambda: t[0])
    for i, st in enumerate(("AAAA", "BBBB", "CCCC", "DDDD")):
        t[0] = float(i)
        await r.touch(st)
    assert await r.active() == ["BBBB", "CCCC", "DDDD"]


@pytest.mark.asyncio
async def test_spent_budget_fails_fast_without_calling(client, upstream):
    s = PressureService(client)
    s.awc_gate = RateGate(per_minute=0)
    s.om_gate = RateGate(per_minute=0)
    with pytest.raises(RateLimited):
        await s.get_pressure("KLUK")
    assert upstream.awc_calls == [] and upstream.om_calls == []


@pytest.mark.asyncio
async def test_forecast_key_is_a_tenth_of_a_degree(client, upstream):
    s = PressureService(client)
    await s.get_forecast(39.101, -84.419)
    await s.get_forecast(39.104, -84.412)      # same 0.1 deg cell
    assert len(upstream.om_calls) == 1


@pytest.mark.asyncio
async def test_routes_reject_junk_before_the_service(client):
    from app.main import app
    app.state.service = PressureService(client)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        for url in ("/combined?station=../x", "/front?station=KLUK,KCVG", "/pressure/K", "/pressure/KLUK?hours=48"):
            r = await c.get(url)
            assert r.status_code == 422, url
        r = await c.get("/pressure/KLUK?hours=24")
        assert r.status_code == 200
