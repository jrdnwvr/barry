"""NOAA's buoys and coastal stations (NDBC), for the radar's station layer.

One file, `latest_obs.txt`, carries the newest report from every buoy and
C-MAN station: about 850 rows and 100 KB, of which about 600 are in and
around the US. One fetch every ten minutes serves everyone, the same fixed
cost as the METAR table. The data is NOAA's and public domain.

Columns (row two gives the units): STN LAT LON YYYY MM DD hh mm WDIR WSPD
GST WVHT DPD APD MWD PRES PTDY ATMP WTMP DEWP VIS TIDE. "MM" is missing.
Wind in m/s, waves in metres and seconds, pressure and its tendency in hPa,
temperatures in °C.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import List, Optional

import httpx

from ..models import StationObs

URL = "https://www.ndbc.noaa.gov/data/latest_obs/latest_obs.txt"
USER_AGENT = "Barry/1.0 (jrdn@wvr.me)"
MAX_AGE = timedelta(hours=3)
MS_TO_KT = 1.943844
M_TO_FT = 3.28084


def _num(v: str) -> Optional[float]:
    if v in ("MM", ""):
        return None
    try:
        return float(v)
    except ValueError:
        return None


def parse(text: str, *, now: datetime) -> List[StationObs]:
    """Every row with wind or pressure that is under three hours old."""
    out: List[StationObs] = []
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        f = line.split()
        if len(f) < 20:
            continue
        lat, lon = _num(f[1]), _num(f[2])
        if lat is None or lon is None:
            continue
        try:
            at = datetime(int(f[3]), int(f[4]), int(f[5]), int(f[6]), int(f[7]), tzinfo=timezone.utc)
        except ValueError:
            continue
        if now - at > MAX_AGE:
            continue
        wdir, wspd, gst = _num(f[8]), _num(f[9]), _num(f[10])
        wvht, dpd = _num(f[11]), _num(f[12])
        pres, ptdy = _num(f[15]), _num(f[16])
        atmp, wtmp, dewp = _num(f[17]), _num(f[18]), _num(f[19])
        if wspd is None and pres is None:
            continue
        out.append(StationObs(
            id=f[0], lat=lat, lon=lon, kind="buoy", obsTime=at,
            windKt=round(wspd * MS_TO_KT, 1) if wspd is not None else None,
            windDir=wdir,
            gustKt=round(gst * MS_TO_KT, 1) if gst is not None else None,
            slp=pres, presTend=ptdy, temp=atmp, dewpoint=dewp,
            waveFt=round(wvht * M_TO_FT, 1) if wvht is not None else None,
            wavePeriodS=dpd, waterTempC=wtmp,
            raw=line.strip(),
        ))
    return out


async def fetch(client: httpx.AsyncClient, *, now: datetime) -> List[StationObs]:
    resp = await client.get(URL, headers={"User-Agent": USER_AGENT}, timeout=15.0)
    resp.raise_for_status()
    return parse(resp.text, now=now)
