"""WPC coded surface fronts — the analysis (CODSUS) and the 12/24/36/48 h
forecast positions (CODSRP), fetched as text from the IEM AFOS archive.

The Weather Prediction Center codes every front on its surface chart as a
typed polyline of lat/lon points, plus HIGH/LOW centers with pressures. Two
bulletins:

    ASUS01 KWBC / CODSUS   current analysis      "VALID MMDDHHZ"
    FSUS02 KWBC / CODSRP   12/24/36/48 HR PROG   "NNHR PROG VALID DDHHMMZ"

Front lines: TYPE [WK] pt pt pt ... where TYPE is COLD, WARM, STNRY, OCFNT or
TROF, WK marks a weak front, and long lines wrap onto continuation lines that
start with a bare number. Points are coded as latitude then longitude with no
separator, longitude WEST, in whole degrees (4-5 digits) or tenths (6-7
digits: LLL+OOO or LLL+OOOO). Whole degrees is what the analysis actually
uses, so positions are good to roughly 50 mi — the key says so.

Direction of motion convention, checked against today's real chart: a front
moves toward the LEFT of the direction of travel along its listed points.
The client draws the pips on that side.
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple

import httpx

from ..models import FrontFrame, FrontLine, PressureCenter

AFOS_URL = "https://mesonet.agron.iastate.edu/cgi-bin/afos/retrieve.py"
USER_AGENT = "Barry/1.0 (jrdn@wvr.me)"

FRONT_TYPES = {"COLD", "WARM", "STNRY", "OCFNT", "TROF"}
CENTER_TYPES = {"HIGHS", "LOWS"}
_MONTHS = {m: i for i, m in enumerate(
    ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"], 1)}


def decode_point(token: str) -> Optional[Tuple[float, float]]:
    """'4865' -> (48, -65); '38107' -> (38, -107); '4512945' -> (45.1, -129.45)."""
    if not token.isdigit():
        return None
    n = len(token)
    if n == 4:
        lat, lon = int(token[:2]), int(token[2:])
    elif n == 5:
        lat, lon = int(token[:2]), int(token[2:])
    elif n == 6:
        lat, lon = int(token[:3]) / 10.0, int(token[3:]) / 10.0
    elif n == 7:
        lat, lon = int(token[:3]) / 10.0, int(token[3:]) / 10.0
    else:
        return None
    if not (0 < lat <= 90 and 0 < lon <= 180):
        return None
    return float(lat), -float(lon)


def _issue_month_year(text: str) -> Tuple[int, int]:
    """From the human date line: '1221 PM EDT MON SEP 14 2026' -> (9, 2026)."""
    m = re.search(r"\b([A-Z]{3}) (\d{1,2}) (\d{4})\b", text)
    if m and m.group(1) in _MONTHS:
        return _MONTHS[m.group(1)], int(m.group(3))
    now = datetime.now(timezone.utc)
    return now.month, now.year


def _valid_datetime(token: str, *, analysis: bool, month: int, year: int) -> Optional[datetime]:
    """Analysis: MMDDHHZ. Prog: DDHHMMZ (day may roll into next month)."""
    digits = token.rstrip("Z")
    if len(digits) != 6 or not digits.isdigit():
        return None
    try:
        if analysis:
            mm, dd, hh = int(digits[:2]), int(digits[2:4]), int(digits[4:])
            # A January analysis in a December-dated bulletin is next year.
            y = year + 1 if mm < month else year
            return datetime(y, mm, dd, hh, tzinfo=timezone.utc)
        dd, hh, mi = int(digits[:2]), int(digits[2:4]), int(digits[4:])
        return datetime(year, month, dd, hh, mi, tzinfo=timezone.utc)
    except ValueError:
        return None


def parse_frames(text: str) -> List[FrontFrame]:
    """Parse one bulletin (analysis or prog) into FrontFrames, in order."""
    month, year = _issue_month_year(text)
    frames: List[FrontFrame] = []
    cur: Optional[FrontFrame] = None
    line_re = re.compile(r"^(?:(\d{2})HR PROG )?VALID (\d{6}Z)\s*$")

    record_type: Optional[str] = None
    record_weak = False
    record_tokens: List[str] = []

    def flush():
        nonlocal record_type, record_tokens, record_weak
        if cur is None or record_type is None:
            record_type, record_tokens, record_weak = None, [], False
            return
        if record_type in CENTER_TYPES:
            toks = record_tokens
            for i in range(0, len(toks) - 1, 2):
                pt = decode_point(toks[i + 1])
                if pt and toks[i].isdigit():
                    target = cur.highs if record_type == "HIGHS" else cur.lows
                    target.append(PressureCenter(pressure=int(toks[i]), lat=pt[0], lon=pt[1]))
        else:
            pts = [p for p in (decode_point(t) for t in record_tokens) if p]
            if len(pts) >= 2:
                cur.fronts.append(FrontLine(
                    type=record_type.lower(), weak=record_weak,
                    points=[[p[0], p[1]] for p in pts]))
        record_type, record_tokens, record_weak = None, [], False

    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        m = line_re.match(line)
        if m:
            flush()
            hours = int(m.group(1)) if m.group(1) else 0
            valid = _valid_datetime(m.group(2), analysis=(hours == 0), month=month, year=year)
            # Prog days roll into the next month when the day count wraps.
            if valid is not None and hours and frames and valid < frames[0].valid:
                mm = month + 1 if month < 12 else 1
                yy = year if month < 12 else year + 1
                valid = valid.replace(month=mm, year=yy)
            if valid is None:
                cur = None
                continue
            cur = FrontFrame(hours=hours, valid=valid)
            frames.append(cur)
            continue
        if cur is None:
            continue
        tokens = line.split()
        head = tokens[0]
        if head in FRONT_TYPES or head in CENTER_TYPES:
            flush()
            record_type = head
            rest = tokens[1:]
            if rest and rest[0] == "WK":
                record_weak = True
                rest = rest[1:]
            record_tokens.extend(rest)
        elif head.isdigit() and record_type is not None:
            record_tokens.extend(tokens)   # wrapped continuation line
        else:
            flush()                        # any other header text ends a record
    flush()
    return frames


async def _fetch_text(client: httpx.AsyncClient, pil: str) -> str:
    resp = await client.get(
        AFOS_URL, params={"pil": pil, "fmt": "text"},
        headers={"User-Agent": USER_AGENT}, timeout=15.0,
    )
    resp.raise_for_status()
    return resp.text


async def fetch_fronts(client: httpx.AsyncClient) -> Dict[str, List[FrontFrame]]:
    """{'analysis': [frame], 'progs': [12h, 24h, 36h, 48h frames]} — either
    list may be empty if that bulletin is unavailable."""
    out: Dict[str, List[FrontFrame]] = {"analysis": [], "progs": []}
    try:
        out["analysis"] = parse_frames(await _fetch_text(client, "CODSUS"))[:1]
    except Exception:
        pass
    try:
        out["progs"] = [f for f in parse_frames(await _fetch_text(client, "CODSRP")) if f.hours]
    except Exception:
        pass
    return out
