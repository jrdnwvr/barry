"""What the box counts about itself, for /metrics.

Plain dictionaries under a lock, rendered in the Prometheus text format so
anything can scrape them. Nothing here is exported anywhere on its own;
the endpoint answers only on the box's own network. No label ever carries
a coordinate or a client address: routes are templates, hosts are the
upstream's, the rest is numbers.
"""

from __future__ import annotations

import os
import resource
import sys
import threading
from typing import Dict, Tuple

_lock = threading.Lock()
_counters: Dict[str, Dict[Tuple[str, ...], float]] = {}
_gauges: Dict[str, float] = {}

LABELS = {
    "barry_requests_total": ("route", "status"),
    "barry_upstream_requests_total": ("host",),
    "barry_upstream_responses_total": ("host", "status"),
    "barry_cache_total": ("outcome",),
}
HELP = {
    "barry_requests_total": "requests answered, by route template and status",
    "barry_upstream_requests_total": "requests sent upstream, by host",
    "barry_upstream_responses_total": "responses that came back, by host and status class",
    "barry_cache_total": "cache reads by outcome: hit, miss, joined (waited on a fetch in flight), negative",
    "barry_scheduler_cycles_total": "refresh cycles completed",
    "barry_scheduler_cycle_seconds": "how long the last refresh cycle took",
    "barry_registry_size": "stations the scheduler is refreshing",
    "barry_glm_flashes": "lightning flashes in the twenty minute window",
    "barry_rss_bytes": "resident memory of the process",
    "barry_cache_entries": "entries in the TTL cache",
}


def inc(name: str, *labels: str, by: float = 1.0) -> None:
    with _lock:
        _counters.setdefault(name, {})
        _counters[name][labels] = _counters[name].get(labels, 0.0) + by


def gauge(name: str, value: float) -> None:
    with _lock:
        _gauges[name] = float(value)


def status_class(code: int) -> str:
    return f"{code // 100}xx"


def rss_bytes() -> float:
    try:
        with open("/proc/self/statm") as f:
            return float(f.read().split()[1]) * os.sysconf("SC_PAGE_SIZE")
    except (OSError, ValueError, IndexError):
        pass
    ru = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return float(ru if sys.platform == "darwin" else ru * 1024)


def _fmt(v: float) -> str:
    return str(int(v)) if v == int(v) else repr(v)


def render() -> str:
    gauge("barry_rss_bytes", rss_bytes())
    lines = []
    with _lock:
        for name, series in sorted(_counters.items()):
            lines.append(f"# HELP {name} {HELP.get(name, '')}")
            lines.append(f"# TYPE {name} counter")
            keys = LABELS.get(name, ())
            for labels, v in sorted(series.items()):
                lab = ",".join(f'{k}="{val}"' for k, val in zip(keys, labels))
                lines.append(f"{name}{{{lab}}} {_fmt(v)}" if lab else f"{name} {_fmt(v)}")
        for name, v in sorted(_gauges.items()):
            lines.append(f"# HELP {name} {HELP.get(name, '')}")
            lines.append(f"# TYPE {name} gauge")
            lines.append(f"{name} {_fmt(v)}")
    return "\n".join(lines) + "\n"


def reset() -> None:
    with _lock:
        _counters.clear()
        _gauges.clear()
