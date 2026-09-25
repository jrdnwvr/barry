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
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple

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
    offset: float = 0.0    # added after the scale: Kelvin to Celsius is -273.15


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

# The Aloft column: 17 levels, closer together near the ground where the
# screen gives the most room, with what the column draws at each (height,
# temperature, humidity, wind, cloud water and ice), and the surface.
COL_LEVELS = (1000, 975, 950, 925, 900, 875, 850, 825, 800, 750, 700, 650, 600, 550, 500, 450, 400)
# Temperatures are stored in Celsius: in half precision a value near 280
# steps by a quarter degree, near 5 by a two-hundred-fiftieth.
COL_FIELDS: Tuple[Field, ...] = tuple(
    Field(f"{short}{p}", g, f"{p} mb", "prs", offset=-273.15 if g == "TMP" else 0.0)
    for p in COL_LEVELS
    for short, g in (("hgt", "HGT"), ("t", "TMP"), ("rh", "RH"), ("u", "UGRD"), ("v", "VGRD"),
                     ("qc", "CLMR"), ("qi", "CIMIXR"))
) + (
    Field("t2", "TMP", "2 m above ground", "sfc", offset=-273.15),
    Field("td2", "DPT", "2 m above ground", "sfc", offset=-273.15),
    Field("u10", "UGRD", "10 m above ground", "sfc"),
    Field("v10", "VGRD", "10 m above ground", "sfc"),
    Field("frz", "HGT", "0C isotherm", "sfc"),
    Field("hpbl", "HPBL", "surface", "sfc"),
    Field("zsfc", "HGT", "surface", "sfc"),
)
COL_WIND_PAIRS: Tuple[Tuple[str, str], ...] = (("u10", "v10"),) + tuple((f"u{p}", f"v{p}") for p in COL_LEVELS)


@dataclass(frozen=True)
class FeedSpec:
    """One thing Barry keeps from HRRR: which fields, which forecast hours
    of which cycles, and how they are stored. `hours` returns the hours to
    pull for a cycle, or nothing when the feed skips that cycle."""
    name: str
    fields: Tuple[Field, ...]
    wind_pairs: Tuple[Tuple[str, str], ...]
    hours: Callable[[datetime], Tuple[int, ...]]
    stride: int = 1                 # 2 keeps every other point: 6 km
    dtype: str = "float32"
    nomads: bool = False            # whole files from NOMADS when the bucket is late
    keep: int = 2


# The last hour the day-long column feed takes from a 48-hour cycle: six
# hours until the next such cycle lands, plus the 24 the column shows.
EXTENDED_LAST = 30


def _extended(cycle: datetime) -> Tuple[int, ...]:
    return tuple(range(0, EXTENDED_LAST + 1)) if cycle.hour % 6 == 0 else ()


# The radar's map layers: full resolution, three hours of every cycle.
MAP = FeedSpec("hrrr", FIELDS, WIND_PAIRS, lambda c: FHRS, nomads=True)
# The Aloft column. The first hours from every cycle, and the day ahead
# from the four cycles a day that run to 48 hours. A point's column needs
# no 3 km detail, so these keep every other point in half precision:
# 0.95 MB a field instead of 7.6.
# One run of each is kept: the store deletes the old one only once the new
# one is complete, and a day-long run is 3.5 GB.
COL = FeedSpec("hrrr-col", COL_FIELDS, COL_WIND_PAIRS, lambda c: (0, 1, 2, 3), stride=2, dtype="float16", keep=1)
COLX = FeedSpec("hrrr-colx", COL_FIELDS, COL_WIND_PAIRS, lambda c: _extended(c), stride=2, dtype="float16", keep=1)
# The point forecast: everything the forecast cards, the storm outlook,
# density altitude and the ride estimate read, for 18 hours from every
# cycle and 48 from the four long ones. NBM overrides temperature, wind,
# sky and adds real probabilities for the first 36 hours.
FC_FIELDS: Tuple[Field, ...] = (
    Field("mslp", "MSLMA", "mean sea level", "sfc", 0.01),
    Field("psfc", "PRES", "surface", "sfc", 0.01),
    Field("u10", "UGRD", "10 m above ground", "sfc"),
    Field("v10", "VGRD", "10 m above ground", "sfc"),
    Field("gust", "GUST", "surface", "sfc"),
    Field("t2", "TMP", "2 m above ground", "sfc", offset=-273.15),
    Field("td2", "DPT", "2 m above ground", "sfc", offset=-273.15),
    Field("tcc", "TCDC", "entire atmosphere", "sfc"),
    Field("cape", "CAPE", "surface", "sfc"),
    Field("cin", "CIN", "surface", "sfc"),
    Field("hpbl", "HPBL", "surface", "sfc"),
    Field("dswrf", "DSWRF", "surface", "sfc"),
    Field("u80", "UGRD", "80 m above ground", "sfc"),
    Field("v80", "VGRD", "80 m above ground", "sfc"),
    Field("prate", "PRATE", "surface", "sfc", 3600.0),          # kg/m2/s to mm/h
)
FC_WIND_PAIRS: Tuple[Tuple[str, str], ...] = (("u10", "v10"), ("u80", "v80"))
EXTENDED_FC_LAST = 48


