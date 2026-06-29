"""Periodic batched METAR refresh for the set of actively-watched stations.

The whole point (brief §2.3): collapse N users onto ~M requests/cycle by batching
every active station id into one comma-separated AWC call, on a fixed interval.
With AWC's 100 req/min ceiling, one batched call per 10-minute cycle is trivially
under budget even with hundreds of stations.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone
from typing import List, Optional

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
        self._stop = asyncio.Event()
        self.cycles = 0
        self.last_request_count = 0

    async def refresh_once(self) -> int:
        """Refresh all active stations in batched calls. Returns #upstream calls."""
        active = await self._service.registry.active()
        if not active:
            log.info("scheduler: no active stations; skipping cycle")
            return 0

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
                resp = PressureResponse(
                    station=sid,
                    name=parsed.get("name"),
                    lat=parsed.get("lat"),
                    lon=parsed.get("lon"),
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

    def start(self) -> None:
        if self._task is None:
            self._stop.clear()
            self._task = asyncio.create_task(self._run())
            log.info("scheduler: started, interval=%.0fs", self._interval)

    async def stop(self) -> None:
        self._stop.set()
        if self._task is not None:
            await self._task
            self._task = None
