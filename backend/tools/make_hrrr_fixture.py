"""Build the small HRRR-shaped GRIB2 fixtures the tests serve.

A 24 x 16 Lambert grid at 25 km over the Ohio valley, on HRRR's cone
(LoV 262.5, standard parallels 38.5, sphere 6,371,229 m), with winds
stored grid-relative the way HRRR stores them. Known values:

- 10 m wind from 270 at 10 m/s everywhere (earth-relative), stored
  turned to the grid, so a test can see the rotation undone.
- Heights rise 60 m per degree toward the south at every level, from
  1,500 m at 38.5 N at 850 hPa (and the standard heights elsewhere), so
  the contours run east and west.
- Sea-level pressure 1016 hPa at 38.5 N, 2 hPa less per degree north.
- Gust 12 m/s, boundary layer 900 m, CAPE 500 J/kg.
- Surface pressure 840 hPa west of 86 W (high ground, so 850 and 925
  hPa are underground there) and 990 hPa east of it.

Two files, surface and pressure, each with an index in NOAA's format and
a message Barry doesn't ask for between the ones it does, so the range
merging is exercised.

    cd backend && .venv/bin/python tools/make_hrrr_fixture.py
"""

import os
import sys

import eccodes
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from app import grib  # noqa: E402

NX, NY = 24, 16
OUT = os.path.join(os.path.dirname(__file__), "..", "tests", "fixtures")
STD_HGT = {925: 760, 850: 1500, 700: 3050, 600: 4350, 500: 5750}


def message(values: np.ndarray) -> bytes:
    h = eccodes.codes_grib_new_from_samples("GRIB2")
    eccodes.codes_set(h, "gridDefinitionTemplateNumber", 30)
    for k, v in [("shapeOfTheEarth", 6), ("Nx", NX), ("Ny", NY),
                 ("latitudeOfFirstGridPointInDegrees", 37.0), ("longitudeOfFirstGridPointInDegrees", 272.0),
                 ("LaDInDegrees", 38.5), ("LoVInDegrees", 262.5), ("Latin1InDegrees", 38.5),
                 ("Latin2InDegrees", 38.5), ("DxInMetres", 25000), ("DyInMetres", 25000),
                 ("resolutionAndComponentFlags", 8), ("iScansNegatively", 0), ("jScansPositively", 1),
                 ("packingType", "grid_simple"), ("bitsPerValue", 24)]:
        eccodes.codes_set(h, k, v)
    eccodes.codes_set_values(h, values.astype(float).ravel())
    msg = eccodes.codes_get_message(h)
    eccodes.codes_release(h)
    return msg


def main():
    g = grib.LambertGrid(NX, NY, 37.0, 272.0, 262.5, 38.5, 38.5, 25000, 25000)
    lat, lon = g.lonlat_arrays()
    a = g.rotation(lon)

    def to_grid(ue, ve):
        # Inverse of LambertGrid.earth_wind.
        return ue * np.cos(a) - ve * np.sin(a), ue * np.sin(a) + ve * np.cos(a)

    u10, v10 = to_grid(np.full_like(lat, 10.0), np.zeros_like(lat))
    sfc = [
        ("TMP", "2 m above ground", np.full_like(lat, 290.0)),        # not asked for
        ("UGRD", "10 m above ground", u10),
        ("VGRD", "10 m above ground", v10),
        ("GUST", "surface", np.full_like(lat, 12.0)),
        ("HPBL", "surface", np.full_like(lat, 900.0)),
        ("CAPE", "surface", np.full_like(lat, 500.0)),
        ("MSLMA", "mean sea level", (1016.0 - 2.0 * (lat - 38.5)) * 100.0),
        # High ground in the west third: 850 hPa lies under it there.
        ("PRES", "surface", np.where(lon < -86.0, 84000.0, 99000.0)),
    ]
    prs = [("TMP", "1000 mb", np.full_like(lat, 288.0))]
    for k, p in enumerate((925, 850, 700, 600, 500)):
        # From 250 degrees at 10 m/s plus 5 per level.
        spd = 10.0 + 5 * k
        d = np.radians(250.0)
        ue, ve = -spd * np.sin(d) * np.ones_like(lat), -spd * np.cos(d) * np.ones_like(lat)
        ug, vg = to_grid(ue, ve)
        prs += [("HGT", f"{p} mb", STD_HGT[p] - 60.0 * (lat - 38.5)),
                ("UGRD", f"{p} mb", ug), ("VGRD", f"{p} mb", vg)]

    for name, fields in (("hrrr_sfc", sfc), ("hrrr_prs", prs)):
        data = b""
        idx = []
        for n, (short, level, values) in enumerate(fields, start=1):
            idx.append(f"{n}:{len(data)}:d=2026092500:{short}:{level}:1 hour fcst:")
            data += message(values)
        with open(os.path.join(OUT, name + ".grib2"), "wb") as fh:
            fh.write(data)
        with open(os.path.join(OUT, name + ".grib2.idx"), "w") as fh:
            fh.write("\n".join(idx) + "\n")
        print(name, len(data), "bytes,", len(fields), "messages")


if __name__ == "__main__":
    main()
