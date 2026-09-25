"""MRMS composite reflectivity from NOAA's AWS Open Data bucket.

NOAA's Multi-Radar Multi-Sensor system merges every NEXRAD (and Canadian)
radar into one quality-controlled grid: 0.01 degree, 7000 x 3500 points
from 55 N to 20 N and 130 W to 60 W, a new composite about every two
minutes, on the bucket about 45 seconds later. Each file is one GRIB2
message with PNG packing, gzipped, 1 to 1.4 MB; eccodes decodes it in
0.2 s. -99 means no echo, -999 no radar coverage.

Barry keeps a frame every ten minutes (the file nearest each ten-minute
mark) for two hours, as it had from RainViewer. Public domain.
"""

from __future__ import annotations

import gzip
import re
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional, Tuple
from xml.etree import ElementTree as ET

import httpx
import numpy as np

BUCKET = "https://noaa-mrms-pds.s3.amazonaws.com"
PRODUCT = "MergedReflectivityQCComposite_00.50"
USER_AGENT = "Barry/1.0 (jrdn@wvr.me)"
STEP_MIN = 10
KEEP_H = 2
MARK_TOLERANCE_S = 150        # the file must be within 2.5 minutes of its mark

_S3_NS = "{http://s3.amazonaws.com/doc/2006-03-01/}"
_TIME_RE = re.compile(r"_(\d{8})-(\d{6})\.grib2\.gz$")


def key_time(key: str) -> Optional[datetime]:
    m = _TIME_RE.search(key)
    if not m:
        return None
    return datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S").replace(tzinfo=timezone.utc)


def list_url(day: datetime, after: Optional[str] = None) -> str:
    u = f"{BUCKET}/?list-type=2&prefix=CONUS/{PRODUCT}/{day:%Y%m%d}/"
    return u + (f"&start-after={after}" if after else "")


def parse_listing(xml: str) -> List[str]:
    try:
        root = ET.fromstring(xml)
    except ET.ParseError:
        return []
    return [c.findtext(f"{_S3_NS}Key") or "" for c in root.iter(f"{_S3_NS}Contents")]


# NOAA's chance of lightning (any flash) in the next hour, from MRMS and
# GOES, on the same grid, every two minutes, about 30 KB. Percent.
LIGHTNING_NEXT = "LightningProbabilityNext60minGrid_scale_1"


async def recent_keys(client: httpx.AsyncClient, now: datetime, product: str = PRODUCT,
                      hours: float = KEEP_H) -> List[str]:
    """Keys from the last `hours` and a bit, across midnight when the
    window crosses it. A day holds about 720 keys, one listing page."""
    start = now - timedelta(hours=hours, minutes=15)
    keys: List[str] = []
    for day in sorted({start.date(), now.date()}):
        d = datetime(day.year, day.month, day.day, tzinfo=timezone.utc)
        after = f"CONUS/{product}/{d:%Y%m%d}/MRMS_{product}_{max(d, start):%Y%m%d-%H%M%S}.grib2.gz"
        u = f"{BUCKET}/?list-type=2&prefix=CONUS/{product}/{d:%Y%m%d}/&start-after={after}"
        r = await client.get(u, headers={"User-Agent": USER_AGENT}, timeout=20.0)
        r.raise_for_status()
        keys += parse_listing(r.text)
    return sorted(k for k in keys if key_time(k) is not None)


def marks(now: datetime) -> List[datetime]:
    """Ten-minute marks over the last KEEP_H hours, oldest first."""
    top = now.replace(minute=(now.minute // STEP_MIN) * STEP_MIN, second=0, microsecond=0)
    n = KEEP_H * 60 // STEP_MIN
    return [top - timedelta(minutes=STEP_MIN * i) for i in range(n, -1, -1)]


def pick(keys: List[str], now: datetime) -> Dict[datetime, str]:
    """For each mark, the file nearest it within the tolerance."""
    times = [(key_time(k), k) for k in keys]
    out: Dict[datetime, str] = {}
    for m in marks(now):
        best = None
        for t, k in times:
            d = abs((t - m).total_seconds())
            if d <= MARK_TOLERANCE_S and (best is None or d < best[0]):
                best = (d, k)
        if best:
            out[m] = best[1]
    return out


def decode(gz: bytes, percent: bool = False) -> Tuple[np.ndarray, dict]:
    """dBZ as uint8 codes (dBZ = code / 2 - 32; 0 is no echo or no
    coverage), or with `percent` the value itself (0 to 100), and the
    grid's corner and spacing, rows north to south."""
    import eccodes
    data = gzip.decompress(gz)
    h = eccodes.codes_new_from_message(data)
    try:
        meta = {k: eccodes.codes_get(h, k) for k in (
            "Ni", "Nj", "latitudeOfFirstGridPointInDegrees", "longitudeOfFirstGridPointInDegrees",
            "iDirectionIncrementInDegrees", "jDirectionIncrementInDegrees", "jScansPositively")}
        vals = eccodes.codes_get_values(h).astype(np.float32)
    finally:
        eccodes.codes_release(h)
    ni, nj = int(meta["Ni"]), int(meta["Nj"])
    v = vals.reshape(nj, ni)
    if int(meta["jScansPositively"]) == 1:
        v = v[::-1]
    if percent:
        codes = np.clip(np.rint(v), 0, 100).astype(np.uint8)
    else:
        codes = np.clip(np.rint((v + 32.0) * 2.0), 0, 255).astype(np.uint8)
        codes[v < -32] = 0                  # -99 no echo, -999 no coverage
    lon0 = float(meta["longitudeOfFirstGridPointInDegrees"])
    return codes, {
        "lat0": float(meta["latitudeOfFirstGridPointInDegrees"]),
        "lon0": lon0 - 360.0 if lon0 > 180 else lon0,
        "dlat": float(meta["jDirectionIncrementInDegrees"]),
        "dlon": float(meta["iDirectionIncrementInDegrees"]),
    }


async def fetch(client: httpx.AsyncClient, key: str) -> bytes:
    r = await client.get(f"{BUCKET}/{key}", headers={"User-Agent": USER_AGENT}, timeout=60.0)
    r.raise_for_status()
    return r.content
