"""GOES Geostationary Lightning Mapper (GLM) — real flash positions.

NOAA publishes every GLM Level 2 file on public S3 buckets (Open Data
program): anonymous reads, no key, no terms, US government work in the
public domain. One file per satellite every 20 seconds, 200 to 500 KB,
covering the whole disk. Barry's server polls the two current satellites
(GOES-East = G19, GOES-West = G18) once a minute and keeps the last 15
minutes of flashes in memory; phones only ever ask Barry. The cost is
therefore fixed (about 2 to 3 GB a day into the server) no matter how many
users there are.

Files are netCDF-4, i.e. HDF5, read with h5py straight from memory. Only
the flash-level variables are used; groups and events are ignored.
"""

from __future__ import annotations

import io
import re
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional, Sequence, Tuple
from xml.etree import ElementTree as ET

import httpx

USER_AGENT = "Barry/1.0 (jrdn@wvr.me)"
PRODUCT = "GLM-L2-LCFA"

#: Satellite id (as in the filename) -> bucket. East first: it sees CONUS.
BUCKETS: Dict[str, str] = {"G19": "noaa-goes19", "G18": "noaa-goes18"}

#: Both satellites see the Mountain West. Each keeps only its side of this
#: meridian so a storm in Colorado is not counted twice.
SPLIT_LON = -106.0
OWNED_SIDE = {"G19": lambda lon: lon >= SPLIT_LON, "G18": lambda lon: lon < SPLIT_LON}

_S3_NS = "{http://s3.amazonaws.com/doc/2006-03-01/}"
_START_RE = re.compile(r"_s(\d{4})(\d{3})(\d{2})(\d{2})(\d{2})\d_")
_UNITS_RE = re.compile(r"seconds since (\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2}(?:\.\d+)?)")


@dataclass(frozen=True)
class Flash:
    t: float        # unix epoch seconds
    lat: float
    lon: float
    energy: float   # J (0 when not decodable)


def list_url(bucket: str, hour: datetime) -> str:
    return (f"https://{bucket}.s3.amazonaws.com/?list-type=2"
            f"&prefix={PRODUCT}/{hour:%Y/%j/%H}/")


def file_url(bucket: str, key: str) -> str:
    return f"https://{bucket}.s3.amazonaws.com/{key}"


def parse_listing(xml: str) -> List[Tuple[str, int]]:
    """S3 ListObjectsV2 XML -> [(key, size)] in key order (which is time order)."""
    out: List[Tuple[str, int]] = []
    try:
        root = ET.fromstring(xml)
    except ET.ParseError:
        return out
    for c in root.iter(f"{_S3_NS}Contents"):
        key = c.findtext(f"{_S3_NS}Key") or ""
        size = c.findtext(f"{_S3_NS}Size") or "0"
        if key.endswith(".nc"):
            out.append((key, int(size)))
    out.sort()
    return out


def start_time(key: str) -> Optional[datetime]:
    """The file's start time from its name: _sYYYYDDDHHMMSSt_."""
    m = _START_RE.search(key)
    if not m:
        return None
    y, doy, hh, mm, ss = (int(g) for g in m.groups())
    return (datetime(y, 1, 1, tzinfo=timezone.utc) + timedelta(days=doy - 1,
                                                                 hours=hh, minutes=mm, seconds=ss))


def _base_from_units(units) -> Optional[datetime]:
    if isinstance(units, bytes):
        units = units.decode("ascii", "replace")
    m = _UNITS_RE.search(str(units or ""))
    if not m:
        return None
    return datetime.fromisoformat(f"{m.group(1)}T{m.group(2)}").replace(tzinfo=timezone.utc)


def _scaled(ds):
    """A netCDF variable's values with scale_factor/add_offset applied and
    the _Unsigned convention honored (h5py applies neither)."""
    import numpy as np
    raw = ds[()]
    if str(ds.attrs.get("_Unsigned", b"")).strip("b'\"").lower() == "true" and raw.dtype.kind == "i":
        raw = raw.view({1: np.uint8, 2: np.uint16, 4: np.uint32}[raw.dtype.itemsize])
    vals = raw.astype("float64")
    scale = ds.attrs.get("scale_factor")
    offset = ds.attrs.get("add_offset")
    if scale is not None:
        vals = vals * float(np.asarray(scale).ravel()[0])
    if offset is not None:
        vals = vals + float(np.asarray(offset).ravel()[0])
    return vals


def parse_file(data: bytes, key: str = "") -> List[Flash]:
    """Flash positions and times from one GLM L2 LCFA file held in memory."""
    import h5py
    import numpy as np

    out: List[Flash] = []
    with h5py.File(io.BytesIO(data), "r") as f:
        if "flash_lat" not in f or "flash_lon" not in f:
            return out
        lat = _scaled(f["flash_lat"])
        lon = _scaled(f["flash_lon"])
        n = min(len(lat), len(lon))
        if n == 0:
            return out
        base = start_time(key)
        times = None
        if "flash_time_offset_of_first_event" in f:
            ds = f["flash_time_offset_of_first_event"]
            b = _base_from_units(ds.attrs.get("units")) or base
            if b is not None:
                times = b.timestamp() + _scaled(ds)
        if times is None:
            if base is None:
                return out
            times = np.full(n, base.timestamp())
        energy = _scaled(f["flash_energy"]) if "flash_energy" in f else np.zeros(n)
        quality = f["flash_quality_flag"][()] if "flash_quality_flag" in f else None
        for i in range(n):
            if quality is not None and int(quality[i]) not in (0, 1):
                continue   # 0 good, 1 degraded-but-usable; the rest are junk
            la, lo = float(lat[i]), float(lon[i])
            if not (-90 <= la <= 90 and -180 <= lo <= 180):
                continue
            e = float(energy[i]) if i < len(energy) and np.isfinite(energy[i]) else 0.0
            out.append(Flash(t=float(times[i]), lat=la, lon=lo, energy=max(0.0, e)))
    return out


async def list_recent(client: httpx.AsyncClient, bucket: str, now: datetime,
                      lookback: timedelta) -> List[str]:
    """Keys whose start time is within `lookback` of now. Lists the current
    UTC hour and, when the window crosses it, the previous hour too."""
    hours = [now.replace(minute=0, second=0, microsecond=0)]
    if now - lookback < hours[0]:
        hours.insert(0, hours[0] - timedelta(hours=1))
    keys: List[str] = []
    for h in hours:
        r = await client.get(list_url(bucket, h), headers={"User-Agent": USER_AGENT}, timeout=20.0)
        r.raise_for_status()
        for key, _size in parse_listing(r.text):
            st = start_time(key)
            if st is not None and st >= now - lookback:
                keys.append(key)
    return sorted(set(keys))


async def fetch_file(client: httpx.AsyncClient, bucket: str, key: str) -> List[Flash]:
    r = await client.get(file_url(bucket, key), headers={"User-Agent": USER_AGENT}, timeout=30.0)
    r.raise_for_status()
    return parse_file(r.content, key)
