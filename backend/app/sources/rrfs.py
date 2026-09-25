"""RRFS beside HRRR, for the switch.

The Rapid Refresh Forecast System replaces HRRR, NAM and the rest on
2026-10-14 (SCN 26-48) on the same 3 km CONUS grid, but HRRR has no
retirement date. The plan is to run both through the winter and switch
when RRFS is at least as good at the stations Barry serves. So this feed
pulls RRFS's surface pressure and wind for the first six hours of the four
long cycles a day, and modelscore.py scores it and HRRR against METARs.
Nothing is served from it.

Its files differ from HRRR's: rrfs.YYYYMMDD/HH/rrfs.tHHz.2dfld.3km.fFFF.conus.grib2,
sea-level pressure is MSLET, and it lands about two hours after its time.
The CONUS files carry no pressure levels.
"""

from __future__ import annotations

from datetime import datetime
from typing import Tuple

from .hrrr import PRESSURE_OFFSET, Field, FeedSpec

AWS = "https://noaa-rrfs-ops-pds.s3.amazonaws.com"


def url(cycle: datetime, fhr: int, kind: str) -> str:
    return f"{AWS}/rrfs.{cycle:%Y%m%d}/{cycle:%H}/rrfs.t{cycle:%H}z.2dfld.3km.f{fhr:03d}.conus.grib2"


def arrival(fhr: int) -> float:
    """Measured 2026-09-25: f001 of the 00z cycle at 117 minutes."""
    return 115.0 + 3.0 * fhr


FIELDS: Tuple[Field, ...] = (
    Field("mslp", "MSLET", "mean sea level", "sfc", 0.01, PRESSURE_OFFSET),
    Field("u10", "UGRD", "10 m above ground", "sfc"),
    Field("v10", "VGRD", "10 m above ground", "sfc"),
)

SFC = FeedSpec("rrfs-sfc", FIELDS, (("u10", "v10"),),
               lambda c: tuple(range(1, 7)) if c.hour % 6 == 0 else (),
               stride=2, dtype="float16", keep=1, url=url, arrival=arrival)
