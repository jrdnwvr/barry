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
- Surface pressure 840 hPa west of 86 W (high ground at 1,600 m, so 850
  and 925 hPa are underground there) and 990 hPa east of it (200 m).
- The Aloft column's 17 levels: temperature on the standard lapse rate,
  a saturated deck with cloud water at 850 to 800 hPa, 60 percent humidity
  elsewhere, wind from 250 strengthening with height; 2 m 17 C over 10 C,
  freezing level 2,308 m.

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


def message(values: np.ndarray, param=None, height_m=None) -> bytes:
    h = eccodes.codes_grib_new_from_samples("GRIB2")
    if param is not None:
        d, c, n = param
        eccodes.codes_set(h, "discipline", d)
        eccodes.codes_set(h, "parameterCategory", c)
        eccodes.codes_set(h, "parameterNumber", n)
    if height_m is not None:
        # Specific altitude above mean sea level, as GTG and CIP give it.
        eccodes.codes_set(h, "typeOfFirstFixedSurface", 102)
        eccodes.codes_set(h, "scaleFactorOfFirstFixedSurface", 0)
        eccodes.codes_set(h, "scaledValueOfFirstFixedSurface", int(height_m))
    eccodes.codes_set(h, "gridDefinitionTemplateNumber", 30)
    for k, v in [("shapeOfTheEarth", 6), ("Nx", NX), ("Ny", NY),
                 ("latitudeOfFirstGridPointInDegrees", 37.0), ("longitudeOfFirstGridPointInDegrees", 272.0),
                 ("LaDInDegrees", 38.5), ("LoVInDegrees", 262.5), ("Latin1InDegrees", 38.5),
                 ("Latin2InDegrees", 38.5), ("DxInMetres", 25000), ("DyInMetres", 25000),
                 ("resolutionAndComponentFlags", 8), ("iScansNegatively", 0), ("jScansPositively", 1),
                 ("packingType", "grid_simple"), ("bitsPerValue", 24)]:
        eccodes.codes_set(h, k, v)
    vals = values.astype(float).ravel()
    if (vals == 9999.0).any():
        eccodes.codes_set(h, "bitmapPresent", 1)
        eccodes.codes_set(h, "missingValue", 9999.0)
    eccodes.codes_set_values(h, vals)
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
    u80, v80 = to_grid(np.full_like(lat, 14.0), np.zeros_like(lat))
    high = lon < -86.0
    sfc = [
        ("ABSV", "1000 mb", np.zeros_like(lat)),                      # not asked for
        ("UGRD", "10 m above ground", u10),
        ("VGRD", "10 m above ground", v10),
        ("GUST", "surface", np.full_like(lat, 12.0)),
        ("HPBL", "surface", np.full_like(lat, 900.0)),
        ("CAPE", "surface", np.full_like(lat, 500.0)),
        ("MSLMA", "mean sea level", (1016.0 - 2.0 * (lat - 38.5)) * 100.0),
        ("TMP", "2 m above ground", np.full_like(lat, 290.0)),
        ("DPT", "2 m above ground", np.full_like(lat, 283.0)),
        ("HGT", "0C isotherm", np.full_like(lat, 2308.0)),
        ("HGT", "surface", np.where(high, 1600.0, 200.0)),
        # High ground in the west third: 850 hPa lies under it there.
        ("PRES", "surface", np.where(high, 84000.0, 99000.0)),
        # The point forecast's own fields.
        ("TCDC", "entire atmosphere", np.full_like(lat, 40.0)),
        ("CIN", "surface", np.full_like(lat, -20.0)),
        ("DSWRF", "surface", np.full_like(lat, 300.0)),
        ("UGRD", "80 m above ground", u80),
        ("VGRD", "80 m above ground", v80),
        ("PRATE", "surface", np.zeros_like(lat)),
    ]
    prs = [("ABSV", "1000 mb", np.zeros_like(lat))]
    col_levels = (1000, 975, 950, 925, 900, 875, 850, 825, 800, 750, 700, 650, 600, 550, 500, 450, 400)
    for p in col_levels:
        # Heights: the map's round numbers at its five levels, the standard
        # atmosphere elsewhere; 60 m less per degree north everywhere.
        h0 = STD_HGT.get(p, 44330.8 * (1 - (p / 1013.25) ** 0.190263))
        hgt = h0 - 60.0 * (lat - 38.5)
        t = 288.15 - 0.0065 * h0
        cloud = p in (850, 825, 800)                                   # a deck from about 5,000 to 6,500 ft
        spd = float(np.interp(p, [500, 600, 700, 850, 925, 1000], [30, 25, 20, 15, 10, 8]))
        d = np.radians(250.0)
        ug, vg = to_grid(-spd * np.sin(d) * np.ones_like(lat), -spd * np.cos(d) * np.ones_like(lat))
        prs += [("HGT", f"{p} mb", hgt), ("TMP", f"{p} mb", np.full_like(lat, t)),
                ("RH", f"{p} mb", np.full_like(lat, 98.0 if cloud else 60.0)),
                ("UGRD", f"{p} mb", ug), ("VGRD", f"{p} mb", vg),
                ("CLMR", f"{p} mb", np.full_like(lat, 2e-5 if cloud else 0.0)),
                ("CIMIXR", f"{p} mb", np.zeros_like(lat))]

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

    # GTG: turbulence every 1,000 ft to 10,100; 0.3 (moderate) from 5,100
    # to 6,100 ft, 0.05 (smooth) elsewhere; nothing below the ground in the
    # high west third.
    data = b""
    for k in range(11):
        m = 30 + 304.8 * k
        ft = m * 3.28084
        v = np.full_like(lat, 0.3 if 5000 <= ft <= 6200 else 0.05)
        v = np.where(high & (m < 1600), 9999.0, v)
        data += message(v, (0, 19, 30), m)
    with open(os.path.join(OUT, "gtg.grib2"), "wb") as fh:
        fh.write(data)
    # CIP: every 500 ft to 10,000; moderate icing, 60 percent, some large
    # drops, from 7,000 to 8,000 ft; none elsewhere.
    data = b""
    for k in range(20):
        m = 152.4 * (k + 1)
        ft = m * 3.28084
        ice = 7000 <= ft <= 8000
        data += message(np.full_like(lat, 0.6 if ice else 0.0), (0, 19, 233), m)
        data += message(np.full_like(lat, 3.0 if ice else 0.0), (0, 19, 37), m)
        data += message(np.full_like(lat, 0.2 if ice else 0.0), (0, 19, 217), m)
    with open(os.path.join(OUT, "cip.grib2"), "wb") as fh:
        fh.write(data)
    print("gtg and cip written")

    # NBM: the fields Barry takes, with an unwanted one first and a spread
    # message after the temperature, and an index template whose hour is
    # filled in per request ({f} and {p} for the hour and the one before).
    nbm = [
        ("APTMP", "2 m above ground", "{f} hour fcst", "", np.full_like(lat, 290.0)),
        ("TMP", "2 m above ground", "{f} hour fcst", "", np.full_like(lat, 293.15)),
        ("TMP", "2 m above ground", "{f} hour fcst", "ens std dev", np.full_like(lat, 1.0)),
        ("DPT", "2 m above ground", "{f} hour fcst", "", np.full_like(lat, 285.15)),
        ("WIND", "10 m above ground", "{f} hour fcst", "", np.full_like(lat, 5.0)),
        ("WDIR", "10 m above ground", "{f} hour fcst", "", np.full_like(lat, 180.0)),
        ("GUST", "10 m above ground", "{f} hour fcst", "", np.full_like(lat, 9.0)),
        ("TCDC", "surface", "{f} hour fcst", "", np.full_like(lat, 70.0)),
        ("APCP", "surface", "{p}-{f} hour acc fcst", "prob >0.254:prob fcst 255/255", np.full_like(lat, 60.0)),
        ("TSTM", "surface", "{p}-{f} hour acc fcst", "probability forecast", np.full_like(lat, 35.0)),
    ]
    data = b""
    idx = []
    for n, (name, level, fcst, extra, values) in enumerate(nbm, start=1):
        idx.append(f"{n}:{len(data)}:d=2026092500:{name}:{level}:{fcst}:{extra}")
        data += message(values)
    with open(os.path.join(OUT, "nbm.grib2"), "wb") as fh:
        fh.write(data)
    with open(os.path.join(OUT, "nbm.idx.tmpl"), "w") as fh:
        fh.write("\n".join(idx) + "\n")
    print("nbm written", len(data))


if __name__ == "__main__":
    main()
