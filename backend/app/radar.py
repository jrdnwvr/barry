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


def _ltg_lut() -> np.ndarray:
    """Chance of lightning in the next hour (code = percent) -> violet,
    deeper with the chance; nothing under 10 percent."""
    lut = np.zeros((256, 4), dtype=np.uint8)
    for p in range(10, 101):
        a = 0.18 if p < 30 else 0.30 if p < 50 else 0.42 if p < 70 else 0.55
        lut[p] = [140, 77, 242, int(round(a * 255))]
    return lut


LUT_LTG = _ltg_lut()


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
    def __init__(self, root: Optional[Path], subdir: str = "radar", lut: Optional[np.ndarray] = None) -> None:
        self.root = Path(root) / subdir if root else None
        self.lut = LUT if lut is None else lut
        self.grid: Optional[dict] = None
        self._frames: Dict[int, List[np.ndarray]] = {}
        self._tiles: "OrderedDict[tuple, bytes]" = OrderedDict()
        self._tile_bytes = 0
        self._lock = threading.Lock()
        if self.root is not None:
            self.root.mkdir(parents=True, exist_ok=True)
            self._load()

    @classmethod
    def from_env(cls, subdir: str = "radar", lut: Optional[np.ndarray] = None) -> "RadarStore":
        d = os.environ.get("BARRY_DATA_DIR")
        return cls(Path(d) if d else None, subdir, lut)

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

    # Nowcast frames are stored under their base frame's time plus 1, 2 or
    # 3 (seconds), which no ten-minute mark can be: the tile URL then names
    # the run that made them, so a newer nowcast for the same valid time
    # never reuses a URL Cloudflare already holds.
    STEP_S = 600

    def observed(self) -> List[int]:
        return [t for t in self.times() if t % self.STEP_S == 0]

    def casts(self, base: int) -> List[int]:
        return [base + k for k in (1, 2, 3) if (base + k) in self._frames]

    def drop_casts_before(self, base: int) -> None:
        with self._lock:
            old = [t for t in self._frames if t % self.STEP_S and t - t % self.STEP_S < base]
        if old:
            self._drop(old)

    def _drop(self, keys) -> None:
        with self._lock:
            for t in keys:
                self._frames.pop(t, None)
                if self.root is not None:
                    for i in range(LEVELS):
                        try:
                            (self.root / f"{t}.l{i}.npy").unlink()
                        except OSError:
                            pass
            for k in [k for k in self._tiles if k[0] in set(keys)]:
                self._tile_bytes -= len(self._tiles.pop(k))

    def level(self, t: int, i: int) -> Optional[np.ndarray]:
        f = self._frames.get(t)
        return f[i] if f is not None else None

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
        self._drop([t for t in list(self._frames) if t < before])

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
        png = render(levels, grid, z, x, y, size, self.lut)
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


def render(levels: List[np.ndarray], grid: dict, z: int, x: int, y: int, size: int,
           lut: Optional[np.ndarray] = None) -> bytes:
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
    return png_rgba((LUT if lut is None else lut)[codes])


# ---- the next half hour ----------------------------------------------------------

# Motion is found on the copy pooled twice (0.04 degree): blocks of 12
# points (about 50 km), shifts of up to 5 points (20 km) between frames ten
# minutes apart, so up to about 130 km/h. Blocks with little echo take the
# motion of their neighbours; with none near, the echo stays put.
MOTION_LEVEL = 2
BLOCK = 12
SEARCH = 5
ECHO_CODE = int((15 + 32) * 2)        # 15 dBZ: below it, not worth tracking
SMOOTH_PASSES = 3


def _box(a: np.ndarray, r: int = 2) -> np.ndarray:
    """Sum over a (2r+1)^2 neighbourhood, edges padded with zeros."""
    p = np.pad(a, r)
    c = p.cumsum(0).cumsum(1)
    c = np.pad(c, ((1, 0), (1, 0)))
    n = 2 * r + 1
    return c[n:, n:] - c[:-n, n:] - c[n:, :-n] + c[:-n, :-n]


