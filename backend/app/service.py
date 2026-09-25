"""Service layer: orchestrates sources + cache into the normalized responses.

This is where caching, the active-station registry, and graceful degradation live,
so both the HTTP routes and the scheduled worker share one code path.
"""

from __future__ import annotations

import asyncio
import logging
import math
import os

from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional

import httpx
import numpy as np

from . import conditions as conditions_mod
from .guards import OMBudget, RateGate, RateLimited, check_station
from . import explain
from . import fallbacks as fallbacks_mod
from . import modelfields
from .modelstore import ModelStore
from . import radar as radar_mod
from .radar import RadarStore
from . import flashes as flashes_mod
from . import lightning as lightning_mod
from . import persist
from . import pressure_field
from . import rainstart
from . import track
from . import runways
from . import route as route_mod
from . import front as front_mod
from . import stations
from .cache import CachedFailure, StationRegistry, TTLCache
from .interpreter import Sample, interpret
from .models import (
    AdvisoriesResponse,
    RouteFront,
    RouteLightning,
    RouteResponse,
    RouteStation,
    GlanceItem,
    GlanceResponse,
    HeightsResponse,
    LampOut,
    FieldLevelsResponse,
    AloftResponse,
    FieldGridResponse,
    LightningResponse,
    PressureFieldResponse,
    TrackRecordOut,
    TafOut,
    RadarFramesResponse,
    RadarFrameOut,
    CombinedResponse,
    CurrentObs,
    ForecastResponse,
    FrontResponse,
    FrontsResponse,
    HrrrMeta,
    PressureResponse,
    ReadingOut,
    SeriesPoint,
    Sources,
    StationObs,
    StationsResponse,
    TendencyOut,
)
from .models import ConditionsOut, RainOut
from .sources import aviationweather as awc
from .sources import glm
from .sources import advisories as adv
from .sources import hazards as hazards_src
from .sources import hrrr as hrrr_src
from .sources import rrfs as rrfs_src
from . import modelscore
from .sources import iem
from .sources import mrms
from .sources import nbm as nbm_src
from .sources import lamp as lamp_src
from .sources import ndbc
from .sources import openmeteo as om
from .sources import rainviewer as rv
from .sources import wpc
from .tendency import resolve_tendency
from .verdict import build_verdict

ALOFT_TTL = 60 * 60.0     # the model updates hourly; the column follows it
FIELD_LEVELS_TTL = 30 * 60.0   # winds aloft over a map region
ALOFT_STALE_MAX = 12 * 3600.0   # how long a last good column may stand in
PRESSURE_TTL = 12 * 60.0  # METARs update ~hourly; 12 min keeps it fresh-ish & cheap
FORECAST_TTL = 30 * 60.0  # forecasts move slowly; 30 min is plenty
FRONT_TTL = 15 * 60.0     # regional bbox fetch is the priciest call; ring METARs
                          # are hourly anyway, so 15 min loses nothing
HRRR_TTL = 10 * 60.0      # HRRR runs land hourly; re-probing IEM every 10 min
                          # keeps the run fresh at ~8 tiny tile requests/hour
FRONTS_TTL = 30 * 60.0    # WPC redraws the chart every 3 h; 30 min is plenty
STATIONS_TTL = 10 * 60.0  # radar station layer: METARs are hourly, specials aside
LIGHTNING_TTL = 60.0      # map slice of GLM flashes; the feed itself is polled per minute
GLM_LOOKBACK = timedelta(seconds=flashes_mod.WINDOW_S + 60)
GLM_CONCURRENCY = 4       # parallel file downloads per poll
BULK_TTL = 12 * 60.0      # AWC's whole-world METAR cache: one 250 KB pull serves everyone.
                          # Longer than the scheduler's 10 min cycle, which is what
                          # refreshes it; the TTL is only the net under a missed cycle.
SLICE_TTL = 2 * 60.0      # a box of stations cut from the bulk table (cheap)
GRID_TTL = 5 * 60.0       # a contour grid built from it (seconds of CPU)
FIELD_TTL = 10 * 60.0     # the shortest a model grid is held (see _until_model_hour)
GRID_STALE_MAX = 6 * 3600.0   # how long a grid's last good copy stands in when the budget is spent


def _until_model_hour(_value=None) -> float:
    """Seconds until five past the next hour, and never under FIELD_TTL:
    the model behind the radar's wind grids updates hourly, so fetching
    again inside the hour spends calls for the same numbers."""
    now = _now()
    nxt = now.replace(minute=5, second=0, microsecond=0)
    if nxt <= now:
        nxt += timedelta(hours=1)
    return max(FIELD_TTL, (nxt - now).total_seconds())
FRAMES_TTL = 2 * 60.0     # RainViewer adds a frame every 10 min; 2 min keeps the newest near-live
STATION_INFO_TTL = 24 * 3600.0  # AWC station directory: names change about never
TAF_TTL = 30 * 60.0       # TAFs issue every 6 h with amendments; 30 min is plenty
# Bulk-snapshot history for the front watch ring (A4): one snapshot at most
# every HISTORY_STEP_MIN, kept HISTORY_KEEP_H, usable once HISTORY_MIN_H deep.
HISTORY_STEP_MIN = 25.0
HISTORY_KEEP_H = 9.5
HISTORY_MIN_H = 7.5       # TRACK_LAG_H (4) + a 3 h delta at that epoch + slack
STATIONS_MAX = 350        # most annotation views a phone map should carry
BUOYS_TTL = 10 * 60.0     # NDBC's latest_obs: one fetch serves everyone
ADVISORIES_TTL = 10 * 60.0  # SIGMETs, G-AIRMETs, PIREPs: national feeds, one pull each for everyone
BUOYS_MAX = 120           # buoys added to a station slice, nearest first

# Stale-if-error: when Open-Meteo is down, re-serve the last good forecast for up
# to this long (flagged stale=True) — a 6-hour-old forecast beats no forecast.
STALE_FORECAST_MAX_AGE = 12 * 3600.0
# How long a stale answer is re-served before retrying the upstream.
STALE_RETRY_TTL = 5 * 60.0
# A degraded pressure answer (fallback curve or the empty shell) is held only
# briefly: the next app refresh should get a real try, not twelve minutes of
# "unavailable" because one keep-alive connection dropped after a restart.
DEGRADED_TTL = 45.0


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _tendency_out(t) -> Optional[TendencyOut]:
    if t is None:
        return None
    return TendencyOut(delta3h=t.delta3h, cls=t.cls, intensity=t.intensity)



log = logging.getLogger(__name__)


def _thin_stations(box, lat, lon, half, lon_half, limit):
    """Grid-thin to at most ~limit stations: one per cell, preferring the
    station with the fullest report (category, wind, longer raw text)."""
    if len(box) <= limit:
        return box
    n = max(1, int(math.sqrt(limit)))
    best = {}
    for s in box:
        r = min(n - 1, int((s.lat - (lat - half)) / (2 * half) * n))
        c = min(n - 1, int((s.lon - (lon - lon_half)) / (2 * lon_half) * n))
        score = (s.fltCat is not None, s.windKt is not None, len(s.raw or ""))
        cur = best.get((r, c))
        if cur is None or score > cur[0]:
            best[(r, c)] = (score, s)
    return [v[1] for v in best.values()]



NEAREST_FRESH_H = 3.0     # prefer a station that reported within this many hours
NEAREST_BOX_DEG = 5.0     # cheap pre-filter before the haversine pass


