"""Build app/data/runways.json.gz from OurAirports (public domain).

    python tools/build_runways.py [runways.csv airports.csv]

Downloads the two CSVs when paths aren't given. Output: one JSON object
mapping every id a METAR might carry for an airport (OurAirports ident,
icao_code, gps_code) to its open runways as
[le_ident, he_ident, le_heading_degT, he_heading_degT, length_ft].
Helipads and closed runways are dropped, as is anything without a true
heading (the crosswind math needs it)."""

from __future__ import annotations

import csv
import gzip
import json
import sys
import urllib.request
from math import atan2, cos, degrees, radians, sin
from pathlib import Path

BASE = "https://davidmegginson.github.io/ourairports-data/"
OUT = Path(__file__).resolve().parent.parent / "app" / "data" / "runways.json.gz"


def _read(path_or_name: str):
    if Path(path_or_name).exists():
        return open(path_or_name, newline="", encoding="utf-8")
    data = urllib.request.urlopen(BASE + path_or_name).read().decode("utf-8")
    from io import StringIO
    return StringIO(data)


def _bearing(lat1, lon1, lat2, lon2) -> float:
    """Initial great-circle bearing, degrees true."""
    p1, p2 = radians(lat1), radians(lat2)
    dl = radians(lon2 - lon1)
    x = sin(dl) * cos(p2)
    y = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
    return (degrees(atan2(x, y)) + 360.0) % 360.0


def _heading(r) -> float | None:
    """Published true heading, else the bearing between the two runway ends
    (most small fields publish end coordinates but no heading)."""
    try:
        return float(r["le_heading_degT"])
    except ValueError:
        pass
    try:
        return _bearing(float(r["le_latitude_deg"]), float(r["le_longitude_deg"]),
                        float(r["he_latitude_deg"]), float(r["he_longitude_deg"]))
    except ValueError:
        return None


def main(runways_src="runways.csv", airports_src="airports.csv") -> None:
    ids_by_ref: dict[str, set[str]] = {}
    with _read(airports_src) as f:
        for a in csv.DictReader(f):
            ids = {a["ident"], a.get("icao_code") or "", a.get("gps_code") or ""}
            ids_by_ref[a["id"]] = {i.upper() for i in ids if i}

    table: dict[str, list] = {}
    kept = 0
    with _read(runways_src) as f:
        for r in csv.DictReader(f):
            if r["closed"] == "1":
                continue
            le, he = r["le_ident"].strip(), r["he_ident"].strip()
            if not le or le.upper().startswith("H"):
                continue
            le_h = _heading(r)
            if le_h is None:
                continue
            try:
                he_h = float(r["he_heading_degT"])
            except ValueError:
                he_h = (le_h + 180.0) % 360.0
            try:
                length = int(float(r["length_ft"]))
            except ValueError:
                length = None
            row = [le, he or "", round(le_h, 1), round(he_h, 1), length]
            for sid in ids_by_ref.get(r["airport_ref"], {r["airport_ident"].upper()}):
                table.setdefault(sid, []).append(row)
            kept += 1

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with gzip.open(OUT, "wt", encoding="utf-8") as f:
        json.dump(table, f, separators=(",", ":"))
    print(f"{kept} runways, {len(table)} ids -> {OUT} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main(*sys.argv[1:])