def _extended_fc(cycle: datetime) -> Tuple[int, ...]:
    return tuple(range(0, EXTENDED_FC_LAST + 1)) if cycle.hour % 6 == 0 else ()


FC_LAST = 18
FC = FeedSpec("hrrr-fc", FC_FIELDS, FC_WIND_PAIRS, lambda c: tuple(range(0, FC_LAST + 1)),
              stride=2, dtype="float16", keep=1)
FCX = FeedSpec("hrrr-fcx", FC_FIELDS, FC_WIND_PAIRS, lambda c: _extended_fc(c),
               stride=2, dtype="float16", keep=1)
FEEDS: Tuple[FeedSpec, ...] = (MAP, COL, COLX, FC, FCX)

def path(cycle: datetime, fhr: int, kind: str) -> str:
    return f"hrrr.{cycle:%Y%m%d}/conus/hrrr.t{cycle:%H}z.wrf{kind}f{fhr:02d}.grib2"


def aws_url(cycle: datetime, fhr: int, kind: str) -> str:
    return f"{AWS}/{path(cycle, fhr, kind)}"


def nomads_url(cycle: datetime, fhr: int, kind: str) -> str:
    return nomads.url(f"hrrr/prod/{path(cycle, fhr, kind)}")


def arrival_min(fhr: int) -> float:
    """Minutes after the cycle time when forecast hour `fhr` is normally on
    the bucket: about 50 for the analysis, two more an hour to 18, then one
    (measured 2026-09-24: f00 +50, f18 +85, f36 +93, f48 +107)."""
    return 50 + 2 * min(fhr, 18) + max(0, fhr - 18)


READY_MARGIN_MIN = 4
EXPECTED_AFTER_MIN = arrival_min(max(FHRS)) + READY_MARGIN_MIN      # 58 for the map
LATE_MIN = 10


def ready_after_min(spec: FeedSpec, cycle: datetime) -> Optional[float]:
    hrs = spec.hours(cycle)
    return arrival_min(max(hrs)) + READY_MARGIN_MIN if hrs else None


def expected_cycle(now: datetime, spec: FeedSpec = MAP) -> Optional[datetime]:
    """The newest cycle of this feed whose hours should all be on the
    bucket by now."""
    top = now.replace(minute=0, second=0, microsecond=0)
    for back in range(0, 12):
        cycle = top - timedelta(hours=back)
        after = ready_after_min(spec, cycle)
        if after is not None and now >= cycle + timedelta(minutes=after):
            return cycle
    return None


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
                 spec: FeedSpec = MAP) -> Optional[Tuple[datetime, str]]:
    """The cycle to pull and where from ("aws" or "nomads"), or None when
    the newest one available is already held. Looks back through the three
    newest cycles the feed takes."""
    held = set(held)
    newest = expected_cycle(now, spec)
    if newest is None:
        return None
    cycle, tried = newest, 0
    while tried < 3:
        hrs = spec.hours(cycle)
        if hrs:
            if cycle in held:
                return None
            if await aws_has(client, cycle, spec.fields, hrs):
                return cycle, "aws"
            after = ready_after_min(spec, cycle) or 0
            late = (now - cycle).total_seconds() / 60 > after + LATE_MIN
            if tried == 0 and spec.nomads and late and await nomads_has(client, cycle, spec.fields, hrs):
                return cycle, "nomads"
            tried += 1
        cycle -= timedelta(hours=1)
    return None


async def _get(client: httpx.AsyncClient, url: str, rng: Optional[Tuple[int, Optional[int]]] = None) -> bytes:
    headers = {"User-Agent": USER_AGENT}
    if rng is not None:
        headers["Range"] = f"bytes={rng[0]}-{'' if rng[1] is None else rng[1]}"
    r = await client.get(url, headers=headers, timeout=120.0)
    r.raise_for_status()
    return r.content


