"""Download a year of hourly METARs around KLUK from the IEM ASOS archive.

Iowa State's Environmental Mesonet archives ASOS/AWOS observations going back
decades — the ground truth the front watch's live AWC feed can't provide (AWC
keeps 15 days). This grabs the same regional ring the production bbox query
would see: the nearest stations within MAX_KM of the center, hourly routine
METARs + specials, one CSV per station under data/ (gitignored; re-runs skip
files that already exist).

Usage:  .venv/bin/python backtest/fetch_iem.py
"""

from __future__ import annotations

import json
import math
import sys
import time
from pathlib import Path

import httpx

CENTER_ID = "LUK"            # IEM ids are unprefixed (LUK = KLUK)
CENTER_LAT, CENTER_LON = 39.106, -84.4161
NETWORKS = ["OH_ASOS", "KY_ASOS", "IN_ASOS", "WV_ASOS"]
MAX_KM = 240.0               # mirror front.MAX_RING_KM
MAX_STATIONS = 30            # production caps the ring at 24; a few spares for gaps
START = (2025, 7, 1)
END = (2026, 7, 1)

DATA_DIR = Path(__file__).parent / "data"
KM_PER_DEG_LAT = 111.32


def dist_km(lat: float, lon: float) -> float:
    dy = (lat - CENTER_LAT) * KM_PER_DEG_LAT
    dx = (lon - CENTER_LON) * KM_PER_DEG_LAT * math.cos(math.radians(CENTER_LAT))
    return math.hypot(dx, dy)


def pick_stations(client: httpx.Client) -> dict:
    """Nearest archived stations within the ring, center always included."""
    found: dict[str, dict] = {}
    start_iso = f"{START[0]}-{START[1]:02d}-{START[2]:02d}"
    for net in NETWORKS:
        resp = client.get(f"https://mesonet.agron.iastate.edu/geojson/network/{net}.geojson")
        resp.raise_for_status()
        for f in resp.json()["features"]:
            sid = f["properties"].get("sid") or f["id"]
            lon, lat = f["geometry"]["coordinates"]
            d = dist_km(lat, lon)
            begin = f["properties"].get("archive_begin") or "9999"
            if d > MAX_KM or begin > start_iso:
                continue
            found[sid] = {"lat": lat, "lon": lon, "dist_km": round(d, 1),
                          "name": f["properties"].get("sname")}
    ordered = dict(sorted(found.items(), key=lambda kv: kv[1]["dist_km"]))
    picked = dict(list(ordered.items())[:MAX_STATIONS])
    if CENTER_ID not in picked and CENTER_ID in ordered:
        picked[CENTER_ID] = ordered[CENTER_ID]
    return picked


def fetch_station(client: httpx.Client, sid: str) -> str:
    params = {
        "station": sid,
        "data": ["alti", "mslp", "drct"],
        "year1": START[0], "month1": START[1], "day1": START[2],
        "year2": END[0], "month2": END[1], "day2": END[2],
        "tz": "Etc/UTC", "format": "onlycomma",
        "latlon": "yes", "missing": "empty", "trace": "empty",
        # 3 = routine hourly METAR, 4 = specials — same mix the live feed sees.
        "report_type": ["3", "4"],
    }
    resp = client.get("https://mesonet.agron.iastate.edu/cgi-bin/request/asos.py",
                      params=params, timeout=180.0)
    resp.raise_for_status()
    return resp.text


def main() -> None:
    DATA_DIR.mkdir(exist_ok=True)
    with httpx.Client(headers={"User-Agent": "Barry backtest (jrdn@wvr.me)"},
                      timeout=60.0) as client:
        stations = pick_stations(client)
        (DATA_DIR / "stations.json").write_text(json.dumps(stations, indent=2))
        print(f"{len(stations)} stations within {MAX_KM:.0f} km of {CENTER_ID}")
        for i, sid in enumerate(stations):
            out = DATA_DIR / f"{sid}.csv"
            if out.exists() and out.stat().st_size > 1000:
                print(f"  [{i+1}/{len(stations)}] {sid} cached")
                continue
            try:
                text = fetch_station(client, sid)
            except Exception as e:  # noqa: BLE001 — a lost station shouldn't kill the run
                print(f"  [{i+1}/{len(stations)}] {sid} FAILED: {e}", file=sys.stderr)
                continue
            out.write_text(text)
            rows = text.count("\n") - 1
            print(f"  [{i+1}/{len(stations)}] {sid} {rows} rows")
            time.sleep(1.0)  # be polite to IEM
    print("done")


if __name__ == "__main__":
    main()
