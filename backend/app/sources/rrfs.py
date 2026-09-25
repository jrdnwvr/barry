"""RRFS beside HRRR, for the switch.

The Rapid Refresh Forecast System replaces HRRR, NAM and the rest on
2026-10-14 (SCN 26-48) on the same 3 km CONUS grid, but HRRR has no
retirement date. The plan is to run both through the winter and switch
when RRFS is at least as good at the stations Barry serves. So this feed
pulls RRFS's surface pressure and wind for the first three hours of every
cycle, and modelscore.py scores it against HRRR from the same cycle at the
same lead, at the METARs. Nothing is served from it.

Its files differ from HRRR's: rrfs.YYYYMMDD/HH/rrfs.tHHz.2dfld.3km.fFFF.conus.grib2,
sea-level pressure is MSLET, and the CONUS files carry no pressure levels.
Measured 2026-09-25 on the ops bucket: the hourly cycles land about 80
minutes after their time, the 06 and 18 UTC ones a few minutes later, and
the 00 and 12 UTC ones at about two hours; before the operational date some
hourly cycles are missing altogether (07, 08 and 10 UTC on the day), which
the chooser walks past. Three cycles are kept so the hour being scored is
still held when the METARs for it are in.
"""

from __future__ import annotations

from datetime import datetime
from typing import Tuple

from .hrrr import PRESSURE_OFFSET, Field, FeedSpec

AWS = "https://noaa-rrfs-ops-pds.s3.amazonaws.com"


def url(cycle: datetime, fhr: int, kind: str) -> str:
    return f"{AWS}/rrfs.{cycle:%Y%m%d}/{cycle:%H}/rrfs.t{cycle:%H}z.2dfld.3km.f{fhr:03d}.conus.grib2"


def arrival(fhr: int) -> float:
    """Minutes after the cycle time when the hour is normally on the bucket
    (2026-09-25: f001 of the hourly cycles at 78 to 82 minutes, f003 two
    minutes later; the 00 and 12 UTC cycles take about 40 minutes more and
    are simply found on a later pass)."""
    return 80.0 + 2.0 * fhr


FIELDS: Tuple[Field, ...] = (
    Field("mslp", "MSLET", "mean sea level", "sfc", 0.01, PRESSURE_OFFSET),
    Field("u10", "UGRD", "10 m above ground", "sfc"),
    Field("v10", "VGRD", "10 m above ground", "sfc"),
)

FHRS: Tuple[int, ...] = (1, 2, 3)

SFC = FeedSpec("rrfs-sfc", FIELDS, (("u10", "v10"),), lambda c: FHRS,
               stride=2, dtype="float16", keep=3, url=url, arrival=arrival)
