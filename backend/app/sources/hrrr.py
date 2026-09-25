"""HRRR from NOAA's AWS Open Data bucket, with NOMADS as the fallback.

Each hourly cycle lands in noaa-hrrr-bdp-pds about 50 minutes after its
time (f00) and 55 (f02). Barry pulls the fields in FIELDS for the hours in
FHRS by byte range from the `.idx` sidecars, decodes them, turns HRRR's
grid-relative winds to earth-relative, and hands them to the model store.
About 90 MB a cycle from the surface and pressure files together.

When the bucket is more than ten minutes behind the expected cycle and
NOMADS has it, the cycle comes from NOMADS instead, as whole files (one
request each, so its 10 second spacing costs nothing), sliced locally by
the same index.

Fields are a table (Barry's name, GRIB name, level, file, unit scale), so
RRFS, which uses the same grid with different names, is a second table.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

import httpx
import numpy as np

from .. import grib
from . import nomads

AWS = "https://noaa-hrrr-bdp-pds.s3.amazonaws.com"
FEED = "hrrr"
USER_AGENT = "Barry/1.0 (jrdn@wvr.me)"


@dataclass(frozen=True)
class Field:
    name: str
    grib: str
    level: str
    kind: str              # "sfc" (wrfsfc) or "prs" (wrfprs)
    scale: float = 1.0


LEVELS = (925, 850, 700, 600, 500)

FIELDS: Tuple[Field, ...] = (
    Field("u10", "UGRD", "10 m above ground", "sfc"),
    Field("v10", "VGRD", "10 m above ground", "sfc"),
    Field("gust", "GUST", "surface", "sfc"),
    Field("hpbl", "HPBL", "surface", "sfc"),
    Field("cape", "CAPE", "surface", "sfc"),
    Field("mslp", "MSLMA", "mean sea level", "sfc", 0.01),      # Pa to hPa
    # Surface pressure, to leave out levels that lie underground (850 hPa
    # over Denver): the model extrapolates there, and charts leave it out.
    Field("psfc", "PRES", "surface", "sfc", 0.01),
) + tuple(
    Field(f"{short}{p}", g, f"{p} mb", "prs")
    for p in LEVELS for short, g in (("hgt", "HGT"), ("u", "UGRD"), ("v", "VGRD"))
)

# u and v pairs to turn from grid-relative to earth-relative.
WIND_PAIRS: Tuple[Tuple[str, str], ...] = (("u10", "v10"),) + tuple((f"u{p}", f"v{p}") for p in LEVELS)

# The analysis and the next two hours: whatever time a phone asks, one of
# them is valid within half an hour of it.
FHRS: Tuple[int, ...] = (0, 1, 2)

# Minutes after the cycle time when the last hour Barry needs is normally
# on the bucket, and how late it may be before NOMADS is asked.
EXPECTED_AFTER_MIN = 58
LATE_MIN = 10


def path(cycle: datetime, fhr: int, kind: str) -> str:
    return f"hrrr.{cycle:%Y%m%d}/conus/hrrr.t{cycle:%H}z.wrf{kind}f{fhr:02d}.grib2"


def aws_url(cycle: datetime, fhr: int, kind: str) -> str:
    return f"{AWS}/{path(cycle, fhr, kind)}"


def nomads_url(cycle: datetime, fhr: int, kind: str) -> str:
    return nomads.url(f"hrrr/prod/{path(cycle, fhr, kind)}")


def expected_cycle(now: datetime) -> datetime:
    """The newest cycle whose hours should all be on the bucket by now."""
    t = now - timedelta(minutes=EXPECTED_AFTER_MIN)
    return t.replace(minute=0, second=0, microsecond=0)


def kinds(fields: Iterable[Field]) -> List[str]:
    return sorted({f.kind for f in fields})


async def _exists(client: httpx.AsyncClient, url: str) -> bool:
    try:
        r = await client.head(url, headers={"User-Agent": USER_AGENT}, timeout=15.0)
    except httpx.HTTPError:
        return False
    return r.status_code == 200


async def aws_has(client: httpx.AsyncClient, cycle: datetime, fields: Sequence[Field] = FIELDS,
                  fhrs: Sequence[int] = FHRS) -> bool:
    """Every file the cycle needs has its index on the bucket (the index
    is written after the file)."""
    last = max(fhrs)
    for k in kinds(fields):
        if not await _exists(client, aws_url(cycle, last, k) + ".idx"):
            return False
    return True


async def nomads_has(client: httpx.AsyncClient, cycle: datetime, fields: Sequence[Field] = FIELDS,
                     fhrs: Sequence[int] = FHRS) -> bool:
    last = max(fhrs)
    for k in kinds(fields):
        try:
            await nomads.get(client, nomads_url(cycle, last, k) + ".idx", timeout=20.0)
        except httpx.HTTPError:
            return False
    return True


async def choose(client: httpx.AsyncClient, now: datetime, held: Iterable[datetime],
                 fields: Sequence[Field] = FIELDS, fhrs: Sequence[int] = FHRS
                 ) -> Optional[Tuple[datetime, str]]:
    """The cycle to pull and where from ("aws" or "nomads"), or None when
    the newest one available is already held."""
    held = set(held)
    exp = expected_cycle(now)
    for back in range(0, 4):
        cycle = exp - timedelta(hours=back)
        if cycle in held:
            return None
        if await aws_has(client, cycle, fields, fhrs):
            return cycle, "aws"
        late = (now - cycle).total_seconds() / 60 > EXPECTED_AFTER_MIN + LATE_MIN
        if back == 0 and late and await nomads_has(client, cycle, fields, fhrs):
            return cycle, "nomads"
    return None


async def _get(client: httpx.AsyncClient, url: str, rng: Optional[Tuple[int, Optional[int]]] = None) -> bytes:
    headers = {"User-Agent": USER_AGENT}
    if rng is not None:
        headers["Range"] = f"bytes={rng[0]}-{'' if rng[1] is None else rng[1]}"
    r = await client.get(url, headers=headers, timeout=120.0)
    r.raise_for_status()
    return r.content


async def fetch_hour(client: httpx.AsyncClient, cycle: datetime, fhr: int,
                     fields: Sequence[Field] = FIELDS, source: str = "aws"
                     ) -> Dict[str, grib.Message]:
    """Every field for one forecast hour, decoded, keyed by Barry's name."""
    out: Dict[str, grib.Message] = {}
    for k in kinds(fields):
        want = [f for f in fields if f.kind == k]
        if source == "nomads":
            url = nomads_url(cycle, fhr, k)
            idx = (await nomads.get(client, url + ".idx")).text
            whole = (await nomads.get(client, url, timeout=300.0)).content
        else:
            url = aws_url(cycle, fhr, k)
            idx = (await _get(client, url + ".idx")).decode("utf-8", "replace")
            whole = None
        entries = grib.parse_idx(idx)
        ranges = grib.byte_ranges(entries, [(f.grib, f.level) for f in want])
        missing = [f.name for f in want if (f.grib, f.level) not in ranges]
        if missing:
            raise LookupError(f"hrrr {cycle:%Y%m%d%H} f{fhr:02d} {k}: not in index: {missing}")
        chunks: List[Tuple[int, bytes]] = []
        if whole is not None:
            chunks.append((0, whole))
        else:
            # Neighbouring fields come down together; a gap of up to a
            # megabyte is cheaper to read through than to ask for twice.
            for s, e in grib.merge_ranges(ranges.values(), gap=1 << 20):
                chunks.append((s, await _get(client, url, (s, e))))

        def piece(start: int, end: Optional[int]) -> bytes:
            for cs, data in chunks:
                if cs <= start and (end is None or end < cs + len(data)):
                    return data[start - cs: None if end is None else end - cs + 1]
            raise LookupError("range not fetched")

        for f in want:
            s, e = ranges[(f.grib, f.level)]
            msg = await asyncio.to_thread(grib.decode, piece(s, e))
            if f.scale != 1.0:
                msg.values *= np.float32(f.scale)
            out[f.name] = msg
    return out


_ROTATION: Dict[Tuple, Tuple[np.ndarray, np.ndarray]] = {}


def rotate_winds(msgs: Dict[str, grib.Message]) -> None:
    """Grid-relative u and v, in place, to earth-relative."""
    for un, vn in WIND_PAIRS:
        u, v = msgs.get(un), msgs.get(vn)
        if u is None or v is None or not grib.grid_relative(u.meta):
            continue
        g = grib.LambertGrid.from_meta(u.meta)
        rot = _ROTATION.get(g.key())
        if rot is None:
            _, lon = g.lonlat_arrays()
            a = g.rotation(lon)
            rot = (np.cos(a).astype(np.float32), np.sin(a).astype(np.float32))
            _ROTATION[g.key()] = rot
        c, s = rot
        uu, vv = u.values, v.values
        u.values, v.values = uu * c + vv * s, -uu * s + vv * c


def grid_meta(msg: grib.Message) -> dict:
    keys = ("Nx", "Ny", "latitudeOfFirstGridPointInDegrees", "longitudeOfFirstGridPointInDegrees",
            "LoVInDegrees", "Latin1InDegrees", "Latin2InDegrees", "DxInMetres", "DyInMetres")
    return {k: msg.meta.get(k) for k in keys}
