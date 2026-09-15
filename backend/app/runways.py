"""Runway table for the crosswind readout.

Data: OurAirports (public domain), compacted by tools/build_runways.py into
app/data/runways.json.gz — every id a METAR might carry (ICAO, GPS, local)
maps to that airport's open runways with TRUE headings. Loaded once, lazily,
on first use; ~1 MB in memory."""

from __future__ import annotations

import gzip
import json
from functools import lru_cache
from pathlib import Path
from typing import Dict, List

from .models import Runway

DATA = Path(__file__).resolve().parent / "data" / "runways.json.gz"


@lru_cache(maxsize=1)
def _table() -> Dict[str, list]:
    if not DATA.exists():
        return {}
    with gzip.open(DATA, "rt", encoding="utf-8") as f:
        return json.load(f)


def for_station(station: str) -> List[Runway]:
    """Open runways at `station`, longest first. Empty when unknown — the
    client simply shows no crosswind card."""
    rows = _table().get(station.upper(), [])
    out = [
        Runway(le=r[0], he=r[1], leHeading=r[2], heHeading=r[3], lengthFt=r[4])
        for r in rows
    ]
    out.sort(key=lambda r: -(r.lengthFt or 0))
    return out
