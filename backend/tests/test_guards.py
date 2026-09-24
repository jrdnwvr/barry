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


def test_client_key_trusts_the_tunnel_header_only_from_a_private_peer():
    from app.guards import client_key
    assert client_key("172.18.0.5", "203.0.113.9") == "203.0.113.9"   # cloudflared container
    assert client_key("8.8.8.8", "203.0.113.9") == "8.8.8.8"         # public peer: header ignored
    assert client_key("127.0.0.1", None) == "127.0.0.1"


def test_ip_limiter_is_bounded_in_keys():
    from app.guards import IPLimiter
    lim = IPLimiter(per_minute=1000, max_keys=3)
    for i in range(10):
        assert lim.allow(f"10.0.0.{i}")
    assert len(lim._buckets) == 3


@pytest.mark.asyncio
async def test_per_ip_budget_returns_429_but_never_for_healthz(client):
    from app.main import app
    from app.guards import IPLimiter
    app.state.service = PressureService(client)
    app.state.ip_limiter = IPLimiter(per_minute=2)
    try:
        # raise_app_exceptions=False: /healthz has no scheduler state outside
        # the lifespan and would otherwise raise here instead of answering.
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app, raise_app_exceptions=False),
                                     base_url="http://t") as c:
            codes = [(await c.get("/pressure/KLUK")).status_code for _ in range(3)]
            assert codes == [200, 200, 429]
            # Exempt from the budget. (Without the lifespan there is no
            # scheduler state, so only the non-429 part is meaningful here.)
            assert (await c.get("/healthz")).status_code != 429
            # A different address behind the tunnel has its own budget.
            r = await c.get("/pressure/KLUK", headers={"cf-connecting-ip": "203.0.113.7"})
            assert r.status_code == 200
    finally:
        app.state.ip_limiter = IPLimiter(per_minute=0)


@pytest.mark.asyncio
async def test_docs_and_schema_are_not_served_by_default(client):
    from app.main import app
    app.state.service = PressureService(client)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app, raise_app_exceptions=False),
                                 base_url="http://t") as c:
        for path in ("/docs", "/redoc", "/openapi.json"):
            assert (await c.get(path)).status_code == 404, path


@pytest.mark.asyncio
async def test_upstream_failure_body_carries_no_upstream_detail(client):
    from unittest.mock import AsyncMock
    from app.main import app
    svc = PressureService(client)
    svc.get_radar_frames = AsyncMock(side_effect=RuntimeError("boom https://internal.example/tiles?key=abc"))
    app.state.service = svc
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app, raise_app_exceptions=False),
                                 base_url="http://t") as c:
        r = await c.get("/radar/frames")
        assert r.status_code == 503
        assert "example" not in r.text and "key=" not in r.text and "boom" not in r.text


@pytest.mark.asyncio
async def test_forecast_upstream_url_carries_the_cell_not_the_point(client, upstream):
    s = PressureService(client)
    await s.get_forecast(39.1234, -84.4321)
    url = str(upstream.om_calls[0].url)
    assert "latitude=39.1&" in url and "longitude=-84.4&" in url
    assert "39.1234" not in url and "84.4321" not in url


@pytest.mark.asyncio
async def test_bbox_fallbacks_stay_inside_the_awc_budget(client, upstream):
    from app.guards import RateLimited
    s = PressureService(client)
    s.awc_gate = RateGate(per_minute=0)
    with pytest.raises(RateLimited):
        await s._station_obs_bbox(39.1, -84.5)
    assert await s._nearest_via_bbox(39.1, -84.5) is None
    assert upstream.awc_calls == []
