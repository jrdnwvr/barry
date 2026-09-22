"""Guards on the edge of the service: what a client may ask for, and how
often the service may ask an upstream on the client's behalf.

The project's rule is that no upstream cost may scale with the number of
users. Station ids and coordinates are the two client inputs that reach an
upstream, so they are validated and quantized here, and each upstream has a
token bucket that fails fast once the budget is spent. The scheduler's own
batched refresh does not go through these gates: it is bounded by the
registry cap instead.
"""

from __future__ import annotations

import re
import time

STATION_RE = re.compile(r"^[A-Za-z0-9]{3,4}$")


class InvalidStation(ValueError):
    """Not a station identifier. Routes turn this into a 422."""


class RateLimited(Exception):
    """The per-upstream budget is spent. Routes turn this into a 503."""


def check_station(station: str) -> str:
    """The canonical (upper-case) id, or InvalidStation."""
    if not isinstance(station, str) or not STATION_RE.match(station):
        raise InvalidStation(f"not a station id: {station!r}")
    return station.upper()


class RateGate:
    """A token bucket: `per_minute` tokens, refilled continuously, capacity
    equal to one minute's worth. `take()` returns False when empty rather
    than waiting, because a queued upstream call still costs the quota."""

    def __init__(self, per_minute: float, *, clock=time.monotonic) -> None:
        self.capacity = float(per_minute)
        self.refill_per_sec = float(per_minute) / 60.0
        self._tokens = self.capacity
        self._clock = clock
        self._last = clock()

    def _refill(self) -> None:
        now = self._clock()
        self._tokens = min(self.capacity, self._tokens + (now - self._last) * self.refill_per_sec)
        self._last = now

    def take(self, n: float = 1.0) -> bool:
        self._refill()
        if self._tokens >= n:
            self._tokens -= n
            return True
        return False

    def require(self, n: float = 1.0) -> None:
        if not self.take(n):
            raise RateLimited()


class IPLimiter:
    """One token bucket per client address, bounded in number so a scan of
    addresses cannot grow memory. `per_minute` of 0 disables the limiter."""

    def __init__(self, per_minute: float = 60, *, max_keys: int = 10_000, clock=time.monotonic) -> None:
        self.per_minute = float(per_minute)
        self.max_keys = max_keys
        self._clock = clock
        self._buckets: dict[str, RateGate] = {}

    def allow(self, key: str) -> bool:
        if self.per_minute <= 0:
            return True
        gate = self._buckets.get(key)
        if gate is None:
            if len(self._buckets) >= self.max_keys:
                # Drop the bucket that has gone longest without a request.
                oldest = min(self._buckets, key=lambda k: self._buckets[k]._last)
                del self._buckets[oldest]
            gate = RateGate(self.per_minute, clock=self._clock)
            self._buckets[key] = gate
        return gate.take()


def client_key(peer: str | None, cf_connecting_ip: str | None) -> str:
    """Which address a request counts against. Through the tunnel the peer is
    the cloudflared container and the real address is in CF-Connecting-IP;
    that header is trusted only when the peer is a private address, which is
    the only place the tunnel can be."""
    if cf_connecting_ip and peer and _is_private(peer):
        return cf_connecting_ip.strip()
    return peer or "unknown"


def _is_private(ip: str) -> bool:
    try:
        import ipaddress
        a = ipaddress.ip_address(ip)
        return a.is_private or a.is_loopback
    except ValueError:
        return False


is_private = _is_private
