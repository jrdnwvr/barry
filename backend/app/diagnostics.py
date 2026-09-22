"""MetricKit payloads from the app, kept as files.

The phone sends what MetricKit hands it once a day or so: launch times,
hang and crash diagnostics, battery and network totals. None of it carries
a location or an identifier. It is stored as it came, gzipped, newest
DIAG_KEEP files kept, and read by a person when something needs looking
into. No parsing beyond checking it is JSON, so a future payload shape
cannot break the endpoint.
"""

from __future__ import annotations

import gzip
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from uuid import uuid4

from . import persist

log = logging.getLogger("barry.diagnostics")

DIAG_MAX_BYTES = 1 << 20      # a diagnostic payload with call stacks is ~100-300 KB
DIAG_KEEP = 300               # files; a few weeks of one busy phone
KINDS = ("metric", "diagnostic")


def folder() -> Optional[Path]:
    d = persist.data_dir()
    if d is None:
        return None
    f = d / "diagnostics"
    f.mkdir(parents=True, exist_ok=True)
    return f


def store(kind: str, body: bytes) -> Optional[Path]:
    """Write one payload; returns the path, or None with no data dir."""
    f = folder()
    if f is None:
        return None
    kind = kind if kind in KINDS else "metric"
    name = f"{datetime.now(timezone.utc):%Y%m%dT%H%M%S}-{kind}-{uuid4().hex[:8]}.json.gz"
    path = f / name
    path.write_bytes(gzip.compress(body))
    prune(f)
    return path


def prune(f: Path, keep: int = DIAG_KEEP) -> int:
    files = sorted(f.glob("*.json.gz"))
    extra = files[: max(0, len(files) - keep)]
    for p in extra:
        try:
            p.unlink()
        except OSError:
            pass
    return len(extra)
