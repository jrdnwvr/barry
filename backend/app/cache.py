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


class CachedFailure(LookupError):
    """A LookupError, so every route that already turns "could not get it"
    into a 503 handles the remembered failure the same way as the first. An upstream failed recently and the failure is still being remembered.
    Raised by `fetch` without calling the fetcher again."""


@dataclass
class _Failure:
    reason: str


class TTLCache:
    def __init__(self, *, default_ttl: float = 600.0, max_entries: int = 5000,
                 clock=time.monotonic) -> None:
        self._store: Dict[str, _Entry[Any]] = {}
        self._default_ttl = default_ttl
        self._max = max_entries
        self._clock = clock
        self._lock = asyncio.Lock()
        self._inflight: Dict[str, "asyncio.Future[Any]"] = {}
        self._sets = 0

    async def get(self, key: str) -> Optional[Any]:
        async with self._lock:
            entry = self._store.get(key)
            if entry is None:
                return None
            if entry.expires_at <= self._clock():
                self._store.pop(key, None)
                return None
            # A remembered failure is not a value to anyone reading plainly.
            if isinstance(entry.value, _Failure):
                return None
            return entry.value

    async def set(self, key: str, value: Any, *, ttl: Optional[float] = None) -> None:
        async with self._lock:
            self._store[key] = _Entry(
                value=value,
                expires_at=self._clock() + (ttl if ttl is not None else self._default_ttl),
            )
            self._sets += 1
            if self._sets % 200 == 0 or len(self._store) > self._max:
                self._sweep_locked()

    def _sweep_locked(self) -> None:
        """Drop expired entries; if still over the cap, drop the ones that
        expire soonest. Bounded memory without an LRU chain."""
        now = self._clock()
        for k in [k for k, e in self._store.items() if e.expires_at <= now]:
            del self._store[k]
        excess = len(self._store) - self._max
        if excess > 0:
            for k, _ in sorted(self._store.items(), key=lambda kv: kv[1].expires_at)[:excess]:
                del self._store[k]

    async def fetch(self, key: str, fn, *, ttl, negative_ttl: Optional[float] = None,
                    bypass_read: bool = False) -> Any:
        """The value for `key`, fetching it with `fn()` on a miss.

        Single-flight: concurrent misses on one key share one call. Negative
        caching: when `negative_ttl` is set and `fn` raises, the failure is
        remembered for that long and later callers get CachedFailure at once,
        so a down upstream is probed once per window, not once per request.
        `ttl` is a number or a callable of the value."""
        if not bypass_read:
            async with self._lock:
                entry = self._store.get(key)
                if entry is not None and entry.expires_at > self._clock():
                    if isinstance(entry.value, _Failure):
                        raise CachedFailure(entry.value.reason)
                    return entry.value
        fut = self._inflight.get(key)
        if fut is not None:
            return await asyncio.shield(fut)
        loop = asyncio.get_running_loop()
        fut = loop.create_future()
        self._inflight[key] = fut
        try:
            value = await fn()
        except BaseException as exc:
            if negative_ttl and not isinstance(exc, asyncio.CancelledError):
                await self.set(key, _Failure(type(exc).__name__), ttl=negative_ttl)
            if not fut.done():
                fut.set_exception(exc)
                # Nobody may be waiting on the future; reading the exception
                # here keeps asyncio from logging it as never retrieved.
                fut.exception()
            raise
        else:
            await self.set(key, value, ttl=ttl(value) if callable(ttl) else ttl)
            if not fut.done():
                fut.set_result(value)
            return value
        finally:
            self._inflight.pop(key, None)

    async def keys(self) -> List[str]:
        async with self._lock:
            return list(self._store.keys())


class StationRegistry:
    """Tracks which stations clients have asked about recently.

    The scheduler batch-refreshes exactly this set, so cost scales with the number
    of *watched stations*, not the number of users. Stations expire out of the
    registry after `ttl` seconds of no requests (default 24h per the brief).
    """

    def __init__(self, *, ttl: float = 24 * 3600.0, cap: int = 2000, clock=time.monotonic) -> None:
        self._seen: Dict[str, float] = {}
        self._ttl = ttl
        # Hard ceiling on what the scheduler will refresh. Without it one
        # client could hand the scheduler a day of work on junk ids.
        self._cap = cap
        self._clock = clock
        self._lock = asyncio.Lock()

    async def touch(self, station: str) -> None:
        async with self._lock:
            self._seen[station.upper()] = self._clock()
            if len(self._seen) > self._cap:
                oldest = min(self._seen, key=self._seen.get)
                del self._seen[oldest]

    def restore(self, stations: List[str]) -> None:
        """Seed the registry (after a restart) as if each station had just
        been asked for. Sync on purpose: called from a constructor."""
        now = self._clock()
        for s in stations:
            if isinstance(s, str) and s:
                self._seen.setdefault(s.upper(), now)

    async def active(self) -> List[str]:
        now = self._clock()
        async with self._lock:
            # prune expired entries while we're here
            self._seen = {
                s: ts for s, ts in self._seen.items() if now - ts <= self._ttl
            }
            return sorted(self._seen.keys())
