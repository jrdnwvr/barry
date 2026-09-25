"""The National Blend of Models from NOAA's AWS Open Data bucket.

NBM is NOAA's bias-corrected blend of about thirty models, the starting
point for Weather Service forecasts, with real probabilities. Barry takes,
for the first 36 hours (hourly), what a point forecast needs and HRRR
does not do as well: 2 m temperature and dew point, 10 m wind, direction
and gust, sky cover, and the chance of rain and of thunder in each hour.
No sea-level pressure: that stays with HRRR.

Runs are hourly; Barry pulls every third one (00, 03, ... UTC), about 14
MB an hour of forecast by byte range, every other point kept in half
precision, one run held. The grid is Lambert conformal at 2.5 km (LoV
265, standard parallels 25); directions are true, not grid-relative.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Callable, Dict, List, Optional, Tuple

import httpx
import numpy as np

from .. import grib

AWS = "https://noaa-nbm-grib2-pds.s3.amazonaws.com"
FEED = "nbm"
USER_AGENT = "Barry/1.0 (jrdn@wvr.me)"
FHRS: Tuple[int, ...] = tuple(range(1, 37))
READY_AFTER_MIN = 75          # the whole run lands in about five minutes, 45 to 70 after its hour
EVERY_H = 3


@dataclass(frozen=True)
class Field:
    name: str
    match: Callable[[grib.IdxEntry, int], bool]
    offset: float = 0.0


def _plain(name: str, level: str):
    return lambda e, f: e.name == name and e.level == level and not e.extra


def _hourly(name: str, extra: str):
    return lambda e, f: (e.name == name and e.level == "surface" and e.fcst == f"{f - 1}-{f} hour acc fcst"
                         and e.extra.startswith(extra))


FIELDS: Tuple[Field, ...] = (
    Field("t2", _plain("TMP", "2 m above ground"), -273.15),
    Field("td2", _plain("DPT", "2 m above ground"), -273.15),
    Field("wspd", _plain("WIND", "10 m above ground")),        # m/s
    Field("wdir", _plain("WDIR", "10 m above ground")),        # degrees true, from
    Field("gust", _plain("GUST", "10 m above ground")),        # m/s
    Field("sky", _plain("TCDC", "surface")),                   # percent
    Field("pop1", _hourly("APCP", "prob >0.254")),             # percent, in the hour
    Field("tstm1", _hourly("TSTM", "probability forecast")),   # percent, in the hour
)


def path(cycle: datetime, fhr: int) -> str:
    return f"blend.{cycle:%Y%m%d}/{cycle:%H}/core/blend.t{cycle:%H}z.core.f{fhr:03d}.co.grib2"


def url(cycle: datetime, fhr: int) -> str:
    return f"{AWS}/{path(cycle, fhr)}"


async def _get(client: httpx.AsyncClient, target: str, rng=None) -> bytes:
    headers = {"User-Agent": USER_AGENT}
    if rng is not None:
        headers["Range"] = f"bytes={rng[0]}-{'' if rng[1] is None else rng[1]}"
    r = await client.get(target, headers=headers, timeout=120.0)
    r.raise_for_status()
    return r.content


async def _has(client: httpx.AsyncClient, cycle: datetime) -> bool:
    try:
        r = await client.head(url(cycle, max(FHRS)) + ".idx", headers={"User-Agent": USER_AGENT}, timeout=15.0)
    except httpx.HTTPError:
        return False
    return r.status_code == 200


async def choose(client: httpx.AsyncClient, now: datetime, held) -> Optional[datetime]:
    """The newest three-hourly run that is on the bucket and not held."""
    held = set(held)
    t = (now - timedelta(minutes=READY_AFTER_MIN)).replace(minute=0, second=0, microsecond=0)
    tried = 0
    while tried < 3:
        if t.hour % EVERY_H == 0:
            if t in held:
                return None
            if await _has(client, t):
                return t
            tried += 1
        t -= timedelta(hours=1)
    return None


def _meta(msg: grib.Message) -> dict:
    keys = ("Nx", "Ny", "latitudeOfFirstGridPointInDegrees", "longitudeOfFirstGridPointInDegrees",
            "LoVInDegrees", "Latin1InDegrees", "Latin2InDegrees", "DxInMetres", "DyInMetres")
    m = {k: msg.meta.get(k) for k in keys}
    m["Nx"] = (int(m["Nx"]) + 1) // 2
    m["Ny"] = (int(m["Ny"]) + 1) // 2
    m["DxInMetres"] = float(m["DxInMetres"]) * 2
    m["DyInMetres"] = float(m["DyInMetres"]) * 2
    return m


def _process(pieces: Dict[str, bytes], cycle: datetime, fhr: int, store) -> int:
    n = 0
    for f in FIELDS:
        raw = pieces.get(f.name)
        if raw is None:
            continue
        msg = grib.decode(raw)
        if f.offset:
            msg.values += np.float32(f.offset)
        arr = np.ascontiguousarray(msg.values[::2, ::2], dtype=np.float16)
        store.put(FEED, cycle, fhr, f.name, arr, _meta(msg))
        n += 1
    return n


async def pull(client: httpx.AsyncClient, store, cycle: datetime) -> int:
    """Every hour of the run, every field it has (thunder is not in every
    hour), into the store. Marks the run complete and keeps one."""
    written = 0
    for fhr in FHRS:
        target = url(cycle, fhr)
        entries = grib.parse_idx((await _get(client, target + ".idx")).decode("utf-8", "replace"))
        ranges: Dict[str, Tuple[int, Optional[int]]] = {}
        for f in FIELDS:
            r = grib.range_of(entries, lambda e, f=f: f.match(e, fhr))
            if r is not None:
                ranges[f.name] = r
        if not ranges:
            raise LookupError(f"nbm {cycle:%Y%m%d%H} f{fhr:03d}: nothing in the index")
        chunks: List[Tuple[int, bytes]] = []
        for s, e in grib.merge_ranges(ranges.values(), gap=1 << 20):
            chunks.append((s, await _get(client, target, (s, e))))
        pieces: Dict[str, bytes] = {}
        for name, (s, e) in ranges.items():
            for cs, data in chunks:
                if cs <= s and (e is None or e < cs + len(data)):
                    pieces[name] = data[s - cs: None if e is None else e - cs + 1]
                    break
        written += await asyncio.to_thread(_process, pieces, cycle, fhr, store)
    store.mark_complete(FEED, cycle)
    store.purge(FEED, keep=1)
    return written
