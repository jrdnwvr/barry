"""FastAPI app: the cached proxy + data contract for the Barry clients.

Routes: docs/FEATURES.md (the Backend table) lists every one with its
parameters, sources, caching and the client that reads it. The primary
client endpoint is GET /combined?station=..&lat=..&lon=..
"""

from __future__ import annotations

import asyncio
import json
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Optional

import httpx
from uuid import uuid4
import os
from pathlib import Path

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi import Path as PathParam   # pathlib.Path is the file one below
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse, Response

from . import diagnostics, logs, metrics, stations
from .guards import RateGate, is_private
from .scheduler import Scheduler
from .cache import CachedFailure
from .guards import InvalidStation, IPLimiter, RateLimited, check_station, client_key
from .service import PressureService

logs.configure()

# A descriptive User-Agent is required by AWC (brief §2.1). Set on every request
# at the source layer; this is the connection-pooled client shared app-wide.
HTTP_TIMEOUT = 15.0


def _upstream_hooks():
    """Count every upstream call by host, and every answer by status
    class; sent minus answered is what timed out or failed to connect."""
    async def on_request(request: httpx.Request):
        metrics.inc("barry_upstream_requests_total", request.url.host)

    async def on_response(response: httpx.Response):
        metrics.inc("barry_upstream_responses_total", response.request.url.host,
                    metrics.status_class(response.status_code))
    return {"request": [on_request], "response": [on_response]}


@asynccontextmanager
async def lifespan(app: FastAPI):
    client = httpx.AsyncClient(timeout=HTTP_TIMEOUT, event_hooks=_upstream_hooks())
    service = PressureService(client)
    scheduler = Scheduler(service, interval_seconds=600.0)
    app.state.client = client
    app.state.service = service
    app.state.scheduler = scheduler
    scheduler.start()
    try:
        yield
    finally:
        await scheduler.stop()
        try:
            await service.flush_track_log()
        except Exception:
            log.exception("track log write at shutdown failed")
        await client.aclose()


# The interactive docs and the schema are for development. In production they
# are a map of every parameter for anyone who finds the hostname.
_PUBLIC_DOCS = os.environ.get("BARRY_PUBLIC_DOCS") == "1"
app = FastAPI(title="Barry backend", version="1.0", lifespan=lifespan,
              docs_url="/docs" if _PUBLIC_DOCS else None,
              redoc_url="/redoc" if _PUBLIC_DOCS else None,
              openapi_url="/openapi.json" if _PUBLIC_DOCS else None)

STATION_PATTERN = r"^[A-Za-z0-9]{3,4}$"

# Per-address request budget. Cloudflare's own rule is the outer guard; this
# is the backstop for anything that reaches the container another way, and
# it is what actually keys on the real client address behind the tunnel.
# BARRY_RATE_PER_MIN=0 disables it (tests, local dev).
app.state.ip_limiter = IPLimiter(per_minute=float(os.environ.get("BARRY_RATE_PER_MIN", "60")))


@app.middleware("http")
async def _request_context(request: Request, call_next):
    """A request id on every log line and response, the per-address budget,
    and one count per answer by route template and status. The template,
    not the path: nothing a client typed reaches a label."""
    rid = uuid4().hex[:12]
    token = logs.request_id.set(rid)
    try:
        response = None
        if request.url.path != "/healthz":
            limiter: IPLimiter = request.app.state.ip_limiter
            key = client_key(request.client.host if request.client else None,
                             request.headers.get("cf-connecting-ip"))
            if not limiter.allow(key):
                response = JSONResponse(status_code=429, content={"detail": "too many requests"},
                                        headers={"Retry-After": "30"})
        if response is None:
            try:
                response = await call_next(request)
            except Exception:
                metrics.inc("barry_requests_total", _route_template(request), "500")
                raise
        response.headers["X-Request-Id"] = rid
        metrics.inc("barry_requests_total", _route_template(request), str(response.status_code))
        return response
    finally:
        logs.request_id.reset(token)


def _route_template(request: Request) -> str:
    route = request.scope.get("route")
    return getattr(route, "path", None) or "unmatched"


