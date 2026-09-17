"""Periodic batched METAR refresh for the set of actively-watched stations.

The whole point (brief §2.3): collapse N users onto ~M requests/cycle by batching
every active station id into one comma-separated AWC call, on a fixed interval.
With AWC's 100 req/min ceiling, one batched call per 10-minute cycle is trivially
under budget even with hundreds of stations.
"""

from __future__ import annotations

import asyncio
import logging
import os
from datetime import datetime, timezone
from typing import List, Optional

from . import persist
from .models import PressureResponse
from .service import PRESSURE_TTL, PressureService, _now, _tendency_out
from .sources import aviationweather as awc

log = logging.getLogger("barry.scheduler")

# AWC accepts many ids per call, but keep batches bounded to avoid giant URLs.
MAX_IDS_PER_BATCH = 50


class Scheduler:
    def __init__(
        self,
        service: PressureService,
        *,
        interval_seconds: float = 600.0,
    ) -> None:
        self._service = service
        self._interval = interval_seconds
        self._task: Optional[asyncio.Task] = None
        self._glm_task: Optional[asyncio.Task] = None
        self._stop = asyncio.Event()
        self.cycles = 0
        self.last_request_count = 0
        self.glm_cycles = 0

    async def refresh_once(self) -> int:
        """Refresh all active stations in batched calls. Returns #upstream calls."""
        # Warm the whole-world METAR table and the station directory so no
        # request waits on AWC for either.
        try:
            await self._service.metar_bulk()
            await self._service.station_info()
        except Exception as exc:
            log.warning("scheduler: bulk metar warm failed: %s", exc)

        active = await self._service.registry.active()
        persist.save("registry", active)
        if not active:
            log.info("scheduler: no active stations; skipping cycle")
            return 0
        try:
            info = await self._service.station_info()
        except Exception:
            info = {}

        batches = [
            active[i : i + MAX_IDS_PER_BATCH]
            for i in range(0, len(active), MAX_IDS_PER_BATCH)
        ]
        request_count = 0
        for batch in batches:
            try:
                parsed_all = await awc.fetch_metars(batch, self._service._client, hours=24)
                request_count += 1
            except Exception as exc:  # one bad batch shouldn't sink the cycle
                log.warning("scheduler: batch %s failed: %s", batch, exc)
                continue
            for sid in batch:
                parsed = parsed_all.get(sid)
                if parsed is None:
                    continue
                tendency = awc.build_tendency(parsed)
                # Same shape as get_pressure builds: elevation included, or
                # density altitude and the MSL boundary layer vanish ten
                # minutes after every restart.
                elev = parsed.get("elev")
                if elev is None:
                    elev = (info.get(sid) or {}).get("elev")
                resp = PressureResponse(
                    station=sid,
                    name=parsed.get("name") or (info.get(sid) or {}).get("name"),
                    lat=parsed.get("lat"),
                    lon=parsed.get("lon"),
                    elevM=elev,
                    series=parsed["series"],
                    current=parsed["current"],
                    tendency=_tendency_out(tendency),
                    source="aviationweather.gov",
                    cachedAt=_now(),
                )
                await self._service.cache.set(
                    f"pressure:{sid}:24", resp, ttl=PRESSURE_TTL
                )

        self.cycles += 1
        self.last_request_count = request_count
        log.info(
            "scheduler: cycle %d refreshed %d stations in %d batched request(s) "
            "(well under 100/min)",
            self.cycles,
            len(active),
            request_count,
        )
        return request_count

    async def _run(self) -> None:
        while not self._stop.is_set():
            try:
                await self.refresh_once()
            except Exception:  # never let the loop die
                log.exception("scheduler: unexpected error in cycle")
            try:
                await asyncio.wait_for(self._stop.wait(), timeout=self._interval)
            except asyncio.TimeoutError:
                pass

    # GLM files land every 20 s; a minute poll keeps the map within about
    # a minute of real time at a fixed cost no user count can change.
    GLM_INTERVAL = 60.0

    async def _run_glm(self) -> None:
        while not self._stop.is_set():
            try:
                await self._service.poll_lightning()
                self.glm_cycles += 1
            except Exception:
                log.exception("scheduler: glm poll error")
            try:
                await asyncio.wait_for(self._stop.wait(), timeout=self.GLM_INTERVAL)
            except asyncio.TimeoutError:
                pass

    def start(self) -> None:
        if self._task is None:
            self._stop.clear()
            self._task = asyncio.create_task(self._run())
            log.info("scheduler: started, interval=%.0fs", self._interval)
        if self._glm_task is None and os.environ.get("BARRY_GLM", "1") != "0":
            self._glm_task = asyncio.create_task(self._run_glm())
            log.info("scheduler: glm poll started, interval=%.0fs", self.GLM_INTERVAL)

    async def stop(self) -> None:
        self._stop.set()
        if self._task is not None:
            await self._task
            self._task = None
        if self._glm_task is not None:
            await self._glm_task
            self._glm_task = None