def _nearest_in_table(table, lat, lon, now):
    """Closest pressure-reporting station in the bulk table: a cheap box
    filter first, then haversine only on the survivors. Fresh reports win;
    a stale nearest is used only when nothing fresh is within the box."""
    from datetime import timedelta
    cutoff = now - timedelta(hours=NEAREST_FRESH_H)
    cos_lat = max(0.2, math.cos(math.radians(lat)))
    best_fresh = best_any = None
    for s in table:
        if s.altim is None:
            continue
        if abs(s.lat - lat) > NEAREST_BOX_DEG or abs(s.lon - lon) * cos_lat > NEAREST_BOX_DEG:
            continue
        d = stations._haversine_km(lat, lon, s.lat, s.lon)
        fresh = s.obsTime is not None and s.obsTime >= cutoff
        if fresh and (best_fresh is None or d < best_fresh[0]):
            best_fresh = (d, s)
        if best_any is None or d < best_any[0]:
            best_any = (d, s)
    pick = best_fresh or best_any
    if pick is None:
        return None
    d, s = pick
    return {"station": s.id, "name": s.name or s.id, "lat": s.lat, "lon": s.lon,
            "distance_km": round(d, 1)}


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
        # Client-driven upstream budgets. AWC allows 100/min per IP and the
        # scheduler shares that IP, so clients get well under half of it.
        self.awc_gate = RateGate(per_minute=30)
        # Weighted the way Open-Meteo counts (a call per location, more
        # for many variables), per minute and per UTC day.
        self.om_gate = OMBudget(per_minute=500, per_day=9000)
        # (fetch time, {station: (obsTime, slp, altim, lat, lon)}), oldest first.
        # Restored from disk when a data dir is configured, so a restart
        # doesn't cost the front watch its 7.5 h warm-up.
        self._bulk_history: List[tuple] = self._load_history()
        # {station: [call dicts]} — Barry's own trend calls, scored later.
        self._track_log: Dict[str, List[dict]] = persist.load("track_log") or {}
        self._track_dirty = False
        # When the bulk table last came back from AWC; the health check reads it.
        self.bulk_ok_at: Optional[datetime] = None
        # Stations watched before the last restart, so the scheduler's first
        # cycle warms them instead of waiting for each phone to ask again.
        self.registry.restore(persist.load("registry") or [])
        # GLM flashes (sources/glm.py), fed by the scheduler's minute poll.
        self.flashes = flashes_mod.FlashStore()
        # Contour builds are seconds of numpy each. Two at a time keeps a
        # sweep of distinct map centres from taking every core and, through
        # the GIL, the event loop with it; the rest wait their turn.
        self._grid_sem = asyncio.Semaphore(2)
        # LAMP station guidance (sources/lamp.py): the newest hourly run for
        # every site, fed by the scheduler's LAMP loop.
        self.lamp_table: Dict[str, LampOut] = {}
        self.lamp_run: Optional[datetime] = None
        self.lamp_ok_at: Optional[datetime] = None
        # Decoded model fields on disk (modelstore.py): HRRR today, fed by
        # the scheduler's model loop. BARRY_HRRR=0 keeps every map layer on
        # Open-Meteo.
        self.models = ModelStore.from_env()
        for feed in hrrr_src.RETIRED:
            self.models.drop(feed)
        self.hrrr_enabled = os.environ.get("BARRY_HRRR", "1") != "0"
        self.hrrr_ok_at: Optional[datetime] = None
        self._warmed: set = set()
        # Radar frames from MRMS (radar.py), fed by the scheduler's radar
        # loop; BARRY_MRMS=0 keeps the timeline on RainViewer.
        self.radar = RadarStore.from_env()
        self.ltg_next = RadarStore.from_env("ltgnext", radar_mod.LUT_LTG)
        self.mrms_enabled = os.environ.get("BARRY_MRMS", "1") != "0"
        # Pulled either way; served by default only when this says "mrms".
        # /radar/frames?source=mrms asks for Barry's frames regardless.
        self.radar_default = os.environ.get("BARRY_RADAR_SOURCE", "mrms")
        self.radar_ok_at: Optional[datetime] = None
        # The "rain starts at" line: the newest rain-rate grid (time, codes,
        # grid), the motion between the last two frames (base time, vy,
        # vx), a short cache of outlooks, and the calls kept for scoring.
        self._rain_rate: Optional[tuple] = None
        self._radar_motion: Optional[tuple] = None
        self._rain_cache: Dict[tuple, tuple] = {}
        self._rain_calls: Optional[List[dict]] = None
        self._rain_calls_dirty = False
        # Every answer served by a fallback instead of the NOAA feeds (fallbacks.py).
        self.fallbacks = fallbacks_mod.Log()
        self.public_url = os.environ.get("BARRY_PUBLIC_URL", "https://barry.wide-stack.com").rstrip("/")

    # ---- pressure (observed) -------------------------------------------------

    async def get_pressure(
        self, station: str, *, hours: int = 24, use_cache: bool = True
    ) -> PressureResponse:
        station = check_station(station)
        hours = max(1, min(24, hours))
        # One key per station, always the full day: `hours` used to be part of
        # the key, which let one client turn one station into hundreds of
        # distinct upstream fetches. A shorter window is sliced off the cached day.
        cache_key = f"pressure:{station}"

        if use_cache:
            cached = await self.cache.get(cache_key)
            if cached is not None:
                await self.registry.touch(cached.station)
                return self._slice_hours(cached, hours)

        async def _miss() -> PressureResponse:
            degraded = False
            try:
                parsed_all = await self._fetch_metars_retry([station], hours=24)
                parsed = parsed_all.get(station)
                used_station = station
                if parsed is None and len(station) == 3:
                    # US identifiers are commonly typed without the ICAO prefix
                    # (CVG -> KCVG) — and that includes alphanumeric fields
                    # (I67 -> KI67). Retry the K form and adopt it as canonical.
                    k_station = "K" + station
                    parsed_all = await self._fetch_metars_retry([k_station], hours=24)
                    parsed = parsed_all.get(k_station)
                    if parsed is not None:
                        used_station = k_station
                if parsed is None:
                    raise LookupError(f"no METAR data for {station}")
                # Only a station that actually answered joins the scheduler's list.
                await self.registry.touch(used_station)
                tendency = awc.build_tendency(parsed)
                elev = parsed.get("elev")
                if elev is None:
                    # Some reports omit it; the station directory has it.
                    try:
                        elev = ((await self.station_info()).get(used_station) or {}).get("elev")
                    except Exception:
                        elev = None
                resp = PressureResponse(
                    station=used_station,
                    name=parsed.get("name") or (stations.get(used_station) or {}).get("name"),
                    lat=parsed.get("lat"),
                    lon=parsed.get("lon"),
                    elevM=elev,
                    series=parsed["series"],
                    current=parsed["current"],
                    tendency=_tendency_out(tendency),
                    source="aviationweather.gov",
                    cachedAt=_now(),
                )
            except Exception as exc:
                # Graceful degradation: rebuild the recent-past line from Open-Meteo
                # surface_pressure so the app degrades rather than dies (brief §2.3).
                log.warning("pressure %s: upstream failed (%s: %s); falling back",
                            station, type(exc).__name__, exc)
                degraded = True
                resp = await self._pressure_fallback(station, hours=24)

            return resp
        resp = await self.cache.fetch(
            cache_key, _miss,
            ttl=lambda r: PRESSURE_TTL if r.source == "aviationweather.gov" else DEGRADED_TTL,
            bypass_read=not use_cache)
        return self._slice_hours(resp, hours)

    @staticmethod
    def _slice_hours(resp: PressureResponse, hours: int) -> PressureResponse:
        """The cached day, trimmed to the window asked for."""
        if hours >= 24 or not resp.series:
            return resp
        cutoff = _now() - timedelta(hours=hours)
        return resp.model_copy(update={"series": [p for p in resp.series if p.t >= cutoff]})

    async def _fetch_metars_retry(self, ids: List[str], *, hours: int) -> Dict[str, dict]:
        """One METAR fetch, retried once on a transport error. AWC closes idle
        keep-alive connections; the first reuse after a quiet minute can fail
        instantly with a dropped socket, and that must not become the answer.
        Gated: this is the client-driven path to AWC."""
        self.awc_gate.require()
        try:
            return await awc.fetch_metars(ids, self._client, hours=hours)
        except httpx.TransportError as exc:
            log.info("metar %s: transport error (%s), retrying once", ids, type(exc).__name__)
            return await awc.fetch_metars(ids, self._client, hours=hours)

    def _fell_back(self, kind: str, where: str, lat: Optional[float] = None,
                   lon: Optional[float] = None, reason: Optional[str] = None) -> None:
        """Record an answer the NOAA store could not give. Without a reason,
        it is `off` when the feed is switched off, `off-grid` when the point
        lies outside the HRRR domain, otherwise `no-data`."""
        if reason is None:
            if not self.hrrr_enabled:
                reason = "off"
            else:
                on = modelfields.on_grid(self.models, lat, lon) if lat is not None and lon is not None else None
                reason = "off-grid" if on is False else "no-data"
        try:
            self.fallbacks.note(kind, reason, where, _now())
        except Exception as exc:
            log.warning("fallback log failed: %s: %s", type(exc).__name__, exc)

    async def _pressure_fallback(self, station: str, *, hours: int) -> PressureResponse:
        self._fell_back("pressure", station, reason="upstream")
        info = stations.get(station)
        if info is None:
            # The small table misses most fields; the AWC directory has them all.
            try:
                d = (await self.station_info()).get(station) or {}
            except Exception:
                d = {}
            if d.get("lat") is not None and d.get("lon") is not None:
                info = {"name": d.get("name") or station, "lat": d["lat"], "lon": d["lon"]}
        if info is None:
            # Nothing we can do without coordinates — return an empty, honest shell.
            return PressureResponse(
                station=station,
                source="unavailable",
                cachedAt=_now(),
            )
        self.om_gate.require(om.FORECAST_WEIGHT)
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
        # 0.1 deg cells: finer than that is noise for a point forecast, and
        # at 0.01 a sweep of coordinates was an unbounded Open-Meteo bill.
        # The same cell goes upstream: one forecast per cell is what the cache
        # promises, and the precise point never leaves the server.
        lat, lon = round(lat, 1), round(lon, 1)
        # NOAA's models on Tower first (HRRR, with NBM over the first 36
        # hours); Open-Meteo off the HRRR grid or before a run is held.
        if self.hrrr_enabled:
            hkey = f"forecast-noaa:{lat}:{lon}:{modelfields.forecast_key(self.models)}"
            cached = await self.cache.get(hkey) if use_cache else None
            if cached is not None:
                return cached
            got = await asyncio.to_thread(modelfields.forecast, self.models, lat, lon, _now())
            if got is not None:
                hours, sun, source = got
                resp = ForecastResponse(hourly=hours, sun=sun, source=source, cachedAt=_now())
                await self.cache.set(hkey, resp, ttl=FORECAST_TTL)
                return resp
        self._fell_back("forecast", f"{lat},{lon}", lat, lon)
        cache_key = f"forecast:{lat}:{lon}"
        last_good_key = f"{cache_key}:lastgood"
        if use_cache:
            cached = await self.cache.get(cache_key)
            if cached is not None:
                return cached

        try:
            self.om_gate.require(om.FORECAST_WEIGHT)
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
            sun=om.parse_daily_sun(raw),
            source="open-meteo",
            cachedAt=_now(),
        )
        await self.cache.set(cache_key, resp, ttl=FORECAST_TTL)
        await self.cache.set(last_good_key, resp, ttl=STALE_FORECAST_MAX_AGE)
        return resp

    # ---- front watch ---------------------------------------------------------

    async def get_front(
        self,
        station: str,
        lat: Optional[float] = None,
        lon: Optional[float] = None,
    ) -> FrontResponse:
        """Regional isallobaric analysis around the station (see front.py).

        Designed to be called AFTER /combined so the pressure + forecast caches
        are warm — the only genuinely new upstream cost is the bbox METAR fetch.
        """
        pressure = await self.get_pressure(station)
        f_lat = lat if lat is not None else pressure.lat
        f_lon = lon if lon is not None else pressure.lon
        now = _now()
        if f_lat is None or f_lon is None:
            return FrontResponse(station=pressure.station, status="none", cachedAt=now)

        cache_key = f"front:{pressure.station}:{round(f_lat, 1)}:{round(f_lon, 1)}"
        cached = await self.cache.get(cache_key)
        if cached is not None:
            return cached

        forecast: Optional[ForecastResponse] = None
        try:
            forecast = await self.get_forecast(f_lat, f_lon)
        except Exception:
            pass  # timing degrades to None; direction can still be called
        reading, _ = _run_interpreter(pressure, forecast)

        if self.history_span_h(now) >= HISTORY_MIN_H:
            # The ring from the server's own bulk-snapshot history: the same
            # per-station series the bbox fetch gave, no upstream call. The
            # delta/ring/track math is untouched (it is what the backtest
            # validated); only where the points come from changed.
            parsed = self._parsed_from_history(f_lat, f_lon)
        else:
            try:
                # Cold start (history still warming): 8 h of bbox history, the
                # current ring plus the same ring TRACK_LAG_H earlier. Inside
                # the budget like every other AWC call; a spent budget means
                # no ring, not a 503.
                self.awc_gate.require()
                parsed = await awc.fetch_metars_bbox(f_lat, f_lon, self._client, hours=8)
            except Exception:
                parsed = {}  # no regional field -> at most a "forecast" status

        ring = front_mod.ring_stations(
            parsed, origin_lat=f_lat, origin_lon=f_lon,
            exclude=pressure.station, now=now,
        )
        ring_prev = front_mod.ring_stations(
            parsed, origin_lat=f_lat, origin_lon=f_lon,
            exclude=pressure.station, now=now,
            at=now - timedelta(hours=front_mod.TRACK_LAG_H),
        )
        own = pressure.tendency.delta3h if pressure.tendency else None
        resp = front_mod.analyze(
            station=pressure.station, ring=ring, own_delta3h=own,
            reading=reading, now=now, ring_prev=ring_prev,
        )
        # Name the WPC-analyzed front the field is reacting to (enrichment;
        # never changes the backtested status logic).
        try:
            fronts = await self.get_fronts()
            resp.nearestFront = front_mod.nearest_wpc_front(fronts.frames, f_lat, f_lon)
        except Exception:
            pass
        await self.cache.set(cache_key, resp, ttl=FRONT_TTL)
        return resp

    # ---- HRRR forecast radar metadata ----------------------------------------

    async def get_hrrr_meta(self) -> HrrrMeta:
        """Latest HRRR run available on IEM (see sources/iem.py). Raises
        LookupError when IEM is unreachable or no recent run resolves — the
        client just skips the model frames."""
        cache_key = "hrrr:run"
        return await self.cache.fetch(cache_key, self._resolve_hrrr, ttl=HRRR_TTL, negative_ttl=60.0)

    async def _resolve_hrrr(self) -> HrrrMeta:
        run = await iem.latest_hrrr_run(self._client)
        if run is None:
            raise LookupError("no HRRR run available")
        resp = HrrrMeta(run=run, cachedAt=_now())
        return resp

    # ---- station wind layer --------------------------------------------------

    async def metar_bulk(self, *, force: bool = False) -> Optional[List[StationObs]]:
        """Every station's latest METAR, from AWC's cache file, held for
        BULK_TTL. None when the pull fails (callers fall back to bbox).
        The scheduler passes force=True on every cycle so it, not the
        request path, is what refreshes the table; anyone asking during
        that pull joins it."""
        async def _pull():
            table = await awc.fetch_metar_cache(self._client)
            if not table:
                raise LookupError("empty METAR cache file")
            self._record_snapshot(table, _now())
            self.bulk_ok_at = _now()
            return table
        try:
            return await self.cache.fetch("metar_bulk", _pull, ttl=BULK_TTL,
                                          negative_ttl=DEGRADED_TTL, bypass_read=force)
        except CachedFailure:
            return None
        except Exception as exc:
            log.warning("metar bulk cache fetch failed: %s", exc)
            return None

    # ---- Bulk history (the front watch ring without a bbox call) -------------

    def _record_snapshot(self, table: List[StationObs], now: datetime) -> None:
        """Keep a compact copy of each fresh bulk table so every station has
        ~9 h of (obsTime, pressure) points on the server, no upstream needed."""
        if self._bulk_history and \
           (now - self._bulk_history[-1][0]).total_seconds() < HISTORY_STEP_MIN * 60:
            return
        snap = {s.id: (s.obsTime, s.slp, s.altim, s.lat, s.lon)
                for s in table
                if s.obsTime is not None and (s.slp is not None or s.altim is not None)}
        self._bulk_history.append((now, snap))
        cutoff = now - timedelta(hours=HISTORY_KEEP_H)
        self._bulk_history = [h for h in self._bulk_history if h[0] >= cutoff]
        persist.save("bulk_history", self._bulk_history)

    async def flush_track_log(self) -> None:
        """Prune the verdict log and write it if anything changed. The
        scheduler calls this once a cycle and the app once at shutdown."""
        if track.prune_all(self._track_log, _now()):
            self._track_dirty = True
        if not self._track_dirty:
            return
        self._track_dirty = False
        await asyncio.to_thread(persist.save, "track_log", self._track_log)

    @staticmethod
    def _load_history() -> List[tuple]:
        hist = persist.load("bulk_history") or []
        cutoff = _now() - timedelta(hours=HISTORY_KEEP_H)
        # JSON gives lists back where tuples went in; re-tuple both levels.
        hist = [(h[0], {k: tuple(v) for k, v in h[1].items()})
                for h in hist if isinstance(h, (tuple, list)) and len(h) == 2 and h[0] >= cutoff]
        if hist:
            log.info("bulk history restored: %d snapshots, oldest %s", len(hist), hist[0][0])
        return hist

    def _tendency_points(self, now: datetime) -> List[tuple]:
        """(lat, lon, hPa per 3 h) for every station with a report now and one
        2 to 4 h ago in the snapshot history, same field for both ends."""
        if not self._bulk_history:
            return []
        latest = self._bulk_history[-1][1]
        out = []
        for sid, (t1, slp1, alt1, la, lo) in latest.items():
            if t1 is None or (now - t1).total_seconds() > 2 * 3600:
                continue
            best = None
            for _, snap in self._bulk_history[:-1]:
                rec = snap.get(sid)
                if rec is None or rec[0] is None:
                    continue
                span_h = (t1 - rec[0]).total_seconds() / 3600.0
                if 2.0 <= span_h <= 4.0 and (best is None or abs(span_h - 3.0) < abs(best[0] - 3.0)):
                    best = (span_h, rec)
            if best is None:
                continue
            span_h, (t0, slp0, alt0, _, _) = best
            if slp1 is not None and slp0 is not None:
                d = slp1 - slp0
            elif alt1 is not None and alt0 is not None:
                d = alt1 - alt0
            else:
                continue
            out.append((la, lo, round(d / span_h * 3.0, 2)))
        return out

    def history_span_h(self, now: datetime) -> float:
        if not self._bulk_history:
            return 0.0
        return (now - self._bulk_history[0][0]).total_seconds() / 3600.0

    def _parsed_from_history(self, lat: float, lon: float,
                             half_lat_deg: float = awc.BBOX_HALF_LAT_DEG) -> dict:
        """The same shape parse_records() gives a bbox fetch ({id: {lat, lon,
        series}}), assembled from the snapshots for stations in the box.
        Points are keyed by observation time, so overlapping snapshots
        don't duplicate a report."""
        lon_half = half_lat_deg / max(0.2, math.cos(math.radians(lat)))
        latest = self._bulk_history[-1][1]
        ids = [sid for sid, rec in latest.items()
               if abs(rec[3] - lat) <= half_lat_deg and abs(rec[4] - lon) <= lon_half]
        out = {}
        for sid in ids:
            seen = {}
            la = lo = None
            for _, snap in self._bulk_history:
                rec = snap.get(sid)
                if rec is None:
                    continue
                t, slp, alt, la, lo = rec
                seen[t] = SeriesPoint(t=t, slp=slp, altim=alt)
            out[sid] = {"lat": la, "lon": lo, "series": [seen[k] for k in sorted(seen)]}
        return out

    async def station_info(self) -> Dict[str, dict]:
        """The station directory (names, elevation, METAR/TAF flags), held a
        day. Empty when the pull fails: callers fall back to bare ids."""
        try:
            return await self.cache.fetch("station_info",
                                          lambda: awc.fetch_station_info(self._client),
                                          ttl=STATION_INFO_TTL, negative_ttl=60.0)
        except CachedFailure:
            return {}
        except Exception as exc:
            log.warning("station directory fetch failed: %s", exc)
            return {}

    async def search_stations(self, q: str, limit: int = 15) -> List[dict]:
        """Station search for the saved-places picker: id prefix first, then
        name substring, METAR-issuing sites only, case-insensitive."""
        q = q.strip().upper()
        if len(q) < 2:
            return []
        info = await self.station_info()
        by_id = [(sid, v) for sid, v in info.items() if v["metar"] and sid.startswith(q)]
        by_name = [(sid, v) for sid, v in info.items()
                   if v["metar"] and not sid.startswith(q) and q in v["name"].upper()]
        by_id.sort(key=lambda kv: kv[0])
        by_name.sort(key=lambda kv: (kv[1]["name"].upper().find(q), kv[1]["name"]))
        return [{"station": sid, "name": v["name"], "lat": v["lat"], "lon": v["lon"]}
                for sid, v in (by_id + by_name)[:limit]]

    PIREPS_MAX = 150   # nearest first; a continental view would otherwise carry hundreds of markers

    async def get_advisories(self, lat: float, lon: float, half: float = 6.0) -> AdvisoriesResponse:
        """The AWC advisories that touch a box around a point, cut from three
        national feeds held for ten minutes. A feed that fails is left out
        for a minute; the others still answer."""
        async def pull(key, fn):
            async def _p():
                self.awc_gate.require()
                return await fn(self._client)
            try:
                return await self.cache.fetch(key, _p, ttl=ADVISORIES_TTL, negative_ttl=60.0)
            except Exception:
                return []

        sigmets = await pull("adv:sigmets", adv.fetch_sigmets)
        gairmets = await pull("adv:gairmets", adv.fetch_gairmets)
        pireps = await pull("adv:pireps", adv.fetch_pireps)
        half = max(0.5, min(30.0, half))
        lon_half = half / max(0.2, math.cos(math.radians(lat)))
        lo_lat, hi_lat, lo_lon, hi_lon = lat - half, lat + half, lon - lon_half, lon + lon_half

        def touches(points):
            lats = [p[0] for p in points]
            lons = [p[1] for p in points]
            return not (max(lats) < lo_lat or min(lats) > hi_lat or max(lons) < lo_lon or min(lons) > hi_lon)

        areas = [a for a in sigmets + gairmets if touches(a.points)]
        near = [p for p in pireps if lo_lat <= p.lat <= hi_lat and lo_lon <= p.lon <= hi_lon]
        near.sort(key=lambda p: (p.lat - lat) ** 2 + (p.lon - lon) ** 2)
        return AdvisoriesResponse(areas=areas, pireps=near[: self.PIREPS_MAX], cachedAt=_now())

    async def buoys(self) -> List[StationObs]:
        """Every NDBC buoy and coastal station's latest report, one fetch per
        ten minutes for everyone; a failure is remembered for a minute."""
        async def _pull():
            return await ndbc.fetch(self._client, now=_now())
        return await self.cache.fetch("buoys:all", _pull, ttl=BUOYS_TTL, negative_ttl=60.0)

    async def get_station_obs_with_buoys(self, lat: float, lon: float, half: float = 3.0) -> StationsResponse:
        """The METAR slice plus the buoys in the same box. Buoys are extra:
        if NDBC is down the slice still answers."""
        resp = await self.get_station_obs(lat, lon, half=half)
        half = round(max(0.5, min(30.0, half)) * 2) / 2
        lon_half = half / max(0.2, math.cos(math.radians(lat)))
        try:
            all_buoys = await self.buoys()
        except Exception:
            return resp
        box = [b for b in all_buoys if abs(b.lat - lat) <= half and abs(b.lon - lon) <= lon_half]
        box.sort(key=lambda b: (b.lat - lat) ** 2 + (b.lon - lon) ** 2)
        return StationsResponse(stations=resp.stations + box[:BUOYS_MAX], cachedAt=resp.cachedAt)

    async def get_station_obs(self, lat: float, lon: float, half: float = 3.0) -> StationsResponse:
        """Stations within ±half degrees of a point, sliced from the in-memory
        bulk table (no upstream call per user). Dense areas are thinned on a
        grid to STATIONS_MAX, keeping the fullest report per cell."""
        # Snap to half a degree: the client derives this from the map span,
        # so left raw every pan minted a fresh ~1 MB cache entry.
        half = round(max(0.5, min(30.0, half)) * 2) / 2
        cache_key = f"stations:{round(lat * 5) / 5}:{round(lon * 5) / 5}:{half}"
        cached = await self.cache.get(cache_key)
        if cached is not None:
            return cached
        table = await self.metar_bulk()
        if table is None:
            return await self._station_obs_bbox(lat, lon)

        lon_half = half / max(0.2, math.cos(math.radians(lat)))
        box = [s for s in table
               if abs(s.lat - lat) <= half and abs(s.lon - lon) <= lon_half]
        stations = _thin_stations(box, lat, lon, half, lon_half, STATIONS_MAX)
        info = await self.station_info()
        if info:
            stations = [s.model_copy(update={"name": info.get(s.id, {}).get("name")})
                        if s.name is None else s for s in stations]
        resp = StationsResponse(stations=stations, cachedAt=_now())
        await self.cache.set(cache_key, resp, ttl=SLICE_TTL)
        return resp

    async def _station_obs_bbox(self, lat: float, lon: float) -> StationsResponse:
        """Fallback when the bulk cache is unavailable: one bbox METAR call
        (±1.4°), cached by 0.2° cell."""
        cache_key = f"stations:{round(lat * 5) / 5}:{round(lon * 5) / 5}"
        cached = await self.cache.get(cache_key)
        if cached is not None:
            return cached
        self.awc_gate.require()
        parsed = await awc.fetch_metars_bbox(lat, lon, self._client, hours=2)
        stations = []
        for sid, p in parsed.items():
            cur: CurrentObs = p["current"]
            if p.get("lat") is None or p.get("lon") is None:
                continue
            kt = round(cur.windspeed / 1.852, 0) if cur.windspeed is not None else None
            gust = round(cur.windgust / 1.852, 0) if cur.windgust is not None else None
            stations.append(StationObs(
                id=sid, lat=p["lat"], lon=p["lon"], name=p.get("name"),
                windKt=kt, windDir=cur.winddir, gustKt=gust, fltCat=cur.fltCat,
                obsTime=p["series"][-1].t if p.get("series") else None,
                visibilitySM=cur.visibilitySM, ceilingFt=cur.ceilingFt,
                ceilingCover=cur.ceilingCover, temp=cur.temp,
                dewpoint=cur.dewpoint, altim=cur.altim, raw=p.get("raw"),
            ))
        resp = StationsResponse(stations=stations, cachedAt=_now())
        await self.cache.set(cache_key, resp, ttl=STATIONS_TTL)
        return resp

    async def nearest_reporting_station(self, lat: float, lon: float) -> dict:
        """The closest station that reports pressure, from the in-memory bulk
        METAR table (no upstream call). A station whose latest report is
        older than 3 h is passed over if a fresh one is nearby. Falls back to
        an AWC bbox query when the bulk table is unavailable, and to the
        built-in table as a last resort."""
        cache_key = f"nearest:{round(lat * 5) / 5}:{round(lon * 5) / 5}"
        cached = await self.cache.get(cache_key)
        if cached is not None:
            return cached

        best = None
        table = await self.metar_bulk()
        if table is not None:
            best = _nearest_in_table(table, lat, lon, _now())
            if best is not None:
                info = await self.station_info()
                if best["station"] in info:
                    best["name"] = info[best["station"]]["name"]
        if best is None:
            best = await self._nearest_via_bbox(lat, lon)
        if best is None:
            fallback = stations.nearest(lat, lon)
            if fallback is None:
                raise LookupError("no stations known")
            sid, info, dist = fallback
            best = {"station": sid, "name": info["name"], "lat": info["lat"],
                    "lon": info["lon"], "distance_km": round(dist, 1)}
        await self.cache.set(cache_key, best, ttl=STATIONS_TTL)
        return best

    async def _nearest_via_bbox(self, lat: float, lon: float) -> Optional[dict]:
        """Old path: one or two bbox METAR calls. Only when the bulk pull failed."""
        best = None
        for half in (1.4, 4.0):
            try:
                self.awc_gate.require()
                parsed = await awc.fetch_metars_bbox(
                    lat, lon, self._client, hours=3, half_lat_deg=half)
            except Exception:
                parsed = {}
            for sid, p in parsed.items():
                if p.get("lat") is None or p.get("lon") is None:
                    continue
                if not any(pt.slp is not None or pt.altim is not None
                           for pt in p.get("series", [])):
                    continue
                d = stations._haversine_km(lat, lon, p["lat"], p["lon"])
                if best is None or d < best["distance_km"]:
                    best = {"station": sid, "name": p.get("name") or sid,
                            "lat": p["lat"], "lon": p["lon"], "distance_km": round(d, 1)}
            if best is not None:
                break
        return best

    # ---- TAF ------------------------------------------------------------------

    async def get_taf(self, station: str) -> Optional[TafOut]:
        """The station's TAF, decoded; None where none is issued. One call per
        station per 30 min; enrichment, never blocks /combined."""
        cache_key = f"taf:{station.upper()}"
        cached = await self.cache.get(cache_key)
        if cached is not None:
            return cached or None
        try:
            self.awc_gate.require()
            taf = await awc.fetch_taf(station, self._client)
        except Exception as exc:
            log.warning("taf fetch failed for %s: %s", station, exc)
            return None
        await self.cache.set(cache_key, taf or False, ttl=TAF_TTL)
        return taf

    # ---- HRRR (AWS, NOMADS fallback) -------------------------------------------

    async def poll_hrrr(self) -> int:
        """Pull, for each HRRR feed (the map layers, the Aloft column's first
        hours and its day ahead), the newest cycle not held yet. Returns the
        number of fields written, 0 when nothing was new. One feed failing
        does not stop the others."""
        written = 0
        errors = []
        for spec in hrrr_src.FEEDS + (rrfs_src.SFC,):
            try:
                pick = await hrrr_src.choose(self._client, _now(), self.models.cycles(spec.name), spec)
                if pick is None:
                    continue
                cycle, source = pick
                n = await hrrr_src.pull(self._client, self.models, spec, cycle, source)
                written += n
                await asyncio.to_thread(self.models.warm, spec.name, cycle)
                self._warmed.add((spec.name, cycle))
                if spec is hrrr_src.MAP:
                    self.hrrr_ok_at = _now()
                log.info("hrrr: %s %s from %s, %d fields", spec.name, cycle.strftime("%Y%m%d%H"), source, n)
            except Exception as exc:
                errors.append(exc)
                log.warning("hrrr: %s failed: %s: %s", spec.name, type(exc).__name__, exc)
        try:
            run = await nbm_src.choose(self._client, _now(), self.models.cycles(nbm_src.FEED))
            if run is not None:
                n = await nbm_src.pull(self._client, self.models, run)
                written += n
                await asyncio.to_thread(self.models.warm, nbm_src.FEED, run)
                self._warmed.add((nbm_src.FEED, run))
                log.info("nbm: %s, %d fields", run.strftime("%Y%m%d%H"), n)
        except Exception as exc:
            errors.append(exc)
            log.warning("nbm: failed: %s: %s", type(exc).__name__, exc)
        try:
            await self._score_models()
        except Exception as exc:
            log.warning("model scores failed: %s: %s", type(exc).__name__, exc)
        # After a restart the store is on disk but nothing is open yet.
        for name in [spec.name for spec in hrrr_src.FEEDS] + [nbm_src.FEED]:
            for cycle in self.models.cycles(name)[:1]:
                if (name, cycle) not in self._warmed:
                    await asyncio.to_thread(self.models.warm, name, cycle)
                    self._warmed.add((name, cycle))
        if errors and not written:
            raise errors[0]
        return written

    async def poll_hazards(self) -> int:
        """The newest GTG turbulence and CIP icing runs from NOMADS, each
        when not held. Fields written; a product failing leaves the other."""
        written = 0
        for p in hazards_src.PRODUCTS:
            try:
                n = await hazards_src.poll(self._client, self.models, p, _now())
                if n:
                    log.info("hazards: %s %d fields", p.feed, n)
                written += n
            except Exception as exc:
                log.warning("hazards: %s failed: %s: %s", p.feed, type(exc).__name__, exc)
        return written

    async def _with_hazards(self, resp: AloftResponse, lat: float, lon: float) -> AloftResponse:
        if not self.hrrr_enabled:
            return resp
        try:
            turb, ice = await asyncio.to_thread(modelfields.hazards, self.models, lat, lon, _now())
        except Exception as exc:
            log.warning("hazards at a point failed: %s", exc)
            return resp
        if turb is None and ice is None:
            return resp
        return resp.model_copy(update={"turbulence": turb, "icing": ice})

    async def _score_models(self) -> Optional[dict]:
        """Score the hour nearest the newest METARs (modelscore.py), and fill
        in the hour before it if a model was still on its way then."""
        table = await self.metar_bulk() or []
        times = [s.obsTime for s in table if s.obsTime is not None]
        if not times:
            return None
        # The table holds each station's latest report: the hour to score
        # is the one most of them sit near (routine reports at :51 to :56
        # count for the next hour; stations that report every 20 minutes
        # scatter).
        top = _now().replace(minute=0, second=0, microsecond=0)
        near = lambda h: sum(1 for t in times if abs(t - h) <= modelscore.OBS_WINDOW)
        valid = max((top, top + timedelta(hours=1)), key=near)
        records = persist.load("model_scores") or []
        changed = None
        for hour in (valid, valid - timedelta(hours=1)):
            key = hour.isoformat()
            held = next((r for r in records if r.get("t") == key), None)
            rec = await asyncio.to_thread(modelscore.score_hour, self.models, table, hour, held)
            if rec is None:
                continue
            records = [r for r in records if r.get("t") != key] + [rec]
            changed = rec if changed is None else changed
        if changed is None:
            return None
        records = modelscore.prune(sorted(records, key=lambda r: r["t"]), _now())
        persist.save("model_scores", records)
        self._score_cache = records
        return changed

    def model_scores(self, days: int = 14) -> List[dict]:
        records = getattr(self, "_score_cache", None) or persist.load("model_scores") or []
        return modelscore.daily(records, days)

    def hrrr_run(self) -> Optional[datetime]:
        cycles = self.models.cycles(hrrr_src.FEED)
        return cycles[0] if cycles else None

    async def get_heights(self, lat: float, lon: float, lat_span: float, lon_span: float,
                          hpa: int) -> HeightsResponse:
        """Height contours at a pressure level for a map region, from the
        HRRR store. LookupError when the store has nothing for it."""
        if not self.hrrr_enabled:
            raise LookupError("hrrr off")
        lat_span = max(0.5, min(30.0, lat_span))
        lon_span = max(0.5, min(60.0, lon_span))
        q_lat, q_lon = round(lat * 10) / 10, round(lon * 10) / 10
        def q_span(v):
            return round(v * 2) / 2 if v >= 1 else round(v, 1)
        q_lat_span, q_lon_span = q_span(lat_span), q_span(lon_span)
        run = self.hrrr_run()
        key = f"heights:{hpa}:{q_lat}:{q_lon}:{q_lat_span}:{q_lon_span}:{run}"

        async def _build() -> HeightsResponse:
            now = _now()
            async with self._grid_sem:
                got = await asyncio.to_thread(modelfields.heights, self.models, hpa, q_lat, q_lon,
                                              q_lat_span, q_lon_span, now)
            if got is None:
                raise LookupError("no heights for this region")
            lines, step, cycle, fhr = got
            return HeightsResponse(hPa=hpa, intervalM=step, lines=lines, run=cycle,
                                   validTime=cycle + timedelta(hours=fhr), cachedAt=now)
        return await self.cache.fetch(key, _build, ttl=_until_model_hour, negative_ttl=60.0)

    # ---- LAMP (NOMADS) --------------------------------------------------------

    LAMP_MAX_AGE = timedelta(hours=6)

    async def poll_lamp(self) -> int:
        """Pull the newest hourly LAMP run when there is one we don't hold.
        Returns the number of stations read, 0 when nothing was new."""
        run = lamp_src.run_for(_now())
        if self.lamp_run is not None and run <= self.lamp_run:
            return 0
        try:
            table = await lamp_src.fetch(self._client, run)
        except httpx.HTTPStatusError as exc:
            # Late this hour. On a cold start, the hour before will do.
            if exc.response.status_code != 404 or self.lamp_run is not None:
                raise
            run -= timedelta(hours=1)
            table = await lamp_src.fetch(self._client, run)
        if not table:
            raise ValueError("empty LAMP bulletin")
        self.lamp_table, self.lamp_run, self.lamp_ok_at = table, run, _now()
        return len(table)

    def get_lamp(self, station: str) -> Optional[LampOut]:
        """The station's guidance from the current hour on, or None when the
        site has none or the run held is over six hours old."""
        st = self.lamp_table.get(station.upper())
        now = _now()
        if st is None or now - st.runTime > self.LAMP_MAX_AGE:
            return None
        start = now.replace(minute=0, second=0, microsecond=0)
        hours = [h for h in st.hours if h.t >= start]
        return LampOut(station=st.station, runTime=st.runTime, hours=hours) if hours else None

    # ---- Radar frames (RainViewer) -------------------------------------------

    RADAR_FRAMES = 7             # the last hour at ten minutes, as RainViewer gave; two hours are held
    RADAR_STALE_S = 20 * 60.0

    async def poll_radar(self) -> int:
        """Fetch the MRMS file nearest each ten-minute mark of the last two
        hours that isn't held, and drop frames older than that."""
        now = _now()
        keys = await mrms.recent_keys(self._client, now)
        wanted = mrms.pick(keys, now)
        got = 0
        for mark, key in sorted(wanted.items()):
            t = int(mark.timestamp())
            if self.radar.has(t):
                continue
            gz = await mrms.fetch(self._client, key)
            codes, grid = await asyncio.to_thread(mrms.decode, gz)
            await asyncio.to_thread(self.radar.put, t, codes, grid)
            got += 1
        oldest = min(wanted) if wanted else now - timedelta(hours=mrms.KEEP_H)
        self.radar.purge(int(oldest.timestamp()))
        try:
            await self._nowcast()
        except Exception as exc:
            log.warning("radar nowcast failed: %s: %s", type(exc).__name__, exc)
        try:
            await self._poll_lightning_next(now)
        except Exception as exc:
            log.warning("lightning probability failed: %s: %s", type(exc).__name__, exc)
        try:
            await self._poll_rain_rate(now)
        except Exception as exc:
            log.warning("rain rate failed: %s: %s", type(exc).__name__, exc)
        try:
            self._score_rain_calls(now)
        except Exception as exc:
            log.warning("rain call scoring failed: %s: %s", type(exc).__name__, exc)
        if self.radar.times():
            self.radar_ok_at = datetime.fromtimestamp(self.radar.times()[-1], tz=timezone.utc)
        return got

    async def _nowcast(self) -> int:
        """The next half hour from the newest frame: motion from it and the
        one ten minutes before (radar.motion), the newest frame carried 10,
        20 and 30 minutes forward. Made once per newest frame; older
        nowcasts are dropped. The motion is kept for the rain line, and
        found again after a restart even when the nowcast frames are on
        disk. Returns frames made."""
        obs = self.radar.observed()
        if len(obs) < 2 or obs[-1] - obs[-2] != self.radar.STEP_S:
            return 0
        t0, tp = obs[-1], obs[-2]
        have_casts = bool(self.radar.casts(t0))
        if have_casts and self._radar_motion is not None and self._radar_motion[0] == t0:
            return 0
        prev2, cur2 = self.radar.level(tp, radar_mod.MOTION_LEVEL), self.radar.level(t0, radar_mod.MOTION_LEVEL)
        cur0 = self.radar.level(t0, 0)
        grid = self.radar.grid
        if prev2 is None or cur2 is None or cur0 is None or grid is None:
            return 0
        vy, vx, _ = await asyncio.to_thread(radar_mod.motion, np.asarray(prev2), np.asarray(cur2))
        self._radar_motion = (t0, vy, vx)
        self._rain_cache.clear()
        if have_casts:
            return 0
        for k in (1, 2, 3):
            frame = await asyncio.to_thread(radar_mod.advect, np.asarray(cur0), vy, vx, float(k))
            await asyncio.to_thread(self.radar.put, t0 + k, frame, grid)
        self.radar.drop_casts_before(t0)
        return 3

    LTG_NEXT_MAX_AGE_S = 15 * 60.0

    async def _poll_lightning_next(self, now: datetime) -> bool:
        """The newest chance-of-lightning grid, when it is newer than the one
        held; the last three are kept so a phone mid-switch still finds its
        tiles."""
        keys = await mrms.recent_keys(self._client, now, mrms.LIGHTNING_NEXT, hours=0.25)
        if not keys:
            return False
        key = keys[-1]
        t = int(mrms.key_time(key).timestamp())
        if self.ltg_next.has(t):
            return False
        gz = await mrms.fetch(self._client, key)
        codes, grid = await asyncio.to_thread(mrms.decode, gz, "percent")
        await asyncio.to_thread(self.ltg_next.put, t, codes, grid)
        held = self.ltg_next.times()
        if len(held) > 3:
            self.ltg_next.purge(held[-3])
        return True

    def _lightning_next(self) -> Optional[RadarFrameOut]:
        held = self.ltg_next.times()
        if not held or _now().timestamp() - held[-1] > self.LTG_NEXT_MAX_AGE_S:
            return None
        return RadarFrameOut(time=held[-1], path=f"/radar/lightning/{held[-1]}")

    # ---- The "rain starts at" line ----------------------------------------------

    RAIN_RATE_MAX_AGE_S = 15 * 60.0        # older than this the grid says nothing about now
    RAIN_MOTION_MAX_AGE_S = 40 * 60.0
    RAIN_CACHE_S = 120.0
    RAIN_SCORE_AFTER = timedelta(minutes=15)   # how long after a predicted start the frames are read
    RAIN_SCORE_WINDOW_S = 15 * 60              # frames within this of the predicted start count
    RAIN_HIT_CODE = int((20 + 32) * 2)         # 20 dBZ on the composite: rain reaching the ground
    RAIN_CALL_KEEP_DAYS = 60

    async def _poll_rain_rate(self, now: datetime) -> bool:
        """The newest rain-rate grid, held in memory only (a restart waits
        two minutes for the next one)."""
        keys = await mrms.recent_keys(self._client, now, mrms.PRECIP_RATE, hours=0.25)
        if not keys:
            return False
        key = keys[-1]
        t = int(mrms.key_time(key).timestamp())
        if self._rain_rate is not None and self._rain_rate[0] >= t:
            return False
        gz = await mrms.fetch(self._client, key)
        codes, grid = await asyncio.to_thread(mrms.decode, gz, "rate")
        self._rain_rate = (t, codes, grid)
        self._rain_cache.clear()
        return True

    def rain_outlook(self, lat: float, lon: float, now: datetime) -> Optional[RainOut]:
        """Rain here now or within the next ninety minutes, from the newest
        rain-rate grid and the radar's motion (rainstart.py); None when
        neither is fresh, or nothing is coming. A "starts at" call is kept
        for scoring."""
        if self._rain_rate is None or self._radar_motion is None:
            return None
        t_rate, codes, grid = self._rain_rate
        base, vy, vx = self._radar_motion
        if now.timestamp() - t_rate > self.RAIN_RATE_MAX_AGE_S or now.timestamp() - base > self.RAIN_MOTION_MAX_AGE_S:
            return None
        key = (round(lat, 2), round(lon, 2), t_rate)
        hit = self._rain_cache.get(key)
        if hit is not None and hit[0] > now.timestamp():
            return hit[1]
        out = rainstart.outlook(codes, grid, vy, vx, lat, lon, now, datetime.fromtimestamp(t_rate, tz=timezone.utc))
        if len(self._rain_cache) > 2000:
            self._rain_cache.clear()
        self._rain_cache[key] = (now.timestamp() + self.RAIN_CACHE_S, out)
        if out is not None:
            self._note_rain_call(lat, lon, out, now)
        return out

    def _load_rain_calls(self) -> List[dict]:
        if self._rain_calls is None:
            self._rain_calls = persist.load("rain_calls") or []
        return self._rain_calls

    def _note_rain_call(self, lat: float, lon: float, out: RainOut, now: datetime) -> None:
        """Keep a "starts at" call, one per point and predicted start."""
        if out.status != "soon" or out.startsAt is None:
            return
        calls = self._load_rain_calls()
        la, lo = round(lat, 2), round(lon, 2)
        for c in calls:
            if c.get("lat") == la and c.get("lon") == lo and "hit" not in c \
               and abs((datetime.fromisoformat(c["start"]) - out.startsAt).total_seconds()) <= 600:
                return
        calls.append({"lat": la, "lon": lo, "at": now.isoformat(), "start": out.startsAt.isoformat()})
        self._rain_calls_dirty = True

    def _score_rain_calls(self, now: datetime) -> int:
        """Score the calls whose predicted start is far enough behind for
        the frames to have shown what happened: a hit when the composite
        had rain within 15 minutes of the predicted start. Returns the
        number scored."""
        calls = self._load_rain_calls()
        scored = 0
        for c in calls:
            if "hit" in c:
                continue
            start = datetime.fromisoformat(c["start"])
            if now < start + self.RAIN_SCORE_AFTER:
                continue
            ts = int(start.timestamp())
            frames = [t for t in self.radar.observed() if abs(t - ts) <= self.RAIN_SCORE_WINDOW_S]
            if not frames:
                c["hit"] = None                    # the frames are gone; unknown
            else:
                codes = [self.radar.max_code(t, c["lat"], c["lon"]) for t in frames]
                c["hit"] = any(v is not None and v >= self.RAIN_HIT_CODE for v in codes)
            scored += 1
        cut = (now - timedelta(days=self.RAIN_CALL_KEEP_DAYS)).isoformat()
        kept = [c for c in calls if c.get("at", "") >= cut]
        if scored or self._rain_calls_dirty or len(kept) != len(calls):
            self._rain_calls = kept
            persist.save("rain_calls", kept)
            self._rain_calls_dirty = False
        return scored

    def rain_scores(self, days: int = 14) -> dict:
        """How the "rain starts at" calls did: calls scored, hits, and the
        same by UTC day, newest first."""
        calls = self._load_rain_calls()
        done = [c for c in calls if c.get("hit") is not None]
        by_day: Dict[str, List[dict]] = {}
        for c in done:
            by_day.setdefault(c["at"][:10], []).append(c)
        hits = sum(1 for c in done if c["hit"])
        return {
            "calls": len(done), "hits": hits,
            "hitRate": round(hits / len(done), 2) if done else None,
            "pending": sum(1 for c in calls if "hit" not in c),
            "days": [{"day": d, "calls": len(v), "hits": sum(1 for c in v if c["hit"])}
                     for d in sorted(by_day, reverse=True)[:days] for v in [by_day[d]]],
        }

    def _mrms_frames(self) -> Optional[RadarFramesResponse]:
        obs = self.radar.observed()
        times = obs[-self.RADAR_FRAMES:]
        if len(times) < 4 or _now().timestamp() - times[-1] > self.RADAR_STALE_S:
            return None
        frames = [RadarFrameOut(time=t, path=f"/radar/tiles/{t}") for t in times]
        # The next half hour, marked as forecast, the way RainViewer's
        # nowcast frames were.
        base = times[-1]
        frames += [RadarFrameOut(time=base + (key - base) * self.radar.STEP_S, path=f"/radar/tiles/{key}",
                                 nowcast=True) for key in self.radar.casts(base)]
        return RadarFramesResponse(host=self.public_url, frames=frames,
                                   lightningNext=self._lightning_next(), cachedAt=_now())

    async def get_radar_frames(self, source: Optional[str] = None) -> RadarFramesResponse:
        """The radar timeline: Barry's own MRMS frames when an hour of them
        is held and fresh (and they are the default, or asked for);
        otherwise RainViewer's last 7 observed frames and up to 3 nowcast,
        from one call every two minutes for every user."""
        if self.mrms_enabled and (source or self.radar_default) == "mrms":
            own = self._mrms_frames()
            if own is not None:
                return own
            self._fell_back("radar", "radar", reason="stale" if self.radar.observed() else "no-data")
        else:
            self._fell_back("radar", "radar", reason="off")
        return await self.cache.fetch("radar_frames", lambda: rv.fetch_frames(self._client, now=_now()),
                                      ttl=FRAMES_TTL, negative_ttl=30.0)

    # ---- Pressure field: isobars + isallobars from the bulk table -----------

    async def get_pressure_field(self, lat: float, lon: float,
                                 lat_span: float, lon_span: float) -> PressureFieldResponse:
        """Contours for a map region from the in-memory bulk table. Quantized
        like the wind grid; cached for the bulk table's own lifetime."""
        lat_span = max(0.5, min(30.0, lat_span))
        lon_span = max(0.5, min(60.0, lon_span))
        q_lat, q_lon = round(lat * 10) / 10, round(lon * 10) / 10
        def q_span(v):
            return round(v * 2) / 2 if v >= 1 else round(v, 1)
        q_lat_span, q_lon_span = q_span(lat_span), q_span(lon_span)
        cache_key = f"pfield:{q_lat}:{q_lon}:{q_lat_span}:{q_lon_span}"
        cached = await self.cache.get(cache_key)
        if cached is not None:
            return cached
        # The build is CPU-bound and at a continental span takes seconds. It
        # used to run inline, freezing the single worker for every other
        # request; now it runs in a thread, and concurrent misses on the same
        # key wait for the one build already under way instead of each
        # starting their own.
        async def _build() -> PressureFieldResponse:
            table = await self.metar_bulk() or []
            now = _now()
            tend_pts = self._tendency_points(now) if self.history_span_h(now) >= 3.5 else None
            async with self._grid_sem:
                isobars, isallobars, pgrid, tgrid, textrema = await asyncio.to_thread(
                    pressure_field.build, table, q_lat, q_lon, q_lat_span, q_lon_span,
                    tend_pts=tend_pts)
            return PressureFieldResponse(isobars=isobars, isallobars=isallobars,
                                         pressureGrid=pgrid, tendencyGrid=tgrid,
                                         tendencyExtrema=textrema,
                                         stations=len(table), cachedAt=_now())
        return await self.cache.fetch(cache_key, _build, ttl=GRID_TTL)

    # ---- Radar model field (wind + boundary layer) ------------------------

    FIELD_COLS, FIELD_ROWS, FIELD_INSET = 7, 5, 0.12
    # From the store a point costs nothing, so the map gets more of them.
    HRRR_COLS, HRRR_ROWS = 11, 8

    async def get_field_grid(self, lat: float, lon: float,
                             lat_span: float, lon_span: float) -> FieldGridResponse:
        """The radar's 7x5 sample grid of model wind + boundary-layer top for
        a map region, from ONE Open-Meteo multi-point call. The region is
        quantized (center to 0.05°, spans to 0.5°) so users
        looking at the same area share the cache entry; the shift is far below
        the grid spacing."""
        lat_span = max(0.05, min(30.0, lat_span))
        lon_span = max(0.05, min(60.0, lon_span))
        q_lat, q_lon = round(lat * 20) / 20, round(lon * 20) / 20
        # Spans snap to 0.5° (0.1° when zoomed in) so the map's small aspect
        # and layout differences between devices land on the same entry.
        def q_span(v):
            return round(v * 2) / 2 if v >= 1 else round(v, 1)
        q_lat_span, q_lon_span = q_span(lat_span), q_span(lon_span)
        key = f"field:{q_lat}:{q_lon}:{q_lat_span}:{q_lon_span}"

        if self.hrrr_enabled:
            lats, lons = self._field_points(q_lat, q_lon, q_lat_span, q_lon_span,
                                            self.HRRR_COLS, self.HRRR_ROWS)
            now = _now()
            points = await asyncio.to_thread(modelfields.field_points, self.models, lats, lons, now)
            if points:
                return FieldGridResponse(points=points, source="hrrr", cachedAt=now)
        self._fell_back("field", f"{q_lat},{q_lon}", q_lat, q_lon)

        async def _pull() -> FieldGridResponse:
            lats, lons = self._field_points(q_lat, q_lon, q_lat_span, q_lon_span)
            now = _now()
            self.om_gate.require(om.field_grid_weight(len(lats)))
            points = await om.fetch_field_grid(lats, lons, self._client, now=now)
            resp = FieldGridResponse(points=points, source="open-meteo", cachedAt=now)
            await self.cache.set(f"{key}:lastgood", resp, ttl=GRID_STALE_MAX)
            return resp

        # Held until just past the next model hour: the model does not
        # change in between. A failure (or a spent budget) is remembered for
        # a minute and the last good grid is served meanwhile.
        try:
            return await self.cache.fetch(key, _pull, ttl=_until_model_hour, negative_ttl=60.0)
        except (RateLimited, CachedFailure, LookupError, httpx.HTTPError):
            last = await self.cache.get(f"{key}:lastgood")
            if last is None:
                raise
            return last

    # ---- Aloft: the column at a point -----------------------------------------

    async def get_aloft(self, lat: float, lon: float) -> AloftResponse:
        """The column (below) with what is there now: GTG turbulence and CIP
        icing at the point, read fresh on every request."""
        resp = await self._aloft_column(lat, lon)
        return await self._with_hazards(resp, lat, lon)

    async def _aloft_column(self, lat: float, lon: float) -> AloftResponse:
        """Clouds, temperatures and wind by pressure level for the next day
        at a point, keyed by the same tenth-degree cell as the forecast.
        From the HRRR column feeds on Tower where they cover the point;
        otherwise one Open-Meteo call per watched cell per hour, whatever
        the number of phones looking."""
        lat, lon = round(lat, 1), round(lon, 1)
        if self.hrrr_enabled:
            hkey = f"aloft-hrrr:{lat}:{lon}:{modelfields.column_key(self.models)}"
            cached = await self.cache.get(hkey)
            if cached is not None:
                return self._aloft_from_now(cached)
            start = _now().replace(minute=0, second=0, microsecond=0)
            hours = await asyncio.to_thread(modelfields.column, self.models, lat, lon, start)
            if hours:
                resp = AloftResponse(hours=hours, source="hrrr", cachedAt=_now())
                await self.cache.set(hkey, resp, ttl=ALOFT_TTL)
                return resp
        self._fell_back("aloft", f"{lat},{lon}", lat, lon)
        key = f"aloft:{lat}:{lon}"
        last_good_key = f"{key}:lastgood"

        async def _pull() -> AloftResponse:
            self.om_gate.require(om.ALOFT_WEIGHT)
            raw = await om.fetch_aloft(lat, lon, self._client, forecast_days=2)
            hours = om.parse_aloft(raw, now=_now())
            if not hours:
                raise LookupError("no aloft data")
            resp = AloftResponse(hours=hours, source="open-meteo", cachedAt=_now())
            await self.cache.set(last_good_key, resp, ttl=ALOFT_STALE_MAX)
            return resp

        try:
            return await self.cache.fetch(key, _pull, ttl=ALOFT_TTL, negative_ttl=60.0)
        except Exception:
            # Stale-if-error, like the forecast: Open-Meteo's pressure levels
            # fail in bursts, and the last good column, trimmed to the hours
            # still ahead, beats an empty screen.
            last = await self.cache.get(last_good_key)
            if last is None:
                raise
            hour = _now().replace(minute=0, second=0, microsecond=0)
            ahead = [h for h in last.hours if h.t >= hour]
            if len(ahead) < 2:
                raise
            return last.model_copy(update={"hours": ahead, "stale": True})

    @staticmethod
    def _aloft_from_now(resp: AloftResponse) -> AloftResponse:
        """A held column, trimmed to the hours still ahead."""
        hour = _now().replace(minute=0, second=0, microsecond=0)
        ahead = [h for h in resp.hours if h.t >= hour]
        return resp if len(ahead) == len(resp.hours) else resp.model_copy(update={"hours": ahead})

    def _field_points(self, q_lat: float, q_lon: float, q_lat_span: float, q_lon_span: float,
                      cols: Optional[int] = None, rows: Optional[int] = None):
        """The sample grid for a quantized map region: 7x5 from Open-Meteo,
        denser from the HRRR store."""
        cols, rows, inset = cols or self.FIELD_COLS, rows or self.FIELD_ROWS, self.FIELD_INSET
        h = q_lat_span * (1 - 2 * inset)
        w = q_lon_span * (1 - 2 * inset)
        lat0, lon0 = q_lat - h / 2, q_lon - w / 2
        lats = [lat0 + h * r / (rows - 1) for r in range(rows) for _ in range(cols)]
        lons = [lon0 + w * c / (cols - 1) for _ in range(rows) for c in range(cols)]
        return lats, lons

    async def get_field_levels(self, lat: float, lon: float,
                               lat_span: float, lon_span: float) -> FieldLevelsResponse:
        """The radar's wind grid at every altitude stop, for the same
        quantized region as get_field_grid. Only asked for when someone
        moves the altitude slider off the surface; winds aloft change
        slowly, so a region is held for half an hour."""
        lat_span = max(0.05, min(30.0, lat_span))
        lon_span = max(0.05, min(60.0, lon_span))
        q_lat, q_lon = round(lat * 20) / 20, round(lon * 20) / 20

        def q_span(v):
            return round(v * 2) / 2 if v >= 1 else round(v, 1)
        q_lat_span, q_lon_span = q_span(lat_span), q_span(lon_span)

        key = f"fieldlv:{q_lat}:{q_lon}:{q_lat_span}:{q_lon_span}"

        if self.hrrr_enabled:
            lats, lons = self._field_points(q_lat, q_lon, q_lat_span, q_lon_span,
                                            self.HRRR_COLS, self.HRRR_ROWS)
            now = _now()
            points = await asyncio.to_thread(modelfields.level_points, self.models, lats, lons, now)
            if points:
                return FieldLevelsResponse(points=points, source="hrrr", cachedAt=now)
        self._fell_back("levels", f"{q_lat},{q_lon}", q_lat, q_lon)

        async def _pull() -> FieldLevelsResponse:
            lats, lons = self._field_points(q_lat, q_lon, q_lat_span, q_lon_span)
            now = _now()
            self.om_gate.require(om.field_levels_weight(len(lats)))
            points = await om.fetch_field_levels(lats, lons, self._client, now=now)
            if not points:
                raise LookupError("no winds aloft")
            resp = FieldLevelsResponse(points=points, source="open-meteo", cachedAt=now)
            await self.cache.set(f"{key}:lastgood", resp, ttl=GRID_STALE_MAX)
            return resp

        try:
            return await self.cache.fetch(key, _pull, ttl=_until_model_hour, negative_ttl=60.0)
        except (RateLimited, CachedFailure, LookupError, httpx.HTTPError):
            last = await self.cache.get(f"{key}:lastgood")
            if last is None:
                raise
            return last

    # ---- GOES GLM lightning ---------------------------------------------------

    async def poll_lightning(self) -> int:
        """Pull every GLM file newer than the last one seen, per satellite,
        into the flash store. Returns files fetched. Never raises: an
        outage just means the store goes stale (coverage=False)."""
        import asyncio
        now = _now()
        store = self.flashes
        fetched = 0
        sem = asyncio.Semaphore(GLM_CONCURRENCY)

        async def grab(bucket, key, sat):
            nonlocal fetched
            async with sem:
                try:
                    fls = await glm.fetch_file(self._client, bucket, key)
                except Exception as exc:
                    log.warning("glm: %s failed: %s", key, exc)
                    return None
            fetched += 1
            own = glm.OWNED_SIDE[sat]
            return [f for f in fls if own(f.lon)]

        any_ok = False
        for sat, bucket in glm.BUCKETS.items():
            try:
                keys = await glm.list_recent(self._client, bucket, now, GLM_LOOKBACK)
            except Exception as exc:
                log.warning("glm: listing %s failed: %s", bucket, exc)
                continue
            any_ok = True
            last = store.seen.get(sat)
            todo = [k for k in keys if last is None or k > last]
            results = await asyncio.gather(*(grab(bucket, k, sat) for k in todo))
            batch = [f for r in results if r for f in r]
            store.add(batch, now)
            if todo:
                store.seen[sat] = max(todo)
        store.prune(now)
        if any_ok:
            store.last_fetch = now
            store.files += fetched
        return fetched

    async def get_lightning(self, lat: float, lon: float, half: float = 3.0) -> LightningResponse:
        """Binned GLM flashes around a point for the map's Storms overlay.
        Served from memory; quantized so nearby users share the slice."""
        half = round(max(0.5, min(6.0, half)) * 2) / 2
        key = f"lightning:{round(lat * 5) / 5}:{round(lon * 5) / 5}:{half}"
        cached = await self.cache.get(key)
        if cached is not None:
            return cached
        resp = self.flashes.response(lat, lon, half, _now())
        await self.cache.set(key, resp, ttl=LIGHTNING_TTL)
        return resp

    # ---- WPC surface fronts --------------------------------------------------

    async def get_fronts(self) -> FrontsResponse:
        """The WPC surface chart as data: analysis + 12/24/36/48 h forecast
        front positions (sources/wpc.py). Global, so one cache entry."""
        cache_key = "fronts"
        return await self.cache.fetch(cache_key, self._build_fronts, ttl=FRONTS_TTL, negative_ttl=60.0)

    async def _build_fronts(self) -> FrontsResponse:
        got = await wpc.fetch_fronts(self._client)
        frames = got["analysis"] + sorted(got["progs"], key=lambda f: f.hours)
        if not frames:
            raise LookupError("no WPC front bulletins available")
        return FrontsResponse(frames=frames, cachedAt=_now())

    # ---- combined (primary client endpoint) ---------------------------------

    GLANCE_MAX = 8

    def _glance_item(self, pressure, tz_minutes: Optional[int]) -> GlanceItem:
        interp, local_offset = _run_interpreter(pressure, None)
        if tz_minutes is not None:
            local_offset = tz_minutes / 60.0
        cls = pressure.tendency.cls if pressure.tendency else None
        cur = pressure.current
        kt = lambda kmh: round(kmh / 1.852, 1) if kmh is not None else None
        return GlanceItem(
            station=pressure.station, name=pressure.name, fltCat=cur.fltCat,
            windKt=kt(cur.windspeed), windDir=cur.winddir, gustKt=kt(cur.windgust),
            altim=cur.altim, slp=cur.slp,
            delta3h=pressure.tendency.delta3h if pressure.tendency else None,
            cls=cls,
            verdict=build_verdict(cls, None, reading=interp, local_hour_offset=local_offset),
            obsTime=pressure.series[-1].t if pressure.series else None,
        )

    async def get_glance(self, station_ids: List[str], tz_minutes: Optional[int] = None) -> GlanceResponse:
        """Each saved field in one line, from the same cached reports and the
        same interpreter as /combined, minus the forecast. Saved fields are
        watched stations, so the scheduler already keeps them fresh; a field
        that cannot be read is left out rather than failing the others."""
        items: List[GlanceItem] = []
        for sid in station_ids[: self.GLANCE_MAX]:
            try:
                pressure = await self.get_pressure(sid)
            except Exception:
                continue
            if not pressure.series:
                continue
            items.append(self._glance_item(pressure, tz_minutes))
        return GlanceResponse(items=items, cachedAt=_now())

    ROUTE_CORRIDOR_NM = 15.0
    ROUTE_LIGHTNING_NM = 30.0

    async def get_route(self, dep_id: str, dest_id: str, speed_kt: float = 100.0,
                        tz_minutes: Optional[int] = None) -> RouteResponse:
        """From one field to another in still air, from data already held:
        the two ends' reports, the METAR table along the corridor, the
        lightning store, the WPC analysis and the destination's TAF. Held
        five minutes per pair and speed."""
        key = f"route:{dep_id}:{dest_id}:{int(speed_kt)}"
        cached = await self.cache.get(key)
        if cached is not None:
            return cached
        dep_p = await self.get_pressure(dep_id)
        dest_p = await self.get_pressure(dest_id)
        if None in (dep_p.lat, dep_p.lon, dest_p.lat, dest_p.lon):
            raise LookupError("no coordinates for one end of the route")
        a, b = (dep_p.lat, dep_p.lon), (dest_p.lat, dest_p.lon)
        dist = route_mod.distance_nm(*a, *b)
        now = _now()
        ete = int(round(dist / max(1.0, speed_kt) * 60))
        arrive = now + timedelta(minutes=ete)

        # Along the corridor, from the bulk table.
        corridor: List[RouteStation] = []
        table = await self.metar_bulk() or []
        pad = self.ROUTE_CORRIDOR_NM / 60.0 + 0.5
        lo_lat, hi_lat = min(a[0], b[0]) - pad, max(a[0], b[0]) + pad
        lo_lon, hi_lon = min(a[1], b[1]) - pad * 1.5, max(a[1], b[1]) + pad * 1.5
        for st in table:
            if not (lo_lat <= st.lat <= hi_lat and lo_lon <= st.lon <= hi_lon):
                continue
            if st.id in (dep_p.station, dest_p.station):
                continue
            along, off = route_mod.track_position(a, b, (st.lat, st.lon))
            if off <= self.ROUTE_CORRIDOR_NM and 0 <= along <= dist:
                corridor.append(RouteStation(
                    id=st.id, name=st.name, lat=st.lat, lon=st.lon,
                    alongNm=round(along, 1), offNm=round(off, 1), fltCat=st.fltCat,
                    windKt=st.windKt, windDir=st.windDir, gustKt=st.gustKt,
                    lightning=st.lightning is not None))
        corridor.sort(key=lambda r: r.alongNm)
        worst_cat = route_mod.worst([r.fltCat for r in corridor])
        worst_st = next((r for r in corridor if r.fltCat == worst_cat), None) if worst_cat else None

        # Lightning near the line, from the GOES store.
        near: Optional[RouteLightning] = None
        if self.flashes.fresh(now):
            best = None
            count = 0
            for f in self.flashes.recent(now):
                if not (lo_lat - 1 <= f.lat <= hi_lat + 1 and lo_lon - 1 <= f.lon <= hi_lon + 1):
                    continue
                along, off = route_mod.track_position(a, b, (f.lat, f.lon))
                if off <= self.ROUTE_LIGHTNING_NM and -10 <= along <= dist + 10:
                    count += 1
                    if best is None or off < best[1]:
                        best = (along, off, f.t)
            if best is not None:
                near = RouteLightning(alongNm=round(max(0.0, best[0]), 1), offNm=round(best[1], 1),
                                      count=count, ageSec=max(0, int(now.timestamp() - best[2])))

        # Fronts the line crosses, from the WPC analysis.
        crossings: List[RouteFront] = []
        try:
            fr = await self.get_fronts()
            analysis = next((f for f in fr.frames if f.hours == 0), fr.frames[0] if fr.frames else None)
            if analysis is not None:
                crossings = [RouteFront(type=t, alongNm=round(d, 1))
                             for t, d in route_mod.front_crossings(a, b, analysis.fronts)]
        except Exception:
            crossings = []

        # The destination at the arrival time, by its TAF.
        arrive_cat = arrive_wkt = arrive_wdir = tempo = None
        has_taf = False
        try:
            taf = await self.get_taf(dest_p.station)
        except Exception:
            taf = None
        source = None
        if taf is not None and taf.periods:
            has_taf = True
            prevailing, temporary = route_mod.taf_at(taf.periods, arrive)
            if prevailing is not None:
                arrive_cat, arrive_wkt, arrive_wdir = prevailing.fltCat, prevailing.windKt, prevailing.windDir
                source = "taf"
            worse = [p for p in temporary if p.fltCat and arrive_cat
                     and route_mod.CATEGORY_RANK.get(p.fltCat, 9) < route_mod.CATEGORY_RANK.get(arrive_cat, 9)]
            if worse:
                p = min(worse, key=lambda q: route_mod.CATEGORY_RANK.get(q.fltCat, 9))
                tempo = f"{p.change} {p.fltCat}"

        # No TAF, or none covering the arrival: LAMP's hour nearest it.
        if arrive_cat is None:
            lamp = self.get_lamp(dest_p.station)
            if lamp is not None:
                h = min(lamp.hours, key=lambda h: abs((h.t - arrive).total_seconds()))
                if abs((h.t - arrive).total_seconds()) <= 90 * 60 and h.fltCat:
                    arrive_cat, arrive_wkt, arrive_wdir = h.fltCat, h.windKt, h.windDir
                    source = "lamp"

        resp = RouteResponse(
            dep=self._glance_item(dep_p, tz_minutes), dest=self._glance_item(dest_p, tz_minutes),
            depLat=a[0], depLon=a[1], destLat=b[0], destLon=b[1],
            distanceNm=round(dist, 1), speedKt=speed_kt, eteMin=ete, arriveAt=arrive,
            arriveCat=arrive_cat, arriveWindKt=arrive_wkt, arriveWindDir=arrive_wdir,
            arriveTempo=tempo, hasTaf=has_taf, arriveSource=source,
            sunsetMin=route_mod.minutes_from_sunset(b[0], b[1], arrive),
            corridorNm=self.ROUTE_CORRIDOR_NM, corridor=corridor, worst=worst_st,
            lightning=near, fronts=crossings, cachedAt=now)
        await self.cache.set(key, resp, ttl=5 * 60.0)
        return resp

    async def get_combined(
        self,
        station: str,
        lat: Optional[float] = None,
        lon: Optional[float] = None,
        tz_minutes: Optional[int] = None,
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

        if forecast is not None and "hrrr" in forecast.source:
            forecast = _anchor_pressure(forecast, pressure)
        interp, local_offset = _run_interpreter(pressure, forecast)
        # The client's real UTC offset beats the longitude/15 guess (which is
        # an hour off wherever daylight saving is in effect).
        if tz_minutes is not None:
            local_offset = tz_minutes / 60.0
        reading_out = _to_reading_out(interp) if interp is not None else None
        # What else agrees (observed signals + the model's view). Enrichment:
        # never blocks the response.
        taf: Optional[TafOut] = None
        try:
            taf = await self.get_taf(pressure.station)
        except Exception:
            taf = None

        if reading_out is not None:
            try:
                reading_out.explanation = explain.build(
                    interp, forecast.hourly if forecast else None, pressure.series,
                    _now(), local_hour_offset=local_offset, taf=taf,
                    current=pressure.current)
                reading_out.confidence, extra = explain.adjust_confidence(
                    reading_out.confidence, reading_out.explanation)
                reading_out.caveats = list(reading_out.caveats) + extra
            except Exception:
                reading_out.explanation = None

        tendency_class = pressure.tendency.cls if pressure.tendency else None
        verdict = build_verdict(
            tendency_class,
            forecast.hourly if forecast else None,
            reading=interp,
            local_hour_offset=local_offset,
        )

        # Nearest lightning report within 100 mi: real flashes from orbit
        # first, a station's own report when the mapper feed is stale or
        # sees nothing. Off the in-memory tables, no upstream call.
        nearby: Optional[lightning_mod.LightningNearby] = None
        try:
            if f_lat is not None and f_lon is not None:
                if self.flashes.fresh(_now()):
                    nearby = self.flashes.nearest(f_lat, f_lon, _now())
                if nearby is None:
                    table = await self.metar_bulk()
                    if table:
                        nearby = lightning_mod.nearest(table, f_lat, f_lon, _now())
                        if nearby is not None and nearby.name is None:
                            info = await self.station_info()
                            nearby.name = (info.get(nearby.station) or {}).get("name")
        except Exception:
            nearby = None

        # Field conditions (DA, clouds, layer, storms, fog) are enrichment —
        # never block the response. The storm row reads the same lightning.
        try:
            conditions = conditions_mod.build(pressure, forecast, _now(), taf=taf, nearby=nearby)
        except Exception:
            conditions = None
        if nearby is not None and conditions is not None and conditions.storm is not None \
           and conditions.storm.forecastEnd is not None:
            nearby.continuesUntil = conditions.storm.forecastEnd
        # The rain line, from the radar held on Tower. Enrichment.
        try:
            rain = self.rain_outlook(f_lat, f_lon, _now()) if f_lat is not None and f_lon is not None else None
        except Exception as exc:
            log.warning("rain outlook failed: %s: %s", type(exc).__name__, exc)
            rain = None
        if rain is not None:
            conditions = (conditions or ConditionsOut()).model_copy(update={"rain": rain})

        sources = Sources(
            observed=pressure.source,
            forecast=forecast.source if forecast else None,
        )
        # Log this call and score the old ones (C5/D6). Enrichment. Only a
        # real station reading is a call worth scoring; the model fallback
        # is not. The file is written by the scheduler once a cycle, not here.
        track_out: Optional[TrackRecordOut] = None
        try:
            if reading_out is not None and pressure.source == "aviationweather.gov":
                key = pressure.station
                log_ = track.record(self._track_log.get(key, []), _now(),
                                    reading_out.trend, reading_out.confidence)
                log_ = track.score(log_, pressure.series, _now())
                self._track_log[key] = log_
                self._track_dirty = True
                track_out = track.summary(log_)
        except Exception:
            track_out = None

        return CombinedResponse(
            pressure=pressure,
            forecast=forecast,
            reading=reading_out,
            conditions=conditions,
            runways=runways.for_station(pressure.station),
            taf=taf,
            lamp=self.get_lamp(pressure.station),
            trackRecord=track_out,
            lightningNearby=nearby,
            sources=sources,
            verdict=verdict,
        )


ANCHOR_MAX_HPA = 6.0


def _anchor_pressure(forecast: ForecastResponse, pressure: PressureResponse) -> ForecastResponse:
    """Shift the model's sea-level pressure so it meets the station's latest
    reading. HRRR reduces to sea level its own way (MAPS), a hPa or two off
    a station's SLP; left alone, the step where the dashed line starts
    reads as a rise or a fall that isn't happening. A constant shift keeps
    the model's shape, which is what the curve is read for. Left alone past
    6 hPa (a bad report) or with no forecast hour either side of the report."""
    obs = [p for p in pressure.series if p.slp is not None]
    hrs = [h for h in forecast.hourly if h.pressure_msl is not None]
    if not obs or len(hrs) < 2:
        return forecast
    last = obs[-1]
    before = [h for h in hrs if h.t <= last.t]
    after = [h for h in hrs if h.t >= last.t]
    if not before or not after:
        return forecast
    a, b = before[-1], after[0]
    span = (b.t - a.t).total_seconds()
    fv = a.pressure_msl if span == 0 else a.pressure_msl + (b.pressure_msl - a.pressure_msl) * (last.t - a.t).total_seconds() / span
    off = last.slp - fv
    if abs(off) > ANCHOR_MAX_HPA:
        return forecast
    hourly = [h.model_copy(update={"pressure_msl": round(h.pressure_msl + off, 1)}) if h.pressure_msl is not None else h
              for h in forecast.hourly]
    return forecast.model_copy(update={"hourly": hourly, "pressureOffset": round(off, 1)})


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