@app.get("/metrics", include_in_schema=False)
async def metrics_endpoint(request: Request):
    """Counters in the Prometheus text format, for the box's own network
    only: a request that came through the tunnel carries CF-Connecting-IP,
    and one from outside has a public peer; both get the same 404 as a
    path that does not exist."""
    peer = request.client.host if request.client else None
    if request.headers.get("cf-connecting-ip") or not (peer and is_private(peer)):
        raise HTTPException(status_code=404, detail="Not Found")
    sched: Optional[Scheduler] = getattr(app.state, "scheduler", None)
    service: Optional[PressureService] = getattr(app.state, "service", None)
    if service is not None:
        metrics.gauge("barry_cache_entries", len(service.cache._store))
        metrics.gauge("barry_glm_flashes", len(service.flashes))
    if sched is not None:
        metrics.gauge("barry_scheduler_cycles_total", sched.cycles)
    return PlainTextResponse(metrics.render(), media_type="text/plain; version=0.0.4; charset=utf-8")


@app.exception_handler(InvalidStation)
async def _invalid_station(_request, _exc):
    return JSONResponse(status_code=422, content={"detail": "station must be 3 or 4 letters or digits"})


@app.exception_handler(CachedFailure)
async def _cached_failure(request: Request, exc: CachedFailure):
    # A route that caught nothing met an upstream failure remembered from
    # a minute ago. Same answer as the first failure got, no detail.
    log.warning("%s: upstream failure still cached (%s)", request.url.path, exc)
    return JSONResponse({"detail": "upstream unavailable"}, status_code=503,
                        headers={"Retry-After": "60"})


@app.exception_handler(RateLimited)
async def _rate_limited(_request, _exc):
    # Constant body on purpose: which upstream and why is not the client's business.
    return JSONResponse(status_code=503, content={"detail": "upstream budget exhausted, try again shortly"},
                        headers={"Retry-After": "30"})


def get_service() -> PressureService:
    return app.state.service


log = logging.getLogger(__name__)
# httpx logs every upstream URL at INFO, query string included, which put
# client coordinates back into the container log after the access log went.
for _noisy in ("httpx", "httpcore"):
    logging.getLogger(_noisy).setLevel(logging.WARNING)

STATIC = Path(__file__).resolve().parent / "static"


@app.get("/privacy", include_in_schema=False)
async def privacy_page():
    """The App Store privacy policy URL."""
    return FileResponse(STATIC / "privacy.html", media_type="text/html")


@app.get("/support", include_in_schema=False)
async def support_page():
    """The App Store support URL."""
    return FileResponse(STATIC / "support.html", media_type="text/html")


@app.get("/healthz")
async def healthz(strict: bool = Query(False)):
    """Liveness for the container, readiness for an outside monitor.

    503 with status "unhealthy" when a scheduler loop has exited or stopped
    finishing: that is the process, and a restart fixes it. Status
    "degraded" when an upstream has been silent too long (bulk METAR table
    for two cycles, lightning for ten minutes): the process is fine and a
    restart would only throw away the caches that are carrying users through
    the outage, so that is 200 unless ?strict=1 asks for it as a failure.
    The compose health check reads the plain form; an uptime check should
    read the strict one."""
    sched: Optional[Scheduler] = getattr(app.state, "scheduler", None)
    service: Optional[PressureService] = getattr(app.state, "service", None)
    if sched is None or service is None:
        return JSONResponse({"status": "unhealthy", "problems": ["not started"]}, status_code=503)
    now = datetime.now(timezone.utc)
    dead, stale = sched.problems(now)
    status = "unhealthy" if dead else ("degraded" if stale else "ok")
    body = {
        "status": status,
        "problems": dead + stale,
        "scheduler_cycles": sched.cycles,
        "glm_cycles": sched.glm_cycles,
        "glm_flashes": len(service.flashes),
        "glm_last_fetch": service.flashes.last_fetch.isoformat() if service.flashes.last_fetch else None,
        "bulk_ok_at": service.bulk_ok_at.isoformat() if service.bulk_ok_at else None,
        "last_request_count": sched.last_request_count,
    }
    failing = bool(dead) or (strict and bool(stale))
    return JSONResponse(body, status_code=503 if failing else 200)


# Whatever the app count, the box writes at most this many diagnostics
# files a minute; a phone sends one or two a day.
_diag_gate = RateGate(per_minute=30)


