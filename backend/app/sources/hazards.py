"""Turbulence and icing aloft from NOMADS: GTG and CIP.

GTG (Graphical Turbulence Guidance) nowcast: eddy dissipation rate, the
aircraft-independent measure of turbulence, every 1,000 ft from 100 to
50,000 ft MSL, every 15 minutes, about a minute after its valid time. In
production. AWC's categories for a medium aircraft: light from 0.15,
moderate from 0.22, severe from 0.34.

CIP (Current Icing Product) v2: icing probability, severity (1 trace, 2
light, 3 moderate, 4 heavy; checked against the probabilities on
2026-09-24) and supercooled large drop potential, every 500 ft from 500 to
30,000 ft MSL, hourly, about 11 minutes after the hour. Still "para" on
NOMADS, out for public evaluation, so it can change or stop.

Neither is on the AWS buckets. Both are on the HRRR grid and JPEG2000
packed; each is one whole file (29 and 40 MB), kept at every other point
in half precision, newest run only. Analysis only: they say what is
there now, not later.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Tuple

import httpx
import numpy as np

from .. import grib
from . import nomads

FT_PER_M = 3.28084


@dataclass(frozen=True)
class Product:
    feed: str
    path: str                       # strftime pattern under NOMADS' com/
    step_min: int                   # 15 for GTG, 60 for CIP
    lag_min: int                    # minutes after its valid time it is usually there
    params: Dict[Tuple[int, int, int], str]     # (discipline, category, number) -> prefix
    keep: int = 1


GTG = Product("gtg", "gtgn/prod/gtgn.%Y%m%d/%H/gtgn.t%H%Mz.3km.grib2", 15, 3,
              {(0, 19, 30): "edr"})
CIP = Product("cip", "cip/para/cip.%Y%m%d/cip.t%Hz.3km.grib2", 60, 14,
              {(0, 19, 233): "icp", (0, 19, 37): "ics", (0, 19, 217): "sld"})
PRODUCTS = (GTG, CIP)


def valid_for(p: Product, now: datetime) -> datetime:
    """The newest run that should be on NOMADS."""
    t = now - timedelta(minutes=p.lag_min)
    return t.replace(minute=(t.minute // p.step_min) * p.step_min, second=0, microsecond=0)


def ft_name(prefix: str, level_m: float) -> str:
    """Levels by the nearest 100 ft, so 30 m reads edr_100 and 152 m icp_500."""
    return f"{prefix}_{int(round(level_m * FT_PER_M / 100.0)) * 100}"


def process(p: Product, data: bytes, valid: datetime, store) -> int:
    """Decode every message the product's table names, keep every other
    point in half precision, store under the run's valid time."""
    meta = None
    written = 0
    for raw in grib.split_messages(data):
        msg = grib.decode(raw)
        key = (msg.meta.get("discipline"), msg.meta.get("parameterCategory"), msg.meta.get("parameterNumber"))
        prefix = p.params.get(key)
        if prefix is None or msg.meta.get("typeOfLevel") != "heightAboveSea":
            continue
        if meta is None:
            keys = ("Nx", "Ny", "latitudeOfFirstGridPointInDegrees", "longitudeOfFirstGridPointInDegrees",
                    "LoVInDegrees", "Latin1InDegrees", "Latin2InDegrees", "DxInMetres", "DyInMetres")
            meta = {k: msg.meta.get(k) for k in keys}
            meta["Nx"] = (int(meta["Nx"]) + 1) // 2
            meta["Ny"] = (int(meta["Ny"]) + 1) // 2
            meta["DxInMetres"] = float(meta["DxInMetres"]) * 2
            meta["DyInMetres"] = float(meta["DyInMetres"]) * 2
        arr = np.ascontiguousarray(msg.values[::2, ::2], dtype=np.float16)
        store.put(p.feed, valid, 0, ft_name(prefix, float(msg.meta["level"])), arr, meta)
        written += 1
    if written:
        store.mark_complete(p.feed, valid)
        store.purge(p.feed, keep=p.keep)
    return written


async def poll(client: httpx.AsyncClient, store, p: Product, now: datetime) -> int:
    """Pull the newest run if it isn't held. 0 when held or not there yet."""
    valid = valid_for(p, now)
    if store.has(p.feed, valid):
        return 0
    try:
        r = await nomads.get(client, nomads.url(valid.strftime(p.path)), timeout=180.0)
    except httpx.HTTPStatusError as exc:
        if exc.response.status_code == 404:
            return 0
        raise
    return await asyncio.to_thread(process, p, r.content, valid, store)
