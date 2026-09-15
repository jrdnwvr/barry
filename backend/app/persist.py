"""Tiny on-disk persistence for the few things worth surviving a restart
(E6). Pickle files in BARRY_DATA_DIR (a mounted volume in Docker), written
atomically. Anything here is a cache: a missing or unreadable file just
means starting cold."""

from __future__ import annotations

import logging
import os
import pickle
import tempfile
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


def save(name: str, obj: Any) -> bool:
    d = data_dir()
    if d is None:
        return False
    target = d / f"{name}.pkl"
    try:
        fd, tmp = tempfile.mkstemp(dir=d, prefix=f".{name}.", suffix=".tmp")
        with os.fdopen(fd, "wb") as f:
            pickle.dump(obj, f, protocol=pickle.HIGHEST_PROTOCOL)
        os.replace(tmp, target)
        return True
    except Exception as exc:
        log.warning("persist: save %s failed: %s", name, exc)
        return False


def load(name: str) -> Any:
    d = data_dir()
    if d is None:
        return None
    target = d / f"{name}.pkl"
    if not target.exists():
        return None
    try:
        with open(target, "rb") as f:
            return pickle.load(f)
    except Exception as exc:
        log.warning("persist: load %s failed: %s", name, exc)
        return None
