"""Decoded model fields on disk, for the NOAA feeds.

    <root>/<feed>/<YYYYMMDDHH>/f<FF>/<field>.npy     float32, rows south to north
    <root>/<feed>/<YYYYMMDDHH>/manifest.json         grid, hours and fields held, complete or not

A field is written once and read through a memory map, so the page cache
does the memory management and a restart costs nothing: the manifest says
what is complete and the files are still there. The map fields are
float32, because sea-level pressure in hPa needs a tenth and float16
steps by a whole hPa above 1,024 (an HRRR field is 7.6 MB); the column
feeds keep every other point in float16 (0.95 MB), which is plenty for
temperatures in Celsius, heights and winds at a point.

With no root (tests, or no data directory), fields live in memory only.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np

log = logging.getLogger("barry.modelstore")


def _cycle_name(cycle: datetime) -> str:
    """YYYYMMDDHH, with the minutes added for products that run every
    quarter hour (the turbulence nowcast)."""
    return cycle.strftime("%Y%m%d%H%M" if cycle.minute else "%Y%m%d%H")


def _parse_cycle(name: str) -> Optional[datetime]:
    for fmt in ("%Y%m%d%H", "%Y%m%d%H%M"):
        try:
            if len(name) == len(datetime(2000, 1, 1).strftime(fmt)):
                return datetime.strptime(name, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


class ModelStore:
    def __init__(self, root: Optional[Path]) -> None:
        self.root = Path(root) if root else None
        self._mem: Dict[Tuple[str, str, int, str], np.ndarray] = {}
        self._manifests: Dict[Tuple[str, str], dict] = {}
        self._lock = threading.Lock()
        if self.root is not None:
            self.root.mkdir(parents=True, exist_ok=True)
            self._load_manifests()

    @classmethod
    def from_env(cls) -> "ModelStore":
        d = os.environ.get("BARRY_DATA_DIR")
        return cls(Path(d) / "model" if d else None)

    # ---- manifests ----

    def _load_manifests(self) -> None:
        for feed_dir in self.root.iterdir():
            if not feed_dir.is_dir():
                continue
            for cyc_dir in feed_dir.iterdir():
                m = cyc_dir / "manifest.json"
                if m.exists():
                    try:
                        self._manifests[(feed_dir.name, cyc_dir.name)] = json.loads(m.read_text())
                    except (OSError, ValueError):
                        continue

    def _manifest(self, feed: str, cycle: datetime) -> dict:
        key = (feed, _cycle_name(cycle))
        m = self._manifests.get(key)
        if m is None:
            m = {"cycle": cycle.isoformat(), "hours": {}, "complete": False, "grid": None}
            self._manifests[key] = m
        return m

    def _write_manifest(self, feed: str, cycle: datetime) -> None:
        if self.root is None:
            return
        d = self.root / feed / _cycle_name(cycle)
        d.mkdir(parents=True, exist_ok=True)
        tmp = d / "manifest.json.tmp"
        tmp.write_text(json.dumps(self._manifest(feed, cycle)))
        tmp.replace(d / "manifest.json")

    def drop(self, feed: str) -> None:
        """Forget a feed entirely, files and all (a retired format)."""
        with self._lock:
            for key in [k for k in self._manifests if k[0] == feed]:
                self._manifests.pop(key, None)
            for key in [k for k in self._mem if k[0] == feed]:
                self._mem.pop(key, None)
            if self.root is not None:
                shutil.rmtree(self.root / feed, ignore_errors=True)

    # ---- writing ----

    def put(self, feed: str, cycle: datetime, fhr: int, name: str, arr: np.ndarray,
            grid: Optional[dict] = None) -> None:
        """Float16 arrays stay float16 (the column feeds); anything else is
        stored as float32."""
        arr = np.ascontiguousarray(arr, dtype=np.float16 if arr.dtype == np.float16 else np.float32)
        # A packed hour holds every field; the manifest lists the names.
        with self._lock:
            m = self._manifest(feed, cycle)
            if grid is not None:
                m["grid"] = grid
            names = m["hours"].setdefault(str(fhr), [])
            if name not in names:
                names.append(name)
            if self.root is None:
                self._mem[(feed, _cycle_name(cycle), fhr, name)] = arr
                return
            d = self.root / feed / _cycle_name(cycle) / f"f{fhr:02d}"
            d.mkdir(parents=True, exist_ok=True)
            tmp = d / f"{name}.tmp.npy"
            np.save(tmp, arr)
            tmp.replace(d / f"{name}.npy")
            self._mem.pop((feed, _cycle_name(cycle), fhr, name), None)

    def mark_complete(self, feed: str, cycle: datetime) -> None:
        with self._lock:
            self._manifest(feed, cycle)["complete"] = True
            self._write_manifest(feed, cycle)

    def purge(self, feed: str, keep: int = 2) -> None:
        """Keep the newest `keep` complete cycles, and any incomplete cycle
        newer than them (it is being written)."""
        with self._lock:
            cycles = sorted((c for f, c in self._manifests if f == feed),
                            key=lambda c: _parse_cycle(c) or datetime.min.replace(tzinfo=timezone.utc),
                            reverse=True)
            complete = [c for c in cycles if self._manifests[(feed, c)].get("complete")]
            if len(complete) <= keep:
                return
            cutoff = _parse_cycle(complete[keep - 1])
            for c in cycles:
                if (_parse_cycle(c) or cutoff) < cutoff:
                    self._manifests.pop((feed, c), None)
                    for k in [k for k in self._mem if k[0] == feed and k[1] == c]:
                        self._mem.pop(k, None)
                    if self.root is not None:
                        shutil.rmtree(self.root / feed / c, ignore_errors=True)

    # ---- reading ----

    def cycles(self, feed: str, complete_only: bool = True) -> List[datetime]:
        out = []
        for (f, c), m in self._manifests.items():
            if f == feed and (m.get("complete") or not complete_only):
                t = _parse_cycle(c)
                if t is not None:
                    out.append(t)
        return sorted(out, reverse=True)

    def has(self, feed: str, cycle: datetime) -> bool:
        m = self._manifests.get((feed, _cycle_name(cycle)))
        return bool(m and m.get("complete"))

    def grid(self, feed: str, cycle: datetime) -> Optional[dict]:
        m = self._manifests.get((feed, _cycle_name(cycle)))
        return m.get("grid") if m else None

    def hours(self, feed: str, cycle: datetime) -> Dict[int, List[str]]:
        m = self._manifests.get((feed, _cycle_name(cycle))) or {}
        return {int(k): v for k, v in (m.get("hours") or {}).items()}

    def load(self, feed: str, cycle: datetime, fhr: int, name: str) -> Optional[np.ndarray]:
        key = (feed, _cycle_name(cycle), fhr, name)
        arr = self._mem.get(key)
        if arr is not None or self.root is None:
            return arr
        path = self.root / feed / _cycle_name(cycle) / f"f{fhr:02d}" / f"{name}.npy"
        if not path.exists():
            return None
        try:
            arr = np.load(path, mmap_mode="r")
        except (OSError, ValueError):
            return None
        self._mem[key] = arr
        return arr

    def warm(self, feed: str, cycle: datetime) -> int:
        """Open every field of a cycle now, so the first request after a
        pull or a restart doesn't pay for thousands of opens (the Aloft
        column reads about 3,000 fields; opened cold that was 10 s)."""
        n = 0
        for fhr, names in self.hours(feed, cycle).items():
            for name in names:
                if self.load(feed, cycle, fhr, name) is not None:
                    n += 1
        return n

    def nearest(self, feed: str, name: str, valid: datetime,
                within: timedelta = timedelta(minutes=45)
                ) -> Optional[Tuple[np.ndarray, datetime, int]]:
        """The field from the newest complete cycle whose forecast hour is
        valid nearest `valid`, if one is within `within`."""
        for cycle in self.cycles(feed):
            best = None
            for fhr, names in self.hours(feed, cycle).items():
                if name not in names:
                    continue
                d = abs((cycle + timedelta(hours=fhr) - valid).total_seconds())
                if d <= within.total_seconds() and (best is None or d < best[0]):
                    best = (d, fhr)
            if best is not None:
                arr = self.load(feed, cycle, best[1], name)
                if arr is not None:
                    return arr, cycle, best[1]
        return None
