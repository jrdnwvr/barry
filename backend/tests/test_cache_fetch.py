import asyncio

import pytest

from app.cache import CachedFailure, TTLCache
from app.service import PressureService
from app.sources import aviationweather as awc


@pytest.mark.asyncio
async def test_concurrent_misses_share_one_fetch():
    c = TTLCache()
    calls = 0
    async def fn():
        nonlocal calls
        calls += 1
        await asyncio.sleep(0.01)
        return "v"
    got = await asyncio.gather(*(c.fetch("k", fn, ttl=60) for _ in range(20)))
    assert got == ["v"] * 20 and calls == 1


@pytest.mark.asyncio
async def test_failures_are_remembered_for_negative_ttl():
    t = [0.0]
    c = TTLCache(clock=lambda: t[0])
    calls = 0
    async def fn():
        nonlocal calls
        calls += 1
        raise RuntimeError("down")
    with pytest.raises(RuntimeError):
        await c.fetch("k", fn, ttl=60, negative_ttl=30)
    with pytest.raises(CachedFailure):
        await c.fetch("k", fn, ttl=60, negative_ttl=30)
    assert calls == 1
    assert await c.get("k") is None            # a plain read never sees the failure
    t[0] += 31
    with pytest.raises(RuntimeError):
        await c.fetch("k", fn, ttl=60, negative_ttl=30)
    assert calls == 2


@pytest.mark.asyncio
async def test_cache_is_capped():
    t = [0.0]
    c = TTLCache(max_entries=3, clock=lambda: t[0])
    for i in range(6):
        t[0] += 1
        await c.set(f"k{i}", i, ttl=100)
    assert len(c._store) <= 3
    assert await c.get("k5") == 5


@pytest.mark.asyncio
async def test_concurrent_pressure_misses_cost_one_upstream_call(client, upstream):
    s = PressureService(client)
    await asyncio.gather(*(s.get_pressure("KLUK") for _ in range(10)))
    assert len(upstream.awc_calls) == 1


@pytest.mark.asyncio
async def test_bulk_outage_is_probed_once_per_window(client, upstream):
    s = PressureService(client)
    upstream.bulk_fail = True
    before = upstream.bulk_calls
    assert await s.metar_bulk() is None
    assert await s.metar_bulk() is None
    assert await s.metar_bulk() is None
    assert upstream.bulk_calls - before == 1


def test_one_bad_record_drops_one_station_not_the_batch():
    good = {"icaoId": "KLUK", "obsTime": 1_758_400_000, "slp": 1016.2, "temp": 20, "dewp": 12,
            "wspd": 8, "wdir": 240, "visib": 10, "clouds": [{"cover": "FEW", "base": 40}], "lat": 39.1, "lon": -84.4}
    bad = dict(good, icaoId="KBAD", clouds=[{"cover": "BKN", "base": "junk"}])
    out = awc.parse_records([good, bad])
    assert "KLUK" in out and "KBAD" not in out
