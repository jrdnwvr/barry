"""NOMADS, NCEP's own real-time server, as a polite client.

NOMADS publishes no per-minute cap, but its grib filter page asks scripts
to wait 10 seconds between fetches and warns that a client fetching too
fast can be taken for a denial of service and blocked. Every Barry request
to it goes through `get`, which keeps its own requests at least
`spacing()` seconds apart, whatever loop they come from.

Directory listings come back as an empty 200 over HTTP/2, so file names
are built from the cycle time instead of listed. httpx speaks HTTP/1.1
unless asked, which is what listings need anyway.
"""

from __future__ import annotations

import asyncio
import os
import time
from typing import Optional

import httpx

USER_AGENT = "Barry/1.0 (jrdn@wvr.me)"
BASE = "https://nomads.ncep.noaa.gov/pub/data/nccf/com"

_lock: Optional[asyncio.Lock] = None
_last = 0.0


def spacing() -> float:
    try:
        return float(os.environ.get("BARRY_NOMADS_SPACING", "10"))
    except ValueError:
        return 10.0


def url(path: str) -> str:
    return f"{BASE}/{path.lstrip('/')}"


async def get(client: httpx.AsyncClient, target: str, *, timeout: float = 60.0) -> httpx.Response:
    """One request, spaced from the last. Raises for HTTP errors; a 404 is
    the usual answer for a run that has not landed yet."""
    global _lock, _last
    if _lock is None:
        _lock = asyncio.Lock()
    async with _lock:
        wait = _last + spacing() - time.monotonic()
        if wait > 0:
            await asyncio.sleep(wait)
        try:
            r = await client.get(target, headers={"User-Agent": USER_AGENT}, timeout=timeout)
        finally:
            _last = time.monotonic()
    r.raise_for_status()
    return r