@app.post("/diagnostics", status_code=202, include_in_schema=False)
async def post_diagnostics(request: Request):
    """MetricKit payloads from the app. See app/diagnostics.py. The body is
    read in chunks against a hard cap, checked to be JSON, and written as a
    file; nothing in it is parsed or indexed."""
    _diag_gate.require()
    body = bytearray()
    async for chunk in request.stream():
        body += chunk
        if len(body) > diagnostics.DIAG_MAX_BYTES:
            raise HTTPException(status_code=413, detail="too large")
    try:
        json.loads(bytes(body))
    except ValueError:
        raise HTTPException(status_code=400, detail="not json")
    kind = request.headers.get("X-Barry-Kind", "metric")
    await asyncio.to_thread(diagnostics.store, kind, bytes(body))
    return Response(status_code=202)


@app.get("/pressure/{station}")
async def get_pressure(station: str = PathParam(..., pattern=STATION_PATTERN),
                       hours: int = Query(24, ge=1, le=24)):
    service = get_service()
    resp = await service.get_pressure(station, hours=hours)
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/forecast")
async def get_forecast(
    lat: float = Query(..., ge=-90, le=90),
    lon: float = Query(..., ge=-180, le=180),
):
    service = get_service()
    resp = await service.get_forecast(lat, lon)
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/combined")
async def get_combined(
    station: str = Query(..., pattern=STATION_PATTERN),
    lat: Optional[float] = Query(None, ge=-90, le=90),
    lon: Optional[float] = Query(None, ge=-180, le=180),
    tz: Optional[int] = Query(None, ge=-14 * 60, le=14 * 60,
                              description="client UTC offset in minutes, for local times in copy"),
):
    service = get_service()
    resp = await service.get_combined(station, lat, lon, tz_minutes=tz)
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/front")
async def get_front(
    station: str = Query(..., pattern=STATION_PATTERN),
    lat: Optional[float] = Query(None, ge=-90, le=90),
    lon: Optional[float] = Query(None, ge=-180, le=180),
):
    """Front watch: regional pressure-tendency field + direction + model ETA.
    Clients call this after /combined; a "none" status means render nothing."""
    service = get_service()
    resp = await service.get_front(station, lat, lon)
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/radar/hrrr")
async def radar_hrrr():
    """Latest HRRR run IEM serves forecast-reflectivity tiles for. The client
    builds tile layer names (hrrr::REFD-F{min}-{runstamp}) and true valid
    times from this; 503 just means no model frames on the radar timeline."""
    service = get_service()
    try:
        resp = await service.get_hrrr_meta()
    except LookupError:
        raise HTTPException(status_code=503, detail="HRRR unavailable")
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/metars")
async def get_metars(
    lat: float = Query(..., ge=-90, le=90),
    lon: float = Query(..., ge=-180, le=180),
    half: float = Query(3.0, ge=0.5, le=30.0),
    buoys: bool = Query(False),
):
    """Latest report at every station within ±half degrees of a point, from
    the server's bulk METAR table (no upstream call per request): the radar's
    wind-barb / speed-label layers and the station detail sheet. With
    `buoys=1`, NOAA's buoys and coastal stations in the same box too (one
    NDBC fetch per ten minutes for everyone)."""
    service = get_service()
    if buoys:
        resp = await service.get_station_obs_with_buoys(lat, lon, half=half)
    else:
        resp = await service.get_station_obs(lat, lon, half=half)
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/advisories")
async def get_advisories(
    lat: float = Query(..., ge=-90, le=90),
    lon: float = Query(..., ge=-180, le=180),
    half: float = Query(6.0, ge=0.5, le=30.0),
):
    """SIGMETs, G-AIRMETs at the current hour, and pilot reports of
    turbulence and icing over the last two hours, around a point. Cut from
    national feeds the server pulls once every ten minutes."""
    resp = await get_service().get_advisories(lat, lon, half=half)
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/radar/pressure")
async def radar_pressure(
    lat: float = Query(..., ge=-90, le=90),
    lon: float = Query(..., ge=-180, le=180),
    latSpan: float = Query(..., gt=0, le=180),   # le: inf is not a span
    lonSpan: float = Query(..., gt=0, le=360),
):
    """Isobars (every 4 hPa) and isallobars (every whole hPa per 3 h, no cap)
    for a map region, contoured from Barry's own station table. No upstream
    call."""
    resp = await get_service().get_pressure_field(lat, lon, latSpan, lonSpan)
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/lightning")
async def get_lightning(
    lat: float = Query(..., ge=-90, le=90),
    lon: float = Query(..., ge=-180, le=180),
    half: float = Query(3.0, ge=0.5, le=6.0),
):
    """GOES GLM flashes over the last 20 minutes around a point, binned to
    0.02° cells, from the server's own memory (NOAA is polled once a
    minute regardless of users). coverage=false means the feed is stale."""
    return await get_service().get_lightning(lat, lon, half)


