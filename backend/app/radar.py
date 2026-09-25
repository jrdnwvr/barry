"""Barry's own radar tiles, from MRMS frames held on Tower.

Each frame is kept as uint8 dBZ codes (dBZ = code / 2 - 32) on the MRMS
grid, plus four coarser copies made by taking the strongest echo in each
2x2 block, so a continental view shows every storm instead of whichever
pixel the sampling lands on. A Web Mercator tile is one gather from the
right copy and a colour lookup; the PNG is written here with zlib, no
imaging library.

The colours are RainViewer's Universal Blue, the palette the app asks
RainViewer for and reads back to dBZ before painting in its own colours,
so the app draws Barry's tiles exactly as it drew RainViewer's without a
change. Tile URLs keep RainViewer's shape:

    /radar/tiles/<unix time>/512/<z>/<x>/<y>/2/0_1.png

and carry the frame's time, so they never change and Cloudflare's edge
can keep them; a small in-process cache covers the first viewers.
"""

from __future__ import annotations

import json
import logging
import math
import os
import struct
import threading
import zlib
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np

log = logging.getLogger("barry.radar")

LEVELS = 5                        # full resolution and four halvings
TILE_CACHE_BYTES = 64 << 20


def _lut() -> np.ndarray:
    """uint8 code -> RGBA, from RainViewer's published Universal Blue
    table (dBZ -10 to 95; below that, transparent)."""
    path = os.path.join(os.path.dirname(__file__), "data", "radar_universal_blue.json")
    with open(path, encoding="utf-8") as fh:
        table = {int(k): v for k, v in json.load(fh).items()}
    lut = np.zeros((256, 4), dtype=np.uint8)
    for code in range(1, 256):
        dbz = int(math.floor(code / 2.0 - 32.0 + 0.5))
        c = table.get(dbz)
        if c:
            lut[code] = [int(c[i:i + 2], 16) for i in (0, 2, 4, 6)]
    return lut


LUT = _lut()


def png_rgba(img: np.ndarray, level: int = 3) -> bytes:
    """A (h, w, 4) uint8 image as an RGBA PNG, no filtering (rows of
    nothing compress to almost nothing anyway)."""
    h, w, _ = img.shape
    raw = np.zeros((h, w * 4 + 1), dtype=np.uint8)
    raw[:, 1:] = img.reshape(h, w * 4)

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw.tobytes(), level))
            + chunk(b"IEND", b""))


_EMPTY: Dict[int, bytes] = {}


def empty_png(size: int) -> bytes:
    if size not in _EMPTY:
        _EMPTY[size] = png_rgba(np.zeros((size, size, 4), dtype=np.uint8), level=9)
    return _EMPTY[size]


