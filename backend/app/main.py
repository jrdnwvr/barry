"""FastAPI app: the cached proxy + data contract for the Barry clients.

Routes (brief §5):
  GET /pressure/{station}?hours=24
  GET /forecast?lat=..&lon=..
  GET /combined?station=..&lat=..&lon=..   <- primary client endpoint
  GET /stations/nearest?lat=..&lon=..      <- convenience for location resolution
  GET /healthz
"""

from __future__ import annotations

import asyncio
import json
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Optional

import httpx
import os
from pathlib import Path

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi import Path as PathParam   # pathlib.Path is the file one below
from fastapi.responses import FileResponse, JSONResponse, Response

from . import diagnostics, stations
from .guards import RateGate
from .scheduler import Scheduler
from .cache import CachedFailure
from .guards import InvalidStation, IPLimiter, RateLimited, client_key
from .service import PressureService

logging.basicConfig(level=logging.INFO)

# A descriptive User-Agent is required by AWC (brief §2.1). Set on every request
# at the source layer; this is the connection-pooled client shared app-wide.
HTTP_TIMEOUT = 15.0


@asynccontextmanager
async def lifespan(app: FastAPI):
    client = httpx.AsyncClient(timeout=HTTP_TIMEOUT)
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
async def _per_ip_budget(request: Request, call_next):
    if request.url.path == "/healthz":
        return await call_next(request)
    limiter: IPLimiter = request.app.state.ip_limiter
    key = client_key(request.client.host if request.client else None,
                     request.headers.get("cf-connecting-ip"))
    if not limiter.allow(key):
        return JSONResponse(status_code=429, content={"detail": "too many requests"},
                            headers={"Retry-After": "30"})
    return await call_next(request)


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
):
    """Latest report at every station within ±half degrees of a point, from
    the server's bulk METAR table (no upstream call per request): the radar's
    wind-barb / speed-label layers and the station detail sheet."""
    service = get_service()
    resp = await service.get_station_obs(lat, lon, half=half)
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/radar/pressure")
async def radar_pressure(
    lat: float = Query(..., ge=-90, le=90),
    lon: float = Query(..., ge=-180, le=180),
    latSpan: float = Query(..., gt=0, le=180),   # le: inf is not a span
    lonSpan: float = Query(..., gt=0, le=360),
):
    """Isobars (every 4 hPa) and isallobars (±1/2/3 hPa per 3 h) for a map
    region, contoured from Barry's own station table. No upstream call."""
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
async def search_stations(q: str = Query(..., min_length=1, max_length=40),
                          limit: int = Query(15, ge=1, le=50)):
    """Station search by ICAO id prefix or name, METAR-issuing sites only."""
    return {"results": await get_service().search_stations(q, limit=limit)}


@app.get("/stations/nearest")
async def nearest_station(
    lat: float = Query(..., ge=-90, le=90),
    lon: float = Query(..., ge=-180, le=180),
):
    try:
        return await get_service().nearest_reporting_station(lat, lon)
    except LookupError:
        raise HTTPException(status_code=404, detail="no stations known")