async def fetch_raw(client: httpx.AsyncClient, cycle: datetime, fhr: int,
                    fields: Sequence[Field], source: str = "aws") -> Dict[str, bytes]:
    """Each field's GRIB message bytes for one forecast hour, by Barry's name."""
    out: Dict[str, bytes] = {}
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
            out[f.name] = piece(*ranges[(f.grib, f.level)])
        del chunks
    return out


async def fetch_hour(client: httpx.AsyncClient, cycle: datetime, fhr: int,
                     fields: Sequence[Field] = FIELDS, source: str = "aws"
                     ) -> Dict[str, grib.Message]:
    """Every field for one forecast hour, decoded, keyed by Barry's name."""
    raw = await fetch_raw(client, cycle, fhr, fields, source)
    out: Dict[str, grib.Message] = {}
    for f in fields:
        msg = await asyncio.to_thread(grib.decode, raw.pop(f.name))
        if f.scale != 1.0:
            msg.values *= np.float32(f.scale)
        out[f.name] = msg
    return out


_ROTATION: Dict[Tuple, Tuple[np.ndarray, np.ndarray]] = {}


def rotate_pair(u: grib.Message, v: grib.Message) -> None:
    """Grid-relative u and v, in place, to earth-relative."""
    if not grib.grid_relative(u.meta):
        return
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


def rotate_winds(msgs: Dict[str, grib.Message], pairs: Sequence[Tuple[str, str]] = WIND_PAIRS) -> None:
    for un, vn in pairs:
        u, v = msgs.get(un), msgs.get(vn)
        if u is not None and v is not None:
            rotate_pair(u, v)


def grid_meta(msg: grib.Message, stride: int = 1) -> dict:
    keys = ("Nx", "Ny", "latitudeOfFirstGridPointInDegrees", "longitudeOfFirstGridPointInDegrees",
            "LoVInDegrees", "Latin1InDegrees", "Latin2InDegrees", "DxInMetres", "DyInMetres")
    m = {k: msg.meta.get(k) for k in keys}
    if stride > 1:
        m["Nx"] = (int(m["Nx"]) + stride - 1) // stride
        m["Ny"] = (int(m["Ny"]) + stride - 1) // stride
        m["DxInMetres"] = float(m["DxInMetres"]) * stride
        m["DyInMetres"] = float(m["DyInMetres"]) * stride
    return m


def _shrink(values: np.ndarray, spec: FeedSpec) -> np.ndarray:
    v = values[::spec.stride, ::spec.stride] if spec.stride > 1 else values
    return np.ascontiguousarray(v, dtype=np.dtype(spec.dtype))


def _process_hour(raw: Dict[str, bytes], spec: FeedSpec, cycle: datetime, fhr: int, store) -> int:
    """Decode, turn the winds, shrink and store one forecast hour. Runs in a
    worker thread; eccodes and numpy do the work outside the interpreter."""
    pair_of: Dict[str, str] = {}
    for un, vn in spec.wind_pairs:
        pair_of[un], pair_of[vn] = vn, un
    pending: Dict[str, grib.Message] = {}
    meta = None
    written = 0
    for f in spec.fields:
        msg = grib.decode(raw.pop(f.name))
        if f.scale != 1.0:
            msg.values *= np.float32(f.scale)
        if f.offset:
            msg.values += np.float32(f.offset)
        if meta is None:
            meta = grid_meta(msg, spec.stride)
        ready = [(f.name, msg)]
        other = pair_of.get(f.name)
        if other is not None:
            if other not in pending:
                pending[f.name] = msg
                continue
            o = pending.pop(other)
            u, v = (msg, o) if (f.name, other) in spec.wind_pairs else (o, msg)
            rotate_pair(u, v)
            ready = [(f.name, msg), (other, o)]
        for name, m in ready:
            store.put(spec.name, cycle, fhr, name, _shrink(m.values, spec), meta)
            written += 1
    return written


async def pull(client: httpx.AsyncClient, store, spec: FeedSpec, cycle: datetime,
               source: str = "aws") -> int:
    """Every hour the feed takes from this cycle, into the store, an hour
    at a time so a cycle never sits in memory whole. Returns fields
    written; marks the cycle complete and purges old ones."""
    written = 0
    for fhr in spec.hours(cycle):
        raw = await fetch_raw(client, cycle, fhr, spec.fields, source)
        written += await asyncio.to_thread(_process_hour, raw, spec, cycle, fhr, store)
    store.mark_complete(spec.name, cycle)
    store.purge(spec.name, keep=spec.keep)
    return written
