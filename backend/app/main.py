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
from fastapi import FastAPI, HTTPException, Query

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
):
    service = get_service()
    resp = await service.get_combined(station, lat, lon)
    return resp.model_dump(mode="json", by_alias=True)


@app.get("/stations/nearest")
async def nearest_station(
    lat: float = Query(..., ge=-90, le=90),
    lon: float = Query(..., ge=-180, le=180),
):
    result = stations.nearest(lat, lon)
    if result is None:
        raise HTTPException(status_code=404, detail="no stations known")
    sid, info, dist = result
    return {
        "station": sid,
        "name": info["name"],
        "lat": info["lat"],
        "lon": info["lon"],
        "distance_km": round(dist, 1),
    }