def motion(prev: np.ndarray, cur: np.ndarray):
    """Per-block displacement (rows, cols, in pooled points per step) that
    carries `prev` onto `cur`, by the smallest sum of absolute differences,
    then filled and smoothed. Returns (vy, vx, has_echo) on the block grid."""
    a = np.where(prev >= ECHO_CODE, prev, 0).astype(np.int16)
    b = np.where(cur >= ECHO_CODE, cur, 0).astype(np.int16)
    h, w = b.shape
    nby, nbx = h // BLOCK, w // BLOCK
    a, b = a[:nby * BLOCK, :nbx * BLOCK], b[:nby * BLOCK, :nbx * BLOCK]
    best = np.full((nby, nbx), np.iinfo(np.int64).max, dtype=np.int64)
    vy = np.zeros((nby, nbx), dtype=np.float32)
    vx = np.zeros((nby, nbx), dtype=np.float32)
    zero_cost = None
    for dy in range(-SEARCH, SEARCH + 1):
        for dx in range(-SEARCH, SEARCH + 1):
            shifted = np.zeros_like(a)
            ys, yd = (slice(0, a.shape[0] - dy), slice(dy, None)) if dy >= 0 else (slice(-dy, None), slice(0, a.shape[0] + dy))
            xs, xd = (slice(0, a.shape[1] - dx), slice(dx, None)) if dx >= 0 else (slice(-dx, None), slice(0, a.shape[1] + dx))
            shifted[yd, xd] = a[ys, xs]
            cost = np.abs(b - shifted).reshape(nby, BLOCK, nbx, BLOCK).sum(axis=(1, 3), dtype=np.int64)
            if dy == 0 and dx == 0:
                zero_cost = cost
            better = cost < best
            best[better] = cost[better]
            vy[better], vx[better] = dy, dx
    echo = (b >= ECHO_CODE).reshape(nby, BLOCK, nbx, BLOCK).sum(axis=(1, 3))
    # A block counts when it has echo and moving it helps.
    ok = (echo >= BLOCK * BLOCK // 8) & (best < zero_cost)
    wgt = ok.astype(np.float32)
    ny, nx = vy * wgt, vx * wgt
    for _ in range(SMOOTH_PASSES):
        s = _box(wgt)
        sy, sx = _box(ny), _box(nx)
        filled = s > 0
        ny = np.where(filled, sy / np.maximum(s, 1e-6), 0.0).astype(np.float32)
        nx = np.where(filled, sx / np.maximum(s, 1e-6), 0.0).astype(np.float32)
        wgt = np.where(filled, 1.0, 0.0).astype(np.float32)
    return ny, nx, echo > 0


def advect(cur: np.ndarray, vy: np.ndarray, vx: np.ndarray, steps: float, chunk: int = 400) -> np.ndarray:
    """`cur` (full resolution) carried `steps` motion steps forward: each
    point takes the value from where the motion says it came from. The
    block-grid motion is spread bilinearly over the full grid, a band of
    rows at a time so memory stays small."""
    h, w = cur.shape
    scale = BLOCK * 2 ** MOTION_LEVEL                 # full-resolution points per block
    per = 2 ** MOTION_LEVEL                           # full-resolution points per pooled point
    nby, nbx = vy.shape
    out = np.zeros_like(cur)
    cols = np.arange(w)
    fx = np.clip((cols + 0.5) / scale - 0.5, 0, nbx - 1)
    x0 = np.floor(fx).astype(int)
    x1 = np.minimum(x0 + 1, nbx - 1)
    tx = (fx - x0).astype(np.float32)
    for r0 in range(0, h, chunk):
        rows = np.arange(r0, min(h, r0 + chunk))
        fy = np.clip((rows + 0.5) / scale - 0.5, 0, nby - 1)
        y0 = np.floor(fy).astype(int)
        y1 = np.minimum(y0 + 1, nby - 1)
        ty = (fy - y0).astype(np.float32)[:, None]

        def bil(v):
            top = v[y0][:, x0] * (1 - tx) + v[y0][:, x1] * tx
            bot = v[y1][:, x0] * (1 - tx) + v[y1][:, x1] * tx
            return top * (1 - ty) + bot * ty

        dy = bil(vy) * per * steps
        dx = bil(vx) * per * steps
        src_r = np.rint(rows[:, None] - dy).astype(np.int64)
        src_c = np.rint(cols[None, :] - dx).astype(np.int64)
        inside = (src_r >= 0) & (src_r < h) & (src_c >= 0) & (src_c < w)
        band = np.zeros((len(rows), w), dtype=cur.dtype)
        band[inside] = cur[src_r[inside], src_c[inside]]
        out[r0:r0 + len(rows)] = band
    return out


def pooled(codes: np.ndarray, level: int) -> np.ndarray:
    a = codes
    for _ in range(level):
        a = pool(a)
    return a
