"""Service-level tests: combined shape, caching, batching, graceful degradation."""

import pytest

from app.cache import StationRegistry, TTLCache
from app.service import PressureService
from app.scheduler import Scheduler


@pytest.fixture
def service(client):
    return PressureService(client, cache=TTLCache(), registry=StationRegistry())


async def test_combined_shape(service, upstream):
    resp = await service.get_combined("KLUK", 39.1, -84.5)
    assert resp.pressure.station == "KLUK"
    assert resp.pressure.source == "aviationweather.gov"
    assert len(resp.pressure.series) == 4
    # presTend -2.4 -> falling_mod (the raw §4.1 class is unchanged)
    assert resp.pressure.tendency.cls == "falling_mod"
    assert resp.pressure.tendency.delta3h == pytest.approx(-2.4)
    assert resp.forecast is not None and len(resp.forecast.hourly) == 12

    # Interpreter (§4.3) populated reading + sources.
    assert resp.reading is not None
    assert resp.reading.trend in ("falling", "falling_mod", "falling_fast")
    assert resp.sources is not None
    assert resp.sources.observed == "aviationweather.gov"
    assert resp.sources.forecast == "open-meteo"

    # Verdict reflects the interpreter (front-aware phrasing) and gets the
    # precip enrichment because we're in a falling situation.
    v = resp.verdict.lower()
    assert any(k in v for k in ("front", "trough", "falling", "drop", "bottom"))
    assert "Rain likely around" in resp.verdict

    # METAR-first wind: current wind comes from the newest METAR (10 kt / 230°,
    # gusting 18 kt), converted to km/h. Forecast hours carry model gusts.
    assert resp.pressure.current.windspeed == pytest.approx(18.5, abs=0.1)
    assert resp.pressure.current.winddir == 230.0
    assert resp.pressure.current.windgust == pytest.approx(33.3, abs=0.1)
    assert resp.forecast.hourly[0].windgust == pytest.approx(14.0)

    # Aviation conditions from the METAR: visibility "10+" -> 10.0 SM, the
    # ceiling is the lowest BKN/OVC layer, and fltCat passes through.
    assert resp.pressure.current.visibilitySM == 10.0
    assert resp.pressure.current.ceilingFt == 4500
    assert resp.pressure.current.ceilingCover == "BKN"
    assert resp.pressure.current.fltCat == "VFR"


async def test_combined_serializes_class_alias(service):
    resp = await service.get_combined("KLUK", 39.1, -84.5)
    dumped = resp.model_dump(mode="json", by_alias=True)
    assert dumped["pressure"]["tendency"]["class"] == "falling_mod"
    assert "cls" not in dumped["pressure"]["tendency"]


async def test_caching_avoids_second_upstream_call(service, upstream):
    await service.get_pressure("KLUK")
    assert len(upstream.awc_calls) == 1
    await service.get_pressure("KLUK")  # served from cache
    assert len(upstream.awc_calls) == 1


async def test_registry_tracks_requested_stations(service):
    await service.get_pressure("KLUK")
    await service.get_pressure("KCVG")
    active = await service.registry.active()
    assert active == ["KCVG", "KLUK"]


async def test_graceful_degradation_to_openmeteo(service, upstream):
    upstream.awc_fail = True
    resp = await service.get_pressure("KLUK")
    assert resp.source == "open-meteo (fallback)"
    assert len(resp.series) > 0  # rebuilt from surface_pressure
    assert resp.name == "Cincinnati Lunken, OH"


async def test_unknown_station_when_awc_down_degrades_honestly(service, upstream):
    upstream.awc_fail = True
    resp = await service.get_pressure("ZZZZ")  # not in station table
    assert resp.source == "unavailable"
    assert resp.series == []


async def test_scheduler_batches_active_stations(service, upstream):
    # register several stations
    for sid in ["KLUK", "KCVG", "KILN"]:
        await service.registry.touch(sid)
    sched = Scheduler(service, interval_seconds=600)
    calls = await sched.refresh_once()
    # all three fetched in a SINGLE batched request -> stays under 100/min
    assert calls == 1
    assert len(upstream.awc_calls) == 1
    assert set(upstream.awc_calls[0].url.params.get("ids").split(",")) == {
        "KLUK",
        "KCVG",
        "KILN",
    }
    # and the cache is now warm for each
    for sid in ["KLUK", "KCVG", "KILN"]:
        cached = await service.cache.get(f"pressure:{sid}:24")
        assert cached is not None and cached.station == sid


async def test_scheduler_no_active_stations(service):
    sched = Scheduler(service)
    assert await sched.refresh_once() == 0


async def test_user_agent_is_set(service, upstream):
    await service.get_pressure("KLUK")
    ua = upstream.awc_calls[0].headers.get("user-agent")
    assert ua == "Barry/1.0 (jrdn@wvr.me)"


# --- forecast stale-if-error -------------------------------------------------


async def test_forecast_stale_served_when_upstream_dies(service, upstream):
    # Prime the last-good store with a successful fetch.
    fresh = await service.get_forecast(39.1, -84.5)
    assert fresh.stale is False

    # Upstream dies; bypass the fresh cache to force a refetch attempt.
    upstream.om_fail = True
    stale = await service.get_forecast(39.1, -84.5, use_cache=False)
    assert stale.stale is True
    assert len(stale.hourly) == len(fresh.hourly)
    assert stale.source == "open-meteo"

    # Combined keeps the forecast (flagged) instead of dropping it.
    resp = await service.get_combined("KLUK", 39.1, -84.5)
    assert resp.forecast is not None and resp.forecast.stale is True
    assert resp.sources.forecast == "open-meteo"


async def test_forecast_none_when_upstream_dies_cold(upstream, client):
    # No last-good primed → combined degrades to no forecast, as before.
    from app.cache import StationRegistry, TTLCache
    from app.service import PressureService

    cold = PressureService(client, cache=TTLCache(), registry=StationRegistry())
    upstream.om_fail = True
    resp = await cold.get_combined("KLUK", 39.1, -84.5)
    assert resp.forecast is None
    assert resp.sources.forecast is None
