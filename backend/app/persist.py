"""Tiny on-disk persistence for the few things worth surviving a restart
(E6). Gzipped JSON in BARRY_DATA_DIR (a mounted volume in Docker), written
atomically. Anything here is a cache: a missing or unreadable file just
means starting cold.

JSON, not pickle, on purpose: the directory is a bind mount, and unpickling
a file anyone on the host could write is code execution inside the container.
Datetimes travel as {"__dt__": iso}; tuples come back as lists, and the
callers that care re-tuple them. A leftover .pkl from the pickle days is read
once, rewritten as JSON, and deleted.
"""

from __future__ import annotations

import gzip
import json
import logging
import os
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

log = logging.getLogger(__name__)


def data_dir() -> Optional[Path]:
    raw = os.environ.get("BARRY_DATA_DIR")
    if not raw:
        return None
    p = Path(raw)
    try:
        p.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        log.warning("persist: cannot use %s: %s", p, exc)
        return None
    return p


def _encode(o: Any) -> Any:
    if isinstance(o, datetime):
        return {"__dt__": o.isoformat()}
    raise TypeError(f"persist: cannot store {type(o).__name__}")


def _decode(d: dict) -> Any:
    if "__dt__" in d and len(d) == 1:
        return datetime.fromisoformat(d["__dt__"])
    return d


def save(name: str, obj: Any) -> bool:
    d = data_dir()
    if d is None:
        return False
    target = d / f"{name}.json.gz"
    try:
        fd, tmp = tempfile.mkstemp(dir=d, prefix=f".{name}.", suffix=".tmp")
        with os.fdopen(fd, "wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb") as f:
            f.write(json.dumps(obj, default=_encode, separators=(",", ":")).encode())
        os.replace(tmp, target)
        return True
    except Exception as exc:
        log.warning("persist: save %s failed: %s", name, exc)
        return False


def load(name: str) -> Any:
    d = data_dir()
    if d is None:
        return None
    target = d / f"{name}.json.gz"
    if target.exists():
        try:
            with gzip.open(target, "rb") as f:
                return json.loads(f.read().decode(), object_hook=_decode)
        except Exception as exc:
            log.warning("persist: load %s failed: %s", name, exc)
            return None
    legacy = d / f"{name}.pkl"
    if legacy.exists():
        # One-time migration from our own earlier format. After this the
        # container never unpickles anything again.
        try:
            import pickle
            with open(legacy, "rb") as f:
                obj = pickle.load(f)
            if save(name, obj):
                legacy.unlink(missing_ok=True)
                log.warning("persist: migrated %s from pickle to json", name)
            return obj
        except Exception as exc:
            log.warning("persist: legacy load %s failed: %s", name, exc)
            return None
    return None
