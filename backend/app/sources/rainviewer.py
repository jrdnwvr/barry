"""RainViewer frame list — the radar timeline's source of truth.

One request for `weather-maps.json` yields every available past frame plus
the short nowcast; the app only ever showed the last seven and the first
three, so that selection happens here and the phone receives just those.
Tiles themselves still come from RainViewer's CDN (`host`), as they ask.
"""

from __future__ import annotations

from typing import List

import httpx

from ..models import RadarFrameOut, RadarFramesResponse

MAPS_URL = "https://api.rainviewer.com/public/weather-maps.json"
USER_AGENT = "Barry/1.0 (jrdn@wvr.me)"
PAST_FRAMES = 7
NOWCAST_FRAMES = 3


def parse_frames(data: dict) -> tuple[str, List[RadarFrameOut]]:
    radar = data.get("radar") or {}
    past = [RadarFrameOut(time=int(e["time"]), path=e["path"], nowcast=False)
            for e in (radar.get("past") or [])[-PAST_FRAMES:]]
    cast = [RadarFrameOut(time=int(e["time"]), path=e["path"], nowcast=True)
            for e in (radar.get("nowcast") or [])[:NOWCAST_FRAMES]]
    return data.get("host") or "https://tilecache.rainviewer.com", past + cast


async def fetch_frames(client: httpx.AsyncClient, *, now) -> RadarFramesResponse:
    r = await client.get(MAPS_URL, headers={"User-Agent": USER_AGENT}, timeout=10.0)
    r.raise_for_status()
    host, frames = parse_frames(r.json())
    return RadarFramesResponse(host=host, frames=frames, cachedAt=now)