def pool(a: np.ndarray) -> np.ndarray:
    """The strongest code in each 2x2 block."""
    h, w = a.shape
    if h % 2 or w % 2:
        a = np.pad(a, ((0, h % 2), (0, w % 2)))
    return a.reshape(a.shape[0] // 2, 2, a.shape[1] // 2, 2).max(axis=(1, 3))


class RadarStore:
    def __init__(self, root: Optional[Path]) -> None:
        self.root = Path(root) / "radar" if root else None
        self.grid: Optional[dict] = None
        self._frames: Dict[int, List[np.ndarray]] = {}
        self._tiles: "OrderedDict[tuple, bytes]" = OrderedDict()
        self._tile_bytes = 0
        self._lock = threading.Lock()
        if self.root is not None:
            self.root.mkdir(parents=True, exist_ok=True)
            self._load()

    @classmethod
    def from_env(cls) -> "RadarStore":
        d = os.environ.get("BARRY_DATA_DIR")
        return cls(Path(d) if d else None)

    def _load(self) -> None:
        g = self.root / "grid.json"
        if g.exists():
            try:
                self.grid = json.loads(g.read_text())
            except (OSError, ValueError):
                self.grid = None
        for f in self.root.glob("*.l0.npy"):
            try:
                t = int(f.name.split(".")[0])
                levels = [np.load(self.root / f"{t}.l{i}.npy", mmap_mode="r") for i in range(LEVELS)]
            except (OSError, ValueError):
                continue
            self._frames[t] = levels

    def times(self) -> List[int]:
        return sorted(self._frames)

    def has(self, t: int) -> bool:
        return t in self._frames

    def put(self, t: int, codes: np.ndarray, grid: dict) -> None:
        levels = [np.ascontiguousarray(codes, dtype=np.uint8)]
        for _ in range(LEVELS - 1):
            levels.append(pool(levels[-1]))
        if self.root is not None:
            for i, a in enumerate(levels):
                tmp = self.root / f"{t}.l{i}.tmp.npy"
                np.save(tmp, a)
                tmp.replace(self.root / f"{t}.l{i}.npy")
            (self.root / "grid.json").write_text(json.dumps(grid))
            levels = [np.load(self.root / f"{t}.l{i}.npy", mmap_mode="r") for i in range(LEVELS)]
        with self._lock:
            self.grid = grid
            self._frames[t] = levels

    def purge(self, before: int) -> None:
        with self._lock:
            for t in [t for t in self._frames if t < before]:
                self._frames.pop(t, None)
                if self.root is not None:
                    for i in range(LEVELS):
                        try:
                            (self.root / f"{t}.l{i}.npy").unlink()
                        except OSError:
                            pass
            for k in [k for k in self._tiles if k[0] < before]:
                self._tile_bytes -= len(self._tiles.pop(k))

    def tile(self, t: int, z: int, x: int, y: int, size: int = 512) -> Optional[bytes]:
        """The PNG for one tile of one frame, None when the frame is not held."""
        key = (t, z, x, y, size)
        with self._lock:
            hit = self._tiles.get(key)
            if hit is not None:
                self._tiles.move_to_end(key)
                return hit
            levels = self._frames.get(t)
            grid = self.grid
        if levels is None or grid is None:
            return None
        png = render(levels, grid, z, x, y, size)
        with self._lock:
            self._tiles[key] = png
            self._tile_bytes += len(png)
            while self._tile_bytes > TILE_CACHE_BYTES and self._tiles:
                _, old = self._tiles.popitem(last=False)
                self._tile_bytes -= len(old)
        return png

    def sample(self, t: int, lat: float, lon: float) -> Optional[float]:
        """dBZ at a point in a frame, None where there is no echo."""
        levels, g = self._frames.get(t), self.grid
        if levels is None or g is None:
            return None
        r = int(math.floor((g["lat0"] + g["dlat"] / 2 - lat) / g["dlat"]))
        c = int(math.floor((lon - (g["lon0"] - g["dlon"] / 2)) / g["dlon"]))
        a = levels[0]
        if not (0 <= r < a.shape[0] and 0 <= c < a.shape[1]):
            return None
        code = int(a[r, c])
        return code / 2.0 - 32.0 if code else None


def render(levels: List[np.ndarray], grid: dict, z: int, x: int, y: int, size: int) -> bytes:
    n = 2 ** z
    px_deg = 360.0 / (n * size)
    lvl = 0
    while lvl < len(levels) - 1 and grid["dlon"] * 2 ** (lvl + 1) <= px_deg:
        lvl += 1
    arr = levels[lvl]
    step = 2 ** lvl
    dlat, dlon = grid["dlat"] * step, grid["dlon"] * step
    top = grid["lat0"] + grid["dlat"] / 2           # the grid's north edge
    west = grid["lon0"] - grid["dlon"] / 2          # and west edge
    k = (np.arange(size) + 0.5) / size
    lon = (x + k) / n * 360.0 - 180.0
    lat = np.degrees(np.arctan(np.sinh(np.pi * (1 - 2 * (y + k) / n))))
    col = np.floor((lon - west) / dlon).astype(np.int64)
    row = np.floor((top - lat) / dlat).astype(np.int64)
    rok = (row >= 0) & (row < arr.shape[0])
    cok = (col >= 0) & (col < arr.shape[1])
    if not rok.any() or not cok.any():
        return empty_png(size)
    codes = np.zeros((size, size), dtype=np.uint8)
    codes[np.ix_(rok, cok)] = arr[np.ix_(row[rok], col[cok])]
    if not codes.any():
        return empty_png(size)
    return png_rgba(LUT[codes])
