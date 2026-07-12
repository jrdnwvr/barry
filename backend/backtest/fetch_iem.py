"""Download a year of hourly METARs around a center station from the IEM archive.

Iowa State's Environmental Mesonet archives ASOS/AWOS observations going back
decades — the ground truth the front watch's live AWC feed can't provide (AWC
keeps 15 days). For each region this grabs the same ring the production bbox
query would see: the nearest stations within MAX_KM of the center, hourly
routine METARs + specials, one CSV per station under data/<REGION>/ (gitignored;
re-runs skip files that already exist).

Regions are picked for climate diversity — the point is to stress the front
watch's assumptions, not to flatter them:
  LUK  Ohio Valley: the original tuning region (Midwest frontal parade)
  FTW  southern plains: drylines + violent convective troughs
  BFI  Puget Sound: marine systems arriving over an ocean with NO stations —
       the ring is one-sided, hard mode for the plane fit
  FCM  upper Midwest: strong classic fronts, dense station field
  DVT  Sonoran desert: quiet winters, summer heat lows + monsoon — the
       predicted false-alarm factory

Usage:  .venv/bin/python backtest/fetch_iem.py FTW BFI FCM DVT
        (no args = all regions; cached stations are skipped)
"""

from __future__ import annotations

import json
import math
import sys
import time
from pathlib import Path

import httpx

REGIONS = {
    "LUK": {"networks": ["OH_ASOS", "KY_ASOS", "IN_ASOS", "WV_ASOS"],
            "label": "Cincinnati OH — Midwest frontal (tuning region)"},
    "FTW": {"networks": ["TX_ASOS", "OK_ASOS"],
            "label": "Fort Worth TX — southern plains, drylines"},
    "BFI": {"networks": ["WA_ASOS", "OR_ASOS"],
            "label": "Seattle WA — marine, one-sided ring (ocean west)"},
    "FCM": {"networks": ["MN_ASOS", "WI_ASOS", "IA_ASOS"],
            "label": "Minneapolis MN — northern frontal, dense field"},
    "DVT": {"networks": ["AZ_ASOS"],
            "label": "Phoenix AZ — desert heat lows, monsoon"},
}

MAX_KM = 240.0               # mirror front.MAX_RING_KM
MAX_STATIONS = 30            # production caps the ring at 24; spares for gaps
START = (2025, 7, 1)
END = (2026, 7, 1)
SLEEP_S = 8.0                # IEM 429s burst traffic; be genuinely polite

DATA_ROOT = Path(__file__).parent / "data"
KM_PER_DEG_LAT = 111.32


def dist_km(lat0: float, lon0: float, lat: float, lon: float) -> float:
    dy = (lat - lat0) * KM_PER_DEG_LAT
    dx = (lon - lon0) * KM_PER_DEG_LAT * math.cos(math.radians(lat0))
    return math.hypot(dx, dy)


def pick_stations(client: httpx.Client, center_id: str, networks: list) -> dict:
    """Nearest archived stations within the ring; center coords come from the
    network listing so nothing is hand-typed."""
    start_iso = f"{START[0]}-{START[1]:02d}-{START[2]:02d}"
    all_feats: dict[str, dict] = {}
    for net in networks:
        resp = client.get(f"https://mesonet.agron.iastate.edu/geojson/network/{net}.geojson")
        resp.raise_for_status()
        for f in resp.json()["features"]:
            sid = f["properties"].get("sid") or f["id"]
            lon, lat = f["geometry"]["coordinates"]
            begin = f["properties"].get("archive_begin") or "9999"
            all_feats[sid] = {"lat": lat, "lon": lon, "begin": begin,
                              "name": f["properties"].get("sname")}
    if center_id not in all_feats:
        raise SystemExit(f"center {center_id} not found in {networks}")
    c = all_feats[center_id]
    found = {}
    for sid, f in all_feats.items():
        d = dist_km(c["lat"], c["lon"], f["lat"], f["lon"])
        if d > MAX_KM or f["begin"] > start_iso:
            continue
        found[sid] = {"lat": f["lat"], "lon": f["lon"], "dist_km": round(d, 1),
                      "name": f["name"]}
    ordered = dict(sorted(found.items(), key=lambda kv: kv[1]["dist_km"]))
    picked = dict(list(ordered.items())[:MAX_STATIONS])
    picked[center_id] = ordered[center_id]  # center always included
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
    for attempt in (1, 2):
        resp = client.get("https://mesonet.agron.iastate.edu/cgi-bin/request/asos.py",
                          params=params, timeout=180.0)
        if resp.status_code == 429 and attempt == 1:
            time.sleep(90.0)  # cool the rate limiter, then one retry
            continue
        resp.raise_for_status()
        return resp.text
    raise RuntimeError("unreachable")


def fetch_region(client: httpx.Client, key: str) -> None:
    cfg = REGIONS[key]
    out_dir = DATA_ROOT / key
    out_dir.mkdir(parents=True, exist_ok=True)
    stations = pick_stations(client, key, cfg["networks"])
    (out_dir / "stations.json").write_text(json.dumps(
        {"center": key, "label": cfg["label"], "stations": stations}, indent=2))
    print(f"[{key}] {cfg['label']}: {len(stations)} stations")
    for i, sid in enumerate(stations):
        out = out_dir / f"{sid}.csv"
        if out.exists() and out.stat().st_size > 1000:
            print(f"  [{i+1}/{len(stations)}] {sid} cached")
            continue
        try:
            text = fetch_station(client, sid)
        except Exception as e:  # noqa: BLE001 — a lost station shouldn't kill the run
            print(f"  [{i+1}/{len(stations)}] {sid} FAILED: {e}", file=sys.stderr)
            continue
        out.write_text(text)
        print(f"  [{i+1}/{len(stations)}] {sid} {text.count(chr(10)) - 1} rows")
        time.sleep(SLEEP_S)


def main() -> None:
    keys = sys.argv[1:] or list(REGIONS)
    with httpx.Client(headers={"User-Agent": "Barry backtest (jrdn@wvr.me)"},
                      timeout=60.0) as client:
        for key in keys:
            fetch_region(client, key)
    print("done")


if __name__ == "__main__":
    main()