@app.get("/radar/frames")
async def radar_frames():
    """RainViewer's frame list, trimmed to what the timeline shows and shared
    across users (one upstream call per two minutes)."""
    try:
        resp = await get_service().get_radar_frames()
    except Exception as exc:
        log.warning("radar frames unavailable: %s: %s", type(exc).__name__, exc)
        raise HTTPException(status_code=503, detail="radar frames unavailable")
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/aloft")
async def get_aloft(
    lat: float = Query(..., ge=-90, le=90),
    lon: float = Query(..., ge=-180, le=180),
):
    """The vertical column at a point: clouds, temperatures and wind by
    model level, hourly for a day. One upstream call per tenth-degree cell
    per hour. 503 means the model is unavailable."""
    try:
        resp = await get_service().get_aloft(lat, lon)
    except LookupError:
        raise HTTPException(status_code=503, detail="aloft unavailable")
    except Exception as exc:
        log.warning("aloft unavailable: %s: %s", type(exc).__name__, exc)
        raise HTTPException(status_code=503, detail="aloft unavailable")
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/radar/field/levels")
async def radar_field_levels(
    lat: float = Query(..., ge=-90, le=90),
    lon: float = Query(..., ge=-180, le=180),
    latSpan: float = Query(..., gt=0, le=180),
    lonSpan: float = Query(..., gt=0, le=360),
):
    """Model wind at each altitude stop on the radar's sample grid. Asked
    for only when the altitude slider leaves the surface; one upstream call
    per region cell per half hour."""
    try:
        resp = await get_service().get_field_levels(lat, lon, latSpan, lonSpan)
    except Exception as exc:
        log.warning("winds aloft unavailable: %s: %s", type(exc).__name__, exc)
        raise HTTPException(status_code=503, detail="winds aloft unavailable")
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/radar/field")
async def radar_field(
    lat: float = Query(..., ge=-90, le=90),
    lon: float = Query(..., ge=-180, le=180),
    latSpan: float = Query(..., gt=0, le=180),   # le: inf is not a span
    lonSpan: float = Query(..., gt=0, le=360),
):
    """Model wind + boundary-layer top on the radar's sample grid for a map
    region. One upstream call per region cell per ten minutes, shared by
    every user looking there."""
    try:
        resp = await get_service().get_field_grid(lat, lon, latSpan, lonSpan)
    except Exception as exc:
        log.warning("field grid unavailable: %s: %s", type(exc).__name__, exc)
        raise HTTPException(status_code=503, detail="field grid unavailable")
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/fronts")
async def get_fronts():
    """WPC surface fronts: the current analysis plus 12/24/36/48 h forecast
    positions, as typed polylines. 503 means the bulletins are unavailable."""
    service = get_service()
    try:
        resp = await service.get_fronts()
    except LookupError:
        raise HTTPException(status_code=503, detail="fronts unavailable")
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/stations/search")
async def search_stations(q: str = Query(..., min_length=2, max_length=40),
                          limit: int = Query(15, ge=1, le=50)):
    """Station search by ICAO id prefix or name, METAR-issuing sites only."""
    return {"results": await get_service().search_stations(q, limit=limit)}


@app.get("/glance")
async def glance(
    stations: str = Query(..., min_length=3, max_length=60),
    tz: Optional[int] = Query(None, ge=-840, le=840),
):
    """The saved fields at a glance: one compact line each, from the same
    cached reports as /combined. Up to eight comma-separated ids."""
    ids = [s.strip() for s in stations.split(",") if s.strip()]
    for sid in ids:
        check_station(sid)
    resp = await get_service().get_glance([s.upper() for s in ids], tz_minutes=tz)
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/stations/nearest")
async def nearest_station(
    lat: float = Query(..., ge=-90, le=90),
    lon: float = Query(..., ge=-180, le=180),
):
    try:
        return await get_service().nearest_reporting_station(lat, lon)
    except LookupError:
        raise HTTPException(status_code=404, detail="no stations known")
