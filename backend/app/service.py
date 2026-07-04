"""Service layer: orchestrates sources + cache into the normalized responses.

This is where caching, the active-station registry, and graceful degradation live,
so both the HTTP routes and the scheduled worker share one code path.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Optional

import httpx

from . import stations
from .cache import StationRegistry, TTLCache
from .interpreter import Sample, interpret
from .models import (
    CombinedResponse,
    CurrentObs,
    ForecastResponse,
    PressureResponse,
    ReadingOut,
    SeriesPoint,
    Sources,
    TendencyOut,
)
from .sources import aviationweather as awc
from .sources import openmeteo as om
from .tendency import resolve_tendency
from .verdict import build_verdict

PRESSURE_TTL = 12 * 60.0  # METARs update ~hourly; 12 min keeps it fresh-ish & cheap
FORECAST_TTL = 30 * 60.0  # forecasts move slowly; 30 min is plenty

# Stale-if-error: when Open-Meteo is down, re-serve the last good forecast for up
# to this long (flagged stale=True) — a 6-hour-old forecast beats no forecast.
STALE_FORECAST_MAX_AGE = 12 * 3600.0
# How long a stale answer is re-served before retrying the upstream.
STALE_RETRY_TTL = 5 * 60.0


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _tendency_out(t) -> Optional[TendencyOut]:
    if t is None:
        return None
    return TendencyOut(delta3h=t.delta3h, cls=t.cls, intensity=t.intensity)


class PressureService:
    def __init__(
        self,
        client: httpx.AsyncClient,
        *,
        cache: Optional[TTLCache] = None,
        registry: Optional[StationRegistry] = None,
    ) -> None:
        self._client = client
        self.cache = cache or TTLCache()
        self.registry = registry or StationRegistry()

    # ---- pressure (observed) -------------------------------------------------

    async def get_pressure(
        self, station: str, *, hours: int = 24, use_cache: bool = True
    ) -> PressureResponse:
        station = station.upper()
        await self.registry.touch(station)
        cache_key = f"pressure:{station}:{hours}"

        if use_cache:
            cached = await self.cache.get(cache_key)
            if cached is not None:
                return cached

        try:
            parsed_all = await awc.fetch_metars([station], self._client, hours=hours)
            parsed = parsed_all.get(station)
            if parsed is None:
                raise LookupError(f"no METAR data for {station}")
            tendency = awc.build_tendency(parsed)
            resp = PressureResponse(
                station=station,
                name=parsed.get("name") or (stations.get(station) or {}).get("name"),
                lat=parsed.get("lat"),
                lon=parsed.get("lon"),
                series=parsed["series"],
                current=parsed["current"],
                tendency=_tendency_out(tendency),
                source="aviationweather.gov",
                cachedAt=_now(),
            )
        except Exception:
            # Graceful degradation: rebuild the recent-past line from Open-Meteo
            # surface_pressure so the app degrades rather than dies (brief §2.3).
            resp = await self._pressure_fallback(station, hours=hours)

        await self.cache.set(cache_key, resp, ttl=PRESSURE_TTL)
        return resp

    async def _pressure_fallback(self, station: str, *, hours: int) -> PressureResponse:
        info = stations.get(station)
        if info is None:
            # Nothing we can do without coordinates — return an empty, honest shell.
            return PressureResponse(
                station=station,
                source="unavailable",
                cachedAt=_now(),
            )
        raw = await om.fetch_forecast(
            info["lat"], info["lon"], self._client, forecast_days=1, past_days=1
        )
        times, sp = om.parse_surface_pressure_series(raw)
        now = _now()
        series = [
            SeriesPoint(t=t, slp=v)
            for t, v in zip(times, sp)
            if v is not None and t <= now
        ]
        values = [p.slp for p in series]
        tendency = resolve_tendency(None, [p.t for p in series], values)
        current = CurrentObs(slp=series[-1].slp if series else None, presTend=None)
        return PressureResponse(
            station=station,
            name=info["name"],
            lat=info["lat"],
            lon=info["lon"],
            series=series,
            current=current,
            tendency=_tendency_out(tendency),
            source="open-meteo (fallback)",
            cachedAt=now,
        )

    # ---- forecast ------------------------------------------------------------

    async def get_forecast(
        self, lat: float, lon: float, *, use_cache: bool = True
    ) -> ForecastResponse:
        # round coords for a stable cache key — sub-0.1deg precision is noise here
        cache_key = f"forecast:{round(lat, 2)}:{round(lon, 2)}"
        last_good_key = f"{cache_key}:lastgood"
        if use_cache:
            cached = await self.cache.get(cache_key)
            if cached is not None:
                return cached

        try:
            raw = await om.fetch_forecast(lat, lon, self._client, forecast_days=2)
        except Exception:
            # Stale-if-error: the upstream is down — re-serve the last good
            # forecast (flagged) rather than dropping the whole enrichment layer.
            # Cached briefly so a dead upstream isn't hammered on every request.
            last_good = await self.cache.get(last_good_key)
            if last_good is not None:
                resp = last_good.model_copy(update={"stale": True})
                await self.cache.set(cache_key, resp, ttl=STALE_RETRY_TTL)
                return resp
            raise

        resp = ForecastResponse(
            hourly=om.parse_forecast(raw),
            source="open-meteo",
            cachedAt=_now(),
        )
        await self.cache.set(cache_key, resp, ttl=FORECAST_TTL)
        await self.cache.set(last_good_key, resp, ttl=STALE_FORECAST_MAX_AGE)
        return resp

    # ---- combined (primary client endpoint) ---------------------------------

    async def get_combined(
        self,
        station: str,
        lat: Optional[float] = None,
        lon: Optional[float] = None,
    ) -> CombinedResponse:
        pressure = await self.get_pressure(station)

        # Prefer explicit client coords; else the station's coords from AWC/table.
        f_lat = lat if lat is not None else pressure.lat
        f_lon = lon if lon is not None else pressure.lon

        forecast: Optional[ForecastResponse] = None
        if f_lat is not None and f_lon is not None:
            try:
                forecast = await self.get_forecast(f_lat, f_lon)
            except Exception:
                forecast = None  # forecast is enrichment; never block the response

        interp, local_offset = _run_interpreter(pressure, forecast)
        reading_out = _to_reading_out(interp) if interp is not None else None

        tendency_class = pressure.tendency.cls if pressure.tendency else None
        verdict = build_verdict(
            tendency_class,
            forecast.hourly if forecast else None,
            reading=interp,
            local_hour_offset=local_offset,
        )

        sources = Sources(
            observed=pressure.source,
            forecast=forecast.source if forecast else None,
        )
        return CombinedResponse(
            pressure=pressure,
            forecast=forecast,
            reading=reading_out,
            sources=sources,
            verdict=verdict,
        )


def _run_interpreter(
    pressure: PressureResponse,
    forecast: Optional[ForecastResponse],
):
    """Merge observed + forecast into a Sample list and run the interpreter.

    Returns (Reading | None, local_hour_offset). The offset is derived from the
    station's longitude (≈ 15°/hour) so the S2 de-tide and verdict times align
    with local solar time. Returns (None, 0.0) if there isn't enough data.
    """
    samples: list[Sample] = [
        Sample(t=p.t, p=p.slp, observed=True)
        for p in pressure.series
        if p.slp is not None
    ]
    if forecast is not None:
        samples.extend(
            Sample(t=h.t, p=h.pressure_msl, observed=False)
            for h in forecast.hourly
            if h.pressure_msl is not None
        )
    if len(samples) < 4:
        return None, 0.0

    local_offset = (pressure.lon / 15.0) if pressure.lon is not None else 0.0
    return interpret(samples, now=_now(), local_hour_offset=local_offset), local_offset


def _to_reading_out(reading) -> ReadingOut:
    return ReadingOut(
        trend=reading.trend,
        rate3h=reading.rate3h,
        steadiness=reading.steadiness,
        feature=reading.feature,
        featureTime=reading.featureTime,
        confidence=reading.confidence,
        caveats=list(reading.caveats),
    )
