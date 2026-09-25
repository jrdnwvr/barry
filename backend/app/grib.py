"""GRIB2 for the NOAA model feeds: index files, byte ranges, decoding, and
the Lambert conformal grid HRRR, RRFS and NBM share the shape of.

Every NOAA GRIB file has a `.idx` sidecar, one line per message:

    77:52346734:d=2026092415:UGRD:10 m above ground:1 hour fcst:

(number, byte offset, run, name, level, forecast). One HTTP range request
from a message's offset to the next one's pulls that field alone, so a
400 MB file costs the three or four MB actually used. Match on name and
level, never the number, which shifts between forecast hours.

Decoding is eccodes (the wheel bundles the library with JPEG2000 and PNG).
Values come back as float32 with missing points as NaN, rows south to
north as HRRR scans them.

The projection is done here in numpy rather than with pyproj: forward and
inverse Lambert conformal conic on a sphere, which is what the NCEP grids
declare (shape of the earth 6, radius 6,371,229 m).
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

import numpy as np

EARTH_RADIUS_M = 6371229.0


# ---- index files ------------------------------------------------------------

@dataclass(frozen=True)
class IdxEntry:
    n: int
    offset: int
    name: str
    level: str
    fcst: str
    extra: str = ""       # what follows: "prob >0.254:prob fcst 255/255", "ens std dev"


def parse_idx(text: str) -> List[IdxEntry]:
    out: List[IdxEntry] = []
    for line in text.splitlines():
        parts = line.split(":")
        if len(parts) < 6:
            continue
        try:
            out.append(IdxEntry(int(parts[0]), int(parts[1]), parts[3], parts[4], parts[5],
                                ":".join(p for p in parts[6:] if p)))
        except ValueError:
            continue
    out.sort(key=lambda e: e.offset)
    return out


def range_of(entries: Sequence[IdxEntry], match) -> Optional[Tuple[int, Optional[int]]]:
    """Byte range of the first message `match(entry)` accepts."""
    for i, e in enumerate(entries):
        if match(e):
            return e.offset, (entries[i + 1].offset - 1 if i + 1 < len(entries) else None)
    return None


def byte_ranges(entries: Sequence[IdxEntry], wanted: Iterable[Tuple[str, str]]
                ) -> Dict[Tuple[str, str], Tuple[int, Optional[int]]]:
    """(name, level) -> (first byte, last byte or None for the file's end).
    The first message with that name and level wins; later ones at the same
    level are the averaged or accumulated variants."""
    want = set(wanted)
    out: Dict[Tuple[str, str], Tuple[int, Optional[int]]] = {}
    for i, e in enumerate(entries):
        key = (e.name, e.level)
        # Probability and spread messages share a name and level with the
        # plain field; the plain one is what a (name, level) asks for.
        if e.extra:
            continue
        if key in want and key not in out:
            end = entries[i + 1].offset - 1 if i + 1 < len(entries) else None
            out[key] = (e.offset, end)
    return out


def merge_ranges(ranges: Iterable[Tuple[int, Optional[int]]], gap: int = 0
                 ) -> List[Tuple[int, Optional[int]]]:
    """Adjacent ranges joined, so fields that sit next to each other in the
    file come down in one request."""
    rs = sorted(ranges, key=lambda r: r[0])
    out: List[Tuple[int, Optional[int]]] = []
    for s, e in rs:
        if out and out[-1][1] is not None and s <= out[-1][1] + 1 + gap:
            ps, pe = out[-1]
            out[-1] = (ps, None if e is None else max(pe, e))
        else:
            out.append((s, e))
    return out


# ---- decoding ---------------------------------------------------------------

@dataclass
class Message:
    values: np.ndarray          # float32 (ny, nx), NaN where missing
    meta: Dict[str, object]


_META_KEYS = {
    "gridType": str, "Nx": int, "Ny": int, "shortName": str, "typeOfLevel": str,
    "level": int, "dataDate": int, "dataTime": int, "forecastTime": int,
    "validityDate": int, "validityTime": int, "discipline": int,
    "parameterCategory": int, "parameterNumber": int,
}
_LAMBERT_KEYS = {
    "latitudeOfFirstGridPointInDegrees": float, "longitudeOfFirstGridPointInDegrees": float,
    "LoVInDegrees": float, "Latin1InDegrees": float, "Latin2InDegrees": float,
    "DxInMetres": float, "DyInMetres": float, "resolutionAndComponentFlags": int,
    "jScansPositively": int, "iScansNegatively": int,
}


def decode(msg: bytes) -> Message:
    import eccodes
    h = eccodes.codes_new_from_message(msg)
    try:
        meta: Dict[str, object] = {}
        for k, t in _META_KEYS.items():
            try:
                meta[k] = t(eccodes.codes_get(h, k))
            except Exception:
                meta[k] = None
        if meta.get("gridType") == "lambert":
            for k, t in _LAMBERT_KEYS.items():
                try:
                    meta[k] = t(eccodes.codes_get(h, k))
                except Exception:
                    meta[k] = None
        vals = eccodes.codes_get_values(h).astype(np.float32)
        miss = eccodes.codes_get(h, "missingValue")
        try:
            has_bitmap = eccodes.codes_get(h, "bitmapPresent") == 1
        except Exception:
            has_bitmap = False
        if has_bitmap:
            vals[vals == np.float32(miss)] = np.nan
        ny, nx = int(meta["Ny"]), int(meta["Nx"])
        return Message(values=vals.reshape(ny, nx), meta=meta)
    finally:
        eccodes.codes_release(h)


def split_messages(data: bytes) -> List[bytes]:
    """A buffer holding one or more whole GRIB messages, split by their own
    length fields (section 0: 'GRIB', edition 2, 8-byte total length)."""
    out: List[bytes] = []
    i = 0
    while True:
        i = data.find(b"GRIB", i)
        if i < 0 or i + 16 > len(data):
            break
        length = int.from_bytes(data[i + 8:i + 16], "big")
        if length <= 16 or i + length > len(data):
            break
        out.append(data[i:i + length])
        i += length
    return out


# ---- the Lambert grid -------------------------------------------------------

class LambertGrid:
    """Lambert conformal conic on a sphere, as NCEP defines it: the first
    grid point, the orientation longitude LoV, the two standard parallels
    (HRRR's are equal, 38.5), and the spacing. Index (i, j) counts columns
    east and rows north from the first point."""

    def __init__(self, nx: int, ny: int, lat1: float, lon1: float, lov: float,
                 latin1: float, latin2: float, dx: float, dy: float,
                 radius: float = EARTH_RADIUS_M) -> None:
        self.nx, self.ny = nx, ny
        self.dx, self.dy = dx, dy
        self.lov = lov
        self.radius = radius
        p1, p2 = math.radians(latin1), math.radians(latin2)
        if abs(latin1 - latin2) < 1e-9:
            n = math.sin(p1)
        else:
            n = (math.log(math.cos(p1) / math.cos(p2))
                 / math.log(math.tan(math.pi / 4 + p2 / 2) / math.tan(math.pi / 4 + p1 / 2)))
        self.n = n
        self.F = math.cos(p1) * math.tan(math.pi / 4 + p1 / 2) ** n / n
        # The reference latitude NCEP uses for the cone is LaD, equal to
        # Latin1 on every grid Barry reads.
        self.rho0 = radius * self.F / math.tan(math.pi / 4 + p1 / 2) ** n
        self.x1, self.y1 = self._xy(np.float64(lat1), np.float64(lon1))

    @classmethod
    def from_meta(cls, m: Dict[str, object]) -> "LambertGrid":
        return cls(int(m["Nx"]), int(m["Ny"]),
                   float(m["latitudeOfFirstGridPointInDegrees"]),
                   float(m["longitudeOfFirstGridPointInDegrees"]),
                   float(m["LoVInDegrees"]), float(m["Latin1InDegrees"]),
                   float(m["Latin2InDegrees"]), float(m["DxInMetres"]), float(m["DyInMetres"]))

    def key(self) -> Tuple:
        return (self.nx, self.ny, round(self.x1, 1), round(self.y1, 1), self.lov, round(self.n, 9), self.dx, self.dy)

    def _dlon(self, lon):
        d = (np.asarray(lon, dtype=np.float64) - self.lov + 180.0) % 360.0 - 180.0
        return np.radians(d)

    def _xy(self, lat, lon):
        lat = np.asarray(lat, dtype=np.float64)
        rho = self.radius * self.F / np.tan(np.pi / 4 + np.radians(lat) / 2) ** self.n
        theta = self.n * self._dlon(lon)
        return rho * np.sin(theta), self.rho0 - rho * np.cos(theta)

    def ij(self, lat, lon):
        """Fractional (column, row) of each point."""
        x, y = self._xy(lat, lon)
        return (x - self.x1) / self.dx, (y - self.y1) / self.dy

    def latlon(self, i, j):
        x = self.x1 + np.asarray(i, dtype=np.float64) * self.dx
        y = self.y1 + np.asarray(j, dtype=np.float64) * self.dy
        dy = self.rho0 - y
        rho = np.sign(self.n) * np.sqrt(x * x + dy * dy)
        theta = np.arctan2(np.sign(self.n) * x, np.sign(self.n) * dy)
        lon = self.lov + np.degrees(theta / self.n)
        lat = np.degrees(2 * np.arctan((self.radius * self.F / rho) ** (1 / self.n)) - np.pi / 2)
        return lat, (lon + 180.0) % 360.0 - 180.0

    def rotation(self, lon):
        """The angle between grid north and true north at each longitude,
        radians. A grid-relative wind (u, v) turns into earth-relative
        (u cos a + v sin a, -u sin a + v cos a)."""
        return self.n * self._dlon(lon)

    def sample(self, field: np.ndarray, lat, lon) -> np.ndarray:
        """Bilinear values at points; NaN off the grid."""
        i, j = self.ij(lat, lon)
        i = np.atleast_1d(i)
        j = np.atleast_1d(j)
        out = np.full(i.shape, np.nan, dtype=np.float64)
        ok = (i >= 0) & (j >= 0) & (i <= self.nx - 1) & (j <= self.ny - 1)
        if not ok.any():
            return out
        ii, jj = i[ok], j[ok]
        i0 = np.minimum(np.floor(ii).astype(int), self.nx - 2)
        j0 = np.minimum(np.floor(jj).astype(int), self.ny - 2)
        fi, fj = ii - i0, jj - j0
        f = field
        v = (f[j0, i0] * (1 - fi) * (1 - fj) + f[j0, i0 + 1] * fi * (1 - fj)
             + f[j0 + 1, i0] * (1 - fi) * fj + f[j0 + 1, i0 + 1] * fi * fj)
        out[ok] = v
        return out

    def earth_wind(self, u: np.ndarray, v: np.ndarray, lon) -> Tuple[np.ndarray, np.ndarray]:
        a = self.rotation(lon)
        c, s = np.cos(a), np.sin(a)
        return u * c + v * s, -u * s + v * c

    def lonlat_arrays(self) -> Tuple[np.ndarray, np.ndarray]:
        jj, ii = np.mgrid[0:self.ny, 0:self.nx]
        lat, lon = self.latlon(ii, jj)
        return lat, lon


def grid_relative(meta: Dict[str, object]) -> bool:
    """True when u and v follow the grid's axes (bit 5 of the resolution
    and component flags), which is how HRRR ships them."""
    flags = meta.get("resolutionAndComponentFlags")
    return bool(flags is not None and int(flags) & 0x08)


def wind_speed_dir(u, v):
    """Speed in the input's unit and the direction the wind blows FROM,
    degrees true."""
    u = np.asarray(u, dtype=np.float64)
    v = np.asarray(v, dtype=np.float64)
    spd = np.hypot(u, v)
    deg = (np.degrees(np.arctan2(-u, -v)) + 360.0) % 360.0
    return spd, deg
