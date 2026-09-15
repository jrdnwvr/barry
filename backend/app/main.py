"""FastAPI app: the cached proxy + data contract for the Barry clients.

Routes (brief §5):
  GET /pressure/{station}?hours=24
  GET /forecast?lat=..&lon=..
  GET /combined?station=..&lat=..&lon=..   <- primary client endpoint
  GET /stations/nearest?lat=..&lon=..      <- convenience for location resolution
  GET /healthz
"""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from typing import Optional

import httpx
from pathlib import Path

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse

from . import stations
from .scheduler import Scheduler
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
        await client.aclose()


app = FastAPI(title="Barry backend", version="1.0", lifespan=lifespan)


def get_service() -> PressureService:
    return app.state.service


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
async def healthz():
    sched: Scheduler = app.state.scheduler
    return {
        "status": "ok",
        "scheduler_cycles": sched.cycles,
        "last_request_count": sched.last_request_count,
    }


@app.get("/pressure/{station}")
async def get_pressure(station: str, hours: int = Query(24, ge=1, le=24 * 15)):
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
    station: str = Query(...),
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
    station: str = Query(...),
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
    half: float = Query(3.0, ge=0.5, le=5.0),
):
    """Latest report at every station within ±half degrees of a point, from
    the server's bulk METAR table (no upstream call per request): the radar's
    wind-barb / speed-label layers and the station detail sheet."""
    service = get_service()
    resp = await service.get_station_obs(lat, lon, half=half)
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/radar/frames")
async def radar_frames():
    """RainViewer's frame list, trimmed to what the timeline shows and shared
    across users (one upstream call per two minutes)."""
    try:
        resp = await get_service().get_radar_frames()
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"radar frames unavailable: {exc}")
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/radar/field")
async def radar_field(
    lat: float = Query(..., ge=-90, le=90),
    lon: float = Query(..., ge=-180, le=180),
    latSpan: float = Query(..., gt=0, le=30),
    lonSpan: float = Query(..., gt=0, le=60),
):
    """Model wind + boundary-layer top on the radar's sample grid for a map
    region. One upstream call per region cell per ten minutes, shared by
    every user looking there."""
    try:
        resp = await get_service().get_field_grid(lat, lon, latSpan, lonSpan)
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"field grid unavailable: {exc}")
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


@app.get("/stations/nearest")
async def nearest_station(
    lat: float = Query(..., ge=-90, le=90),
    lon: float = Query(..., ge=-180, le=180),
):
    try:
        return await get_service().nearest_reporting_station(lat, lon)
    except LookupError:
        raise HTTPException(status_code=404, detail="no stations known")
