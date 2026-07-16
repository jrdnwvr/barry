"""Iowa Environmental Mesonet — HRRR forecast reflectivity tile metadata.

IEM serves HRRR simulated composite reflectivity as standard TMS tiles:

    https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0/
        hrrr::REFD-F{MMMM}-{YYYYMMDDHHMI}/{z}/{x}/{y}.png

where F{MMMM} is the forecast minute and the trailing stamp is the model run
init time. The client fetches tiles directly (like RainViewer — the backend
stays out of the image business); what it cannot do cheaply is discover WHICH
run is the latest, and labeling forecast valid times against the wrong run
would put wrong times in front of a pilot. So the backend resolves the run.

There is no metadata endpoint for this on IEM (tms.json only lists the RIDGE
composites), but probing is trivial: a well-formed layer for a run IEM doesn't
have answers 503 text/plain, and a run it does have answers 200 image/png. So
walk back hour by hour until a tile answers as an image. HRRR runs hourly and
lands on IEM ~1-2 h after init; the walk almost always stops within 3 steps.
(Malformed layer NAMES get a 200 red "Invalid TMS Request" PNG instead — our
names are templated, so that case can't arise, but it's why the check demands
both the status and the content type.)
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Optional

import httpx

TILE_BASE = "https://mesonet.agron.iastate.edu/cache/tile.py/1.0.0"
USER_AGENT = "Barry/1.0 (jrdn@wvr.me)"

# Any always-CONUS tile works as the probe target; z5 keeps it a few KB.
PROBE_TILE = "5/8/12"
MAX_WALK_BACK_H = 7


async def _has_tiles(client: httpx.AsyncClient, layer: str) -> bool:
    try:
        resp = await client.get(
            f"{TILE_BASE}/{layer}/{PROBE_TILE}.png",
            headers={"User-Agent": USER_AGENT},
            timeout=10.0,
        )
    except Exception:
        return False
    return (resp.status_code == 200
            and resp.headers.get("content-type", "").startswith("image"))


async def latest_hrrr_run(client: httpx.AsyncClient) -> Optional[datetime]:
    """The most recent HRRR run IEM is actually serving tiles for, or None."""
    now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    for back in range(MAX_WALK_BACK_H):
        run = now - timedelta(hours=back)
        if await _has_tiles(client, f"hrrr::REFD-F0060-{run:%Y%m%d%H%M}"):
            return run
    return None
