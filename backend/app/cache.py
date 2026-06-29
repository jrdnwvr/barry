"""Tiny in-memory TTL cache + an active-station registry.

Deliberately dependency-free (no Redis) so the backend runs with `pip install`
and nothing else. The interface is small enough to swap for Redis later: get/set
with per-key TTL. Not safe across processes — run a single worker, or move to
Redis when you scale out.
"""

from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass
from typing import Any, Dict, Generic, List, Optional, TypeVar

T = TypeVar("T")


@dataclass
class _Entry(Generic[T]):
    value: T
    expires_at: float


class TTLCache:
    def __init__(self, *, default_ttl: float = 600.0, clock=time.monotonic) -> None:
        self._store: Dict[str, _Entry[Any]] = {}
        self._default_ttl = default_ttl
        self._clock = clock
        self._lock = asyncio.Lock()

    async def get(self, key: str) -> Optional[Any]:
        async with self._lock:
            entry = self._store.get(key)
            if entry is None:
                return None
            if entry.expires_at <= self._clock():
                self._store.pop(key, None)
                return None
            return entry.value

    async def set(self, key: str, value: Any, *, ttl: Optional[float] = None) -> None:
        async with self._lock:
            self._store[key] = _Entry(
                value=value,
                expires_at=self._clock() + (ttl if ttl is not None else self._default_ttl),
            )

    async def keys(self) -> List[str]:
        async with self._lock:
            return list(self._store.keys())


class StationRegistry:
    """Tracks which stations clients have asked about recently.

    The scheduler batch-refreshes exactly this set, so cost scales with the number
    of *watched stations*, not the number of users. Stations expire out of the
    registry after `ttl` seconds of no requests (default 24h per the brief).
    """

    def __init__(self, *, ttl: float = 24 * 3600.0, clock=time.monotonic) -> None:
        self._seen: Dict[str, float] = {}
        self._ttl = ttl
        self._clock = clock
        self._lock = asyncio.Lock()

    async def touch(self, station: str) -> None:
        async with self._lock:
            self._seen[station.upper()] = self._clock()

    async def active(self) -> List[str]:
        now = self._clock()
        async with self._lock:
            # prune expired entries while we're here
            self._seen = {
                s: ts for s, ts in self._seen.items() if now - ts <= self._ttl
            }
            return sorted(self._seen.keys())
