"""The model's reflectivity as radar frames.

Past the nowcast's hour the radar's timeline shows what the model expects
the radar to show: HRRR's composite reflectivity, an hour at a time. A
field arrives on the model's Lambert grid; here it is read onto a regular
latitude and longitude grid and written as the same uint8 dBZ codes the
MRMS frames use (dBZ = code / 2 - 32), so radar.RadarStore keeps it and
draws its tiles with no code of its own. 0.03 degree, about the model's
own 3 km.
"""

from __future__ import annotations

from typing import List, Optional, Sequence, Tuple

import numpy as np

from . import grib

# The model's domain with a little to spare; rows run north to south.
LAT_N, LAT_S, LON_W, LON_E = 53.0, 21.0, -134.5, -60.5
STEP = 0.03
MIN_DBZ = 5.0            # the app draws nothing below this; neither does the model's frame
BAND = 256               # rows read at a time


def grid() -> dict:
    """The frame's grid, in the form RadarStore.put takes: the first
    point's centre and the spacing."""
    return {"lat0": LAT_N - STEP / 2, "lon0": LON_W + STEP / 2, "dlat": STEP, "dlon": STEP}


def shape() -> Tuple[int, int]:
    return int(round((LAT_N - LAT_S) / STEP)), int(round((LON_E - LON_W) / STEP))


def to_codes(g: grib.LambertGrid, fields: Sequence[np.ndarray]) -> List[np.ndarray]:
    """Each model field (dBZ on the model's grid) as codes on the frame's
    grid, bilinear, 0 off the model's grid and under MIN_DBZ. The fields
    share the grid, so where each frame point falls on it is worked out
    once, a band of rows at a time."""
    ny, nx = shape()
    gd = grid()
    lons = gd["lon0"] + np.arange(nx) * STEP
    out = [np.zeros((ny, nx), dtype=np.uint8) for _ in fields]
    for r0 in range(0, ny, BAND):
        r1 = min(ny, r0 + BAND)
        lats = gd["lat0"] - np.arange(r0, r1) * STEP
        la = np.repeat(lats, nx)
        lo = np.tile(lons, r1 - r0)
        i, j = g.ij(la, lo)
        ok = (i >= 0) & (j >= 0) & (i <= g.nx - 1) & (j <= g.ny - 1)
        if not ok.any():
            continue
        ii, jj = i[ok], j[ok]
        i0 = np.minimum(np.floor(ii).astype(np.int64), g.nx - 2)
        j0 = np.minimum(np.floor(jj).astype(np.int64), g.ny - 2)
        fi, fj = (ii - i0).astype(np.float32), (jj - j0).astype(np.float32)
        for f, dst in zip(fields, out):
            v = (f[j0, i0] * (1 - fi) * (1 - fj) + f[j0, i0 + 1] * fi * (1 - fj)
                 + f[j0 + 1, i0] * (1 - fi) * fj + f[j0 + 1, i0 + 1] * fi * fj).astype(np.float32)
            codes = np.clip(np.rint((v + 32.0) * 2.0), 0, 255).astype(np.uint8)
            codes[~(v >= MIN_DBZ)] = 0
            band = np.zeros((r1 - r0) * nx, dtype=np.uint8)
            band[ok] = codes
            dst[r0:r1] = band.reshape(r1 - r0, nx)
    return out
