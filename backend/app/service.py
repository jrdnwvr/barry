"""Service layer: orchestrates sources + cache into the normalized responses.

This is where caching, the active-station registry, and graceful degradation live,
so both the HTTP routes and the scheduled worker share one code path.
"""

from __future__ import annotations

import logging
import math

from datetime import datetime, timedelta, timezone
from typing import Optional

import httpx

from . import conditions as conditions_mod
from . import explain
from . import persist
from . import runways
from . import front as front_mod
from . import stations
from .cache import StationRegistry, TTLCache
from .interpreter import Sample, interpret
from .models import (
    FieldGridResponse,
    RadarFramesResponse,
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
from .sources import aviationweather as awc
from .sources import iem
from .sources import openmeteo as om
from .sources import rainviewer as rv
from .sources import wpc
from .tendency import resolve_tendency
from .verdict import build_verdict

PRESSURE_TTL = 12 * 60.0  # METARs update ~hourly; 12 min keeps it fresh-ish & cheap
FORECAST_TTL = 30 * 60.0  # forecasts move slowly; 30 min is plenty
FRONT_TTL = 15 * 60.0     # regional bbox fetch is the priciest call; ring METARs
                          # are hourly anyway, so 15 min loses nothing
HRRR_TTL = 10 * 60.0      # HRRR runs land hourly; re-probing IEM every 10 min
                          # keeps the run fresh at ~8 tiny tile requests/hour
FRONTS_TTL = 30 * 60.0    # WPC redraws the chart every 3 h; 30 min is plenty
STATIONS_TTL = 10 * 60.0  # radar station layer: METARs are hourly, specials aside
BULK_TTL = 5 * 60.0       # AWC's whole-world METAR cache: one 250 KB pull serves everyone
FIELD_TTL = 10 * 60.0     # radar wind/BL grid: model updates hourly; one call per region cell
FRAMES_TTL = 2 * 60.0     # RainViewer adds a frame every 10 min; 2 min keeps the newest near-live
STATION_INFO_TTL = 24 * 3600.0  # AWC station directory: names change about never
# Bulk-snapshot history for the front watch ring (A4): one snapshot at most
# every HISTORY_STEP_MIN, kept HISTORY_KEEP_H, usable once HISTORY_MIN_H deep.
HISTORY_STEP_MIN = 25.0
HISTORY_KEEP_H = 9.5
HISTORY_MIN_H = 7.5       # TRACK_LAG_H (4) + a 3 h delta at that epoch + slack
STATIONS_MAX = 350        # most annotation views a phone map should carry

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
        # (fetch time, {station: (obsTime, slp, altim, lat, lon)}), oldest first.
        # Restored from disk when a data dir is configured, so a restart
        # doesn't cost the front watch its 7.5 h warm-up.
        self._bulk_history: List[tuple] = self._load_history()

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
            used_station = station
            if parsed is None and len(station) == 3:
                # US identifiers are commonly typed without the ICAO prefix
                # (CVG -> KCVG) — and that includes alphanumeric fields
                # (I67 -> KI67). Retry the K form and adopt it as canonical.
                k_station = "K" + station
                parsed_all = await awc.fetch_metars([k_station], self._client, hours=hours)
                parsed = parsed_all.get(k_station)
                if parsed is not None:
                    used_station = k_station
                    await self.registry.touch(used_station)
            if parsed is None:
                raise LookupError(f"no METAR data for {station}")
            tendency = awc.build_tendency(parsed)
            resp = PressureResponse(
                station=used_station,
                name=parsed.get("name") or (stations.get(used_station) or {}).get("name"),
                lat=parsed.get("lat"),
                lon=parsed.get("lon"),
                elevM=parsed.get("elev"),
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
                # current ring plus the same ring TRACK_LAG_H earlier.
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
        cached = await self.cache.get(cache_key)
        if cached is not None:
            return cached
        run = await iem.latest_hrrr_run(self._client)
        if run is None:
            raise LookupError("no HRRR run available")
        resp = HrrrMeta(run=run, cachedAt=_now())
        await self.cache.set(cache_key, resp, ttl=HRRR_TTL)
        return resp

    # ---- station wind layer --------------------------------------------------

    async def metar_bulk(self) -> Optional[List[StationObs]]:
        """Every station's latest METAR, from AWC's cache file, held for
        BULK_TTL. None when the pull fails (callers fall back to bbox)."""
        cached = await self.cache.get("metar_bulk")
        if cached is not None:
            return cached
        try:
            table = await awc.fetch_metar_cache(self._client)
        except Exception as exc:
            log.warning("metar bulk cache fetch failed: %s", exc)
            return None
        if not table:
            return None
        await self.cache.set("metar_bulk", table, ttl=BULK_TTL)
        self._record_snapshot(table, _now())
        return table

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

    @staticmethod
    def _load_history() -> List[tuple]:
        hist = persist.load("bulk_history") or []
        cutoff = _now() - timedelta(hours=HISTORY_KEEP_H)
        hist = [h for h in hist if isinstance(h, tuple) and len(h) == 2 and h[0] >= cutoff]
        if hist:
            log.info("bulk history restored: %d snapshots, oldest %s", len(hist), hist[0][0])
        return hist

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
        cached = await self.cache.get("station_info")
        if cached is not None:
            return cached
        try:
            info = await awc.fetch_station_info(self._client)
        except Exception as exc:
            log.warning("station directory fetch failed: %s", exc)
            return {}
        if info:
            await self.cache.set("station_info", info, ttl=STATION_INFO_TTL)
        return info

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

    async def get_station_obs(self, lat: float, lon: float, half: float = 3.0) -> StationsResponse:
        """Stations within ±half degrees of a point, sliced from the in-memory
        bulk table (no upstream call per user). Dense areas are thinned on a
        grid to STATIONS_MAX, keeping the fullest report per cell."""
        half = max(0.5, min(5.0, half))
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
        await self.cache.set(cache_key, resp, ttl=BULK_TTL)
        return resp

    async def _station_obs_bbox(self, lat: float, lon: float) -> StationsResponse:
        """Fallback when the bulk cache is unavailable: one bbox METAR call
        (±1.4°), cached by 0.2° cell."""
        cache_key = f"stations:{round(lat * 5) / 5}:{round(lon * 5) / 5}"
        cached = await self.cache.get(cache_key)
        if cached is not None:
            return cached
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

    # ---- Radar frames (RainViewer) -------------------------------------------

    async def get_radar_frames(self) -> RadarFramesResponse:
        """The radar timeline: last 7 observed frames + up to 3 nowcast, from
        one RainViewer call every two minutes for every user (the app used to
        fetch the full list itself on every radar open)."""
        cached = await self.cache.get("radar_frames")
        if cached is not None:
            return cached
        resp = await rv.fetch_frames(self._client, now=_now())
        await self.cache.set("radar_frames", resp, ttl=FRAMES_TTL)
        return resp

    # ---- Radar model field (wind + boundary layer) ------------------------

    FIELD_COLS, FIELD_ROWS, FIELD_INSET = 7, 5, 0.12

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
        cache_key = f"field:{q_lat}:{q_lon}:{q_lat_span}:{q_lon_span}"
        cached = await self.cache.get(cache_key)
        if cached is not None:
            return cached

        cols, rows, inset = self.FIELD_COLS, self.FIELD_ROWS, self.FIELD_INSET
        h = q_lat_span * (1 - 2 * inset)
        w = q_lon_span * (1 - 2 * inset)
        lat0, lon0 = q_lat - h / 2, q_lon - w / 2
        lats = [lat0 + h * r / (rows - 1) for r in range(rows) for _ in range(cols)]
        lons = [lon0 + w * c / (cols - 1) for _ in range(rows) for c in range(cols)]
        now = _now()
        points = await om.fetch_field_grid(lats, lons, self._client, now=now)
        resp = FieldGridResponse(points=points, cachedAt=now)
        await self.cache.set(cache_key, resp, ttl=FIELD_TTL)
        return resp

    # ---- WPC surface fronts --------------------------------------------------

    async def get_fronts(self) -> FrontsResponse:
        """The WPC surface chart as data: analysis + 12/24/36/48 h forecast
        front positions (sources/wpc.py). Global, so one cache entry."""
        cache_key = "fronts"
        cached = await self.cache.get(cache_key)
        if cached is not None:
            return cached
        got = await wpc.fetch_fronts(self._client)
        frames = got["analysis"] + sorted(got["progs"], key=lambda f: f.hours)
        if not frames:
            raise LookupError("no WPC front bulletins available")
        resp = FrontsResponse(frames=frames, cachedAt=_now())
        await self.cache.set(cache_key, resp, ttl=FRONTS_TTL)
        return resp

    # ---- combined (primary client endpoint) ---------------------------------

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

        interp, local_offset = _run_interpreter(pressure, forecast)
        # The client's real UTC offset beats the longitude/15 guess (which is
        # an hour off wherever daylight saving is in effect).
        if tz_minutes is not None:
            local_offset = tz_minutes / 60.0
        reading_out = _to_reading_out(interp) if interp is not None else None
        # What else agrees (observed signals + the model's view). Enrichment:
        # never blocks the response.
        if reading_out is not None:
            try:
                reading_out.explanation = explain.build(
                    interp, forecast.hourly if forecast else None, pressure.series,
                    _now(), local_hour_offset=local_offset)
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

        # Field conditions (DA + fog) are enrichment — never block the response.
        try:
            conditions = conditions_mod.build(pressure, forecast, _now())
        except Exception:
            conditions = None

        sources = Sources(
            observed=pressure.source,
            forecast=forecast.source if forecast else None,
        )
        return CombinedResponse(
            pressure=pressure,
            forecast=forecast,
            reading=reading_out,
            conditions=conditions,
            runways=runways.for_station(station),
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
