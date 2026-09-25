"""LAMP: MDL's hourly station guidance, from NOMADS.

GFS LAMP runs every hour at :30 for about 2,300 sites, including fields
that issue no TAF, and forecasts each hour out to 25 hours: temperature,
dew point, wind and gust, precipitation and lightning probability, and
ceiling and visibility as categories. The whole country is one 4.4 MB
fixed-column text bulletin, pulled once an hour for everyone. Public
domain. It is not on the AWS buckets, which is why this reads NOMADS.

The bulletin, one block per station, a blank line between blocks:

     KI69   GFS LAMP GUIDANCE   9/24/2026  2130 UTC
     UTC  22 23 00 01 02 ...
     TMP  65 64 61 59 57 ...
     WDR  06 06 06 05 05 ...     tens of degrees
     WSP  05 04 03 02 01 ...     knots
     WGS  NG NG NG NG NG ...     knots, NG for no gust
     P01   0  0  0  0  0 ...     % chance of precipitation in the hour
     LP1   0  0  0  0  0 ...     % chance of lightning in the hour
     CIG   5  6  6  8  8 ...     category, below
     VIS   7  7  7  7  7 ...     category, below

Each value sits in a three-character column after a five-character label,
and some rows (P06) leave columns blank, so rows are read by position,
never split on spaces. Not every station carries every row.
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional

from ..models import LampHour, LampOut
from . import nomads

# Ceiling categories to a representative height in feet (the middle of the
# band); 8 is above 12,000 ft or no ceiling at all.
#   1 <200  2 200-400  3 500-900  4 1000-1900  5 2000-3000
#   6 3100-6500  7 6600-12000  8 >12000 or unlimited
CIG_FT = {1: 100, 2: 300, 3: 700, 4: 1500, 5: 2500, 6: 4800, 7: 9300}
# Visibility categories to statute miles (the lower edge, except 7).
#   1 <1/2  2 1/2 to <1  3 1 to <2  4 2 to <3  5 3-5  6 6  7 >6
VIS_SM = {1: 0.25, 2: 0.5, 3: 1.0, 4: 2.0, 5: 3.0, 6: 6.0, 7: 10.0}

_HEAD = re.compile(r"^\s*([A-Z0-9]{3,5})\s+GFS LAMP GUIDANCE\s+(\d{1,2})/(\d{1,2})/(\d{4})\s+(\d{2})(\d{2}) UTC")


def run_for(now: datetime) -> datetime:
    """The newest hourly run that should be on NOMADS: the :30 run, given
    eight minutes to land (they arrive about six minutes after)."""
    t = now - timedelta(minutes=38)
    return t.replace(minute=30, second=0, microsecond=0)


def bulletin_path(run: datetime) -> str:
    return f"lmp/prod/lmp.{run:%Y%m%d}/lmp.t{run:%H%M}z.lavtxt.ascii"


def flight_category(cig: Optional[int], vis: Optional[int]) -> Optional[str]:
    """The category the two bands imply, by the FAA's limits: LIFR under
    500 ft or 1 mile, IFR under 1,000 ft or 3 miles, MVFR to 3,000 ft or
    5 miles."""
    if cig is None and vis is None:
        return None
    c = cig or 8
    v = vis or 7
    if c <= 2 or v <= 2:
        return "LIFR"
    if c == 3 or v in (3, 4):
        return "IFR"
    if c in (4, 5) or v == 5:
        return "MVFR"
    return "VFR"


def _cells(line: str, n: int) -> List[str]:
    return [line[5 + 3 * k: 8 + 3 * k].strip() for k in range(n)]


def _int(s: str) -> Optional[int]:
    try:
        return int(s)
    except (TypeError, ValueError):
        return None


def _f_to_c(s: str) -> Optional[float]:
    v = _int(s)
    return None if v is None else round((v - 32) * 5 / 9, 1)


def _block(lines: List[str]) -> Optional[LampOut]:
    m = _HEAD.match(lines[0])
    if not m:
        return None
    sid, mo, day, yr, hh, mm = m.groups()
    run = datetime(int(yr), int(mo), int(day), int(hh), int(mm), tzinfo=timezone.utc)
    rows: Dict[str, str] = {}
    for line in lines[1:]:
        label = line[:5].strip()
        if label:
            rows[label] = line
    if "UTC" not in rows:
        return None
    hours_raw = [_int(c) for c in rows["UTC"][5:].split()]
    n = len(hours_raw)
    cells = {k: _cells(v, n) for k, v in rows.items() if k != "UTC"}

    def col(key: str, i: int) -> str:
        c = cells.get(key)
        return c[i] if c and i < len(c) else ""

    out: List[LampHour] = []
    t = run.replace(minute=0)
    for i, h in enumerate(hours_raw):
        if h is None:
            continue
        t += timedelta(hours=1)
        for _ in range(24):
            if t.hour == h:
                break
            t += timedelta(hours=1)
        cig, vis = _int(col("CIG", i)), _int(col("VIS", i))
        wdr, wsp = _int(col("WDR", i)), _int(col("WSP", i))
        gust = col("WGS", i)
        out.append(LampHour(
            t=t,
            fltCat=flight_category(cig, vis),
            cigCat=cig, cigFt=CIG_FT.get(cig) if cig else None,
            visCat=vis, visSM=VIS_SM.get(vis) if vis else None,
            windDir=None if wdr is None or wsp == 0 else wdr * 10.0,
            windKt=None if wsp is None else float(wsp),
            gustKt=None if gust in ("", "NG") else (None if _int(gust) is None else float(_int(gust))),
            tempC=_f_to_c(col("TMP", i)), dewC=_f_to_c(col("DPT", i)),
            pop1=_int(col("P01", i)), ltg1=_int(col("LP1", i)),
            cloud=col("CLD", i) or None,
            obv=None if col("OBV", i) in ("", "N") else col("OBV", i),
        ))
    return LampOut(station=sid, runTime=run, hours=out)


def parse(text: str) -> Dict[str, LampOut]:
    """Every station in a bulletin, keyed by its id."""
    out: Dict[str, LampOut] = {}
    block: List[str] = []
    for line in text.splitlines() + [""]:
        if line.strip():
            block.append(line.rstrip())
            continue
        if block:
            try:
                st = _block(block)
            except Exception:
                st = None
            if st is not None and st.hours:
                out[st.station] = st
            block = []
    return out


async def fetch(client, run: datetime) -> Dict[str, LampOut]:
    import asyncio
    r = await nomads.get(client, nomads.url(bulletin_path(run)))
    # A quarter of a second of string work; keep it off the event loop.
    return await asyncio.to_thread(parse, r.text)
