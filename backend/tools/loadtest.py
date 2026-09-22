"""Hammer the expensive endpoints and watch the health check stay quick.

    python tools/loadtest.py [--base http://127.0.0.1:8099] [--seconds 30] [--workers 8]

Exit code 1 when /healthz p95 goes over 200 ms while the pressure grid is
being built at continental spans with a fresh key per request. Run it
against a local instance started with BARRY_RATE_PER_MIN=0, never against
production: the per-address budget would turn most of it into 429s.
Upstream cost of a run is one bulk METAR pull plus one station's data.
"""
from __future__ import annotations

import argparse
import asyncio
import random
import statistics
import sys
import time
from collections import Counter, defaultdict

import httpx

HEALTH_P95_LIMIT_MS = 200.0


def _pct(xs, p):
    if not xs:
        return float("nan")
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100.0 * (len(xs) - 1))))]


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8099")
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()

    deadline = time.monotonic() + args.seconds
    lat_ms = defaultdict(list)
    codes = defaultdict(Counter)
    rng = random.Random(1)

    def pick():
        r = rng.random()
        if r < 0.5:
            lat, lon = 25 + rng.randrange(0, 250) / 10, -125 + rng.randrange(0, 550) / 10
            return "/radar/pressure", {"lat": lat, "lon": lon, "latSpan": 30, "lonSpan": 60}
        if r < 0.8:
            return "/metars", {"lat": 25 + rng.randrange(0, 250) / 10, "lon": -125 + rng.randrange(0, 550) / 10,
                               "half": rng.choice([3, 10, 30])}
        if r < 0.9:
            return "/lightning", {"lat": 39.1, "lon": -84.4, "half": 6}
        return "/combined", {"station": "KLUK", "lat": 39.1, "lon": -84.4}

    async def worker(c: httpx.AsyncClient):
        while time.monotonic() < deadline:
            path, params = pick()
            t0 = time.perf_counter()
            try:
                r = await c.get(path, params=params)
                code = r.status_code
            except Exception as exc:
                code = type(exc).__name__
            lat_ms[path].append((time.perf_counter() - t0) * 1000)
            codes[path][code] += 1

    async def probe(c: httpx.AsyncClient):
        while time.monotonic() < deadline:
            t0 = time.perf_counter()
            try:
                r = await c.get("/healthz")
                code = r.status_code
            except Exception as exc:
                code = type(exc).__name__
            lat_ms["/healthz"].append((time.perf_counter() - t0) * 1000)
            codes["/healthz"][code] += 1
            await asyncio.sleep(0.2)

    async with httpx.AsyncClient(base_url=args.base, timeout=120.0) as c:
        try:
            (await c.get("/healthz")).raise_for_status()
        except Exception as exc:
            print(f"no server at {args.base}: {exc}")
            return 2
        await asyncio.gather(probe(c), *(worker(c) for _ in range(args.workers)))

    print(f"{'route':18} {'n':>5} {'p50 ms':>8} {'p95 ms':>8} {'max ms':>8}  codes")
    for path in sorted(lat_ms):
        xs = lat_ms[path]
        print(f"{path:18} {len(xs):5d} {_pct(xs, 50):8.0f} {_pct(xs, 95):8.0f} {max(xs):8.0f}  {dict(codes[path])}")
    p95 = _pct(lat_ms["/healthz"], 95)
    ok = p95 <= HEALTH_P95_LIMIT_MS and set(codes["/healthz"]) == {200}
    print(f"\nhealthz p95 {p95:.0f} ms, limit {HEALTH_P95_LIMIT_MS:.0f} ms: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
