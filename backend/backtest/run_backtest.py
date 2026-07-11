"""Backtest the front watch against a year of real regional METAR history.

Replays the PRODUCTION algorithm (app.front — the same _delta3h, ring geometry,
and plane fit the server runs) hour by hour over the IEM archive fetched by
fetch_iem.py, then scores it against ground truth the live system never gets to
see: pressure troughs detected at the center station with full hindsight.

What gets measured
  POD          fraction of real troughs preceded by an "approaching" call
               in the 12 h before the trough
  FAR          fraction of "approaching" episodes with no trough in the
               following 18 h
  lead time    trough time minus the first approaching call (median)
  direction    circular error between the algorithm's falls bearing and the
               trough's true propagation direction (fit to per-station
               trough arrival times) — only where that fit is itself solid
  duty cycle   fraction of all hours spent saying anything at all

Ground-truth troughs: center series is resampled hourly, de-tided with the
production S2 model, lightly smoothed; a trough is a local minimum with
>= FALL_MIN hPa of fall in the prior 12 h and >= RISE_MIN hPa of rise in the
next 9 h. Troughs with a >= 40 degree wind shift across them are tagged
"frontal" and also scored separately — those are the ones that matter.

The status gate is re-derived from cached per-hour field stats so the
threshold sweep costs nothing; it MIRRORS analyze() in app/front.py — if the
gate there changes, change _status() here to match.

Usage:  .venv/bin/python backtest/run_backtest.py
"""

from __future__ import annotations

import bisect
import csv
import json
import math
import statistics
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).parent.parent))

from app import front  # noqa: E402  (production code under test)
from app.interpreter import tide  # noqa: E402

DATA_DIR = Path(__file__).parent / "data"
CENTER_ID = "LUK"
INHG_TO_HPA = 33.8639

# Ground-truth trough definition (hindsight, de-tided hPa)
FALL_MIN = 2.0     # required fall into the minimum over the prior 12 h
RISE_MIN = 1.2     # required rise out of it over the next 9 h
MERGE_H = 6        # minima closer than this collapse into the deepest one
WIND_SHIFT_DEG = 40.0

# Scoring windows
HIT_WINDOW_H = 12      # approaching must fire within this many hours before
FA_WINDOW_H = 18       # an episode is "true" if a trough lands within this


@dataclass(frozen=True)
class Ob:
    t: datetime
    slp: Optional[float]
    altim: Optional[float]


# ---- data loading ------------------------------------------------------------


def load_station(sid: str) -> Tuple[List[Ob], List[Optional[float]]]:
    obs: List[Ob] = []
    winds: List[Optional[float]] = []
    seen = set()
    with open(DATA_DIR / f"{sid}.csv") as f:
        for row in csv.DictReader(f):
            try:
                t = datetime.strptime(row["valid"], "%Y-%m-%d %H:%M").replace(tzinfo=timezone.utc)
            except ValueError:
                continue
            if t in seen:
                continue
            seen.add(t)
            slp = float(row["mslp"]) if row.get("mslp") else None
            alti = float(row["alti"]) * INHG_TO_HPA if row.get("alti") else None
            if slp is None and alti is None:
                continue
            drct = float(row["drct"]) if row.get("drct") else None
            if drct is not None and drct <= 0:
                drct = None  # IEM reports calm as 0 — useless for shift detection
            obs.append(Ob(t=t, slp=slp, altim=round(alti, 2) if alti else None))
            winds.append(drct)
    order = sorted(range(len(obs)), key=lambda i: obs[i].t)
    return [obs[i] for i in order], [winds[i] for i in order]


# ---- per-hour field stats (threshold-independent, cached) ---------------------


@dataclass
class HourStats:
    t: datetime
    n: int                      # ring stations with a usable delta
    gradient: Optional[float]   # hPa/3h per 100 km
    coherence: Optional[float]
    falls_bearing: Optional[float]
    min_fall: Optional[float]
    own: Optional[float]
    deltas: List[Tuple[float, float, float]]  # ring (x_km, y_km, delta3h)


def field_stats(stations: dict, series: dict, times_idx: dict,
                hours: List[datetime]) -> List[HourStats]:
    out: List[HourStats] = []
    for T in hours:
        pts = []
        min_fall = None
        own = None
        for sid, meta in stations.items():
            obs = series[sid]
            times = times_idx[sid]
            hi = bisect.bisect_right(times, T)
            lo = bisect.bisect_left(times, T - timedelta(hours=4), 0, hi)
            window = obs[lo:hi]
            if len(window) < 2:
                continue
            d = front._delta3h(window, T)
            if d is None:
                continue
            if sid == CENTER_ID:
                own = d
                continue
            if meta["dist_km"] > front.MAX_RING_KM:
                continue
            x = meta["dx"]
            y = meta["dy"]
            pts.append((x, y, d))
            if min_fall is None or d < min_fall:
                min_fall = d
        n = len(pts)
        if own is not None:
            pts.append((0.0, 0.0, own))
        gradient = coherence = falls_bearing = None
        if n >= 3:
            fit = front._plane_fit(pts)
            if fit is not None:
                gx, gy, r2 = fit
                coherence = r2
                mag = math.hypot(gx, gy)
                gradient = mag * 100.0
                if mag > 1e-6:
                    falls_bearing = (math.degrees(math.atan2(-gx, -gy)) + 360.0) % 360.0
        out.append(HourStats(t=T, n=n, gradient=gradient, coherence=coherence,
                             falls_bearing=falls_bearing, min_fall=min_fall, own=own,
                             deltas=pts[:n]))
    return out


def fall_centroid(h: Optional[HourStats]) -> Optional[Tuple[float, float]]:
    """Fall-weighted centroid of the ring's tendency field — where the falling
    air 'is'. Weight = how far below -0.5 hPa/3h a station sits."""
    if h is None:
        return None
    wx = wy = wsum = 0.0
    for x, y, d in h.deltas:
        w = max(0.0, -d - 0.5)
        wx += w * x
        wy += w * y
        wsum += w
    if wsum < 1.5:
        return None
    return wx / wsum, wy / wsum


def centroid_bearing(t: datetime, stats_by_t: dict, lag_h: int = 4) -> Optional[float]:
    """Candidate v2 direction: 'coming from' bearing from the MOTION of the
    fall centroid over the last lag_h hours, instead of the instantaneous
    gradient. Tested here before anything ships."""
    c1 = fall_centroid(stats_by_t.get(t))
    c0 = fall_centroid(stats_by_t.get(t - timedelta(hours=lag_h)))
    if c1 is None or c0 is None:
        return None
    mx, my = c1[0] - c0[0], c1[1] - c0[1]
    if math.hypot(mx, my) < 15.0:  # under ~4 km/h of motion is just wobble
        return None
    return (math.degrees(math.atan2(-mx, -my)) + 360.0) % 360.0


def _status(h: HourStats, *, grad_min: float, coh_min: float, fall_min: float) -> str:
    """MIRRORS the gate in app/front.py analyze() — keep in sync by hand."""
    obs_ok = (
        h.n >= front.MIN_RING_STATIONS
        and h.gradient is not None and h.gradient >= grad_min
        and h.coherence is not None and h.coherence >= coh_min
        and h.min_fall is not None and h.min_fall <= fall_min
        and h.falls_bearing is not None
    )
    if not obs_ok:
        return "none"
    if h.own is not None and h.own >= front.RISING_BEHIND:
        return "passed"
    return "approaching"


# ---- ground truth --------------------------------------------------------------


def hourly_series(obs: List[Ob], lon: float,
                  start: datetime, end: datetime) -> Tuple[List[datetime], List[Optional[float]]]:
    """Hourly, gap-aware (<=3 h interpolation), de-tided, 3-pt smoothed."""
    times = [o.t for o in obs]
    vals = [o.slp if o.slp is not None else o.altim for o in obs]
    grid: List[datetime] = []
    raw: List[Optional[float]] = []
    t = start
    while t <= end:
        i = bisect.bisect_left(times, t)
        v = None
        cands = []
        if i < len(times):
            cands.append(i)
        if i > 0:
            cands.append(i - 1)
        if cands:
            j = min(cands, key=lambda k: abs((times[k] - t).total_seconds()))
            if abs((times[j] - t).total_seconds()) <= 1.5 * 3600:
                v = vals[j]
        grid.append(t)
        raw.append(v)
        t += timedelta(hours=1)
    offset = lon / 15.0
    det = [None if v is None else v - tide(g, local_hour_offset=offset)
           for g, v in zip(grid, raw)]
    sm: List[Optional[float]] = []
    for i in range(len(det)):
        window = [det[j] for j in range(max(0, i - 1), min(len(det), i + 2)) if det[j] is not None]
        sm.append(sum(window) / len(window) if window else None)
    return grid, sm


@dataclass
class Trough:
    t: datetime
    depth: float          # fall into the minimum (hPa, de-tided)
    rise: float
    wind_shift: Optional[float]
    frontal: bool


def find_troughs(grid: List[datetime], p: List[Optional[float]],
                 wind_at: dict) -> List[Trough]:
    events: List[Trough] = []
    n = len(grid)
    for i in range(1, n - 1):
        if p[i] is None or p[i - 1] is None or p[i + 1] is None:
            continue
        if not (p[i] <= p[i - 1] and p[i] <= p[i + 1]):
            continue
        prior = [p[j] for j in range(max(0, i - 12), i) if p[j] is not None]
        later = [p[j] for j in range(i + 1, min(n, i + 10)) if p[j] is not None]
        if len(prior) < 6 or len(later) < 4:
            continue
        fall = max(prior) - p[i]
        rise = max(later) - p[i]
        if fall < FALL_MIN or rise < RISE_MIN:
            continue
        shift = wind_shift(grid[i], wind_at)
        events.append(Trough(t=grid[i], depth=round(fall, 2), rise=round(rise, 2),
                             wind_shift=shift,
                             frontal=shift is not None and shift >= WIND_SHIFT_DEG))
    # merge minima within MERGE_H, keep the deepest
    merged: List[Trough] = []
    for e in events:
        if merged and (e.t - merged[-1].t) <= timedelta(hours=MERGE_H):
            if e.depth > merged[-1].depth:
                merged[-1] = e
        else:
            merged.append(e)
    return merged


def wind_shift(t: datetime, wind_at: dict) -> Optional[float]:
    def mean_dir(lo_h: int, hi_h: int) -> Optional[float]:
        us = vs = 0.0
        k = 0
        for h in range(lo_h, hi_h + 1):
            d = wind_at.get(t + timedelta(hours=h))
            if d is None:
                continue
            r = math.radians(d)
            us += math.sin(r)
            vs += math.cos(r)
            k += 1
        if k < 2:
            return None
        return (math.degrees(math.atan2(us, vs)) + 360.0) % 360.0

    before = mean_dir(-4, -1)
    after = mean_dir(1, 4)
    if before is None or after is None:
        return None
    diff = abs(after - before) % 360.0
    return round(min(diff, 360.0 - diff), 1)


# ---- direction ground truth ----------------------------------------------------


def propagation_bearing(trough_t: datetime, stations: dict,
                        hourly: dict) -> Optional[float]:
    """'Coming from' bearing of a trough, from per-station arrival times.

    Each ring station's trough time = its de-tided minimum within +/-10 h of the
    center trough (needing >=1 hPa of local prominence). A plane fit to arrival
    time vs position gives the propagation vector; require a decent fit so mushy
    events don't grade the algorithm against noise.
    """
    pts = []
    for sid, meta in stations.items():
        if sid == CENTER_ID:
            continue
        grid, p = hourly[sid]
        i0 = bisect.bisect_left(grid, trough_t - timedelta(hours=10))
        i1 = bisect.bisect_right(grid, trough_t + timedelta(hours=10))
        window = [(grid[i], p[i]) for i in range(i0, i1) if p[i] is not None]
        if len(window) < 12:
            continue
        tmin, vmin = min(window, key=lambda x: x[1])
        if max(v for _, v in window) - vmin < 1.0:
            continue
        hours_off = (tmin - trough_t).total_seconds() / 3600.0
        pts.append((meta["dx"], meta["dy"], hours_off))
    if len(pts) < 6:
        return None
    fit = front._plane_fit(pts)
    if fit is None:
        return None
    ax, ay, r2 = fit
    if r2 < 0.5 or math.hypot(ax, ay) < 1e-4:
        return None
    # Arrival time increases along the direction of motion; it came FROM -(a).
    return (math.degrees(math.atan2(-ax, -ay)) + 360.0) % 360.0


def ang_err(a: float, b: float) -> float:
    d = abs(a - b) % 360.0
    return min(d, 360.0 - d)


# ---- scoring -------------------------------------------------------------------


def episodes(times: List[datetime], active: List[bool]) -> List[Tuple[datetime, datetime]]:
    eps: List[Tuple[datetime, datetime]] = []
    start = last = None
    for t, a in zip(times, active):
        if a:
            if start is None:
                start = t
            elif (t - last) > timedelta(hours=2):
                eps.append((start, last))
                start = t
            last = t
    if start is not None:
        eps.append((start, last))
    return eps


def evaluate(label: str, hours: List[HourStats], active: List[bool],
             troughs: List[Trough], shallow: List[Trough]) -> dict:
    """Score any boolean warn-signal against the trough lists.

    `shallow` is a looser trough set (smaller fall bar) used only to autopsy the
    false alarms: an episode with no scoreable trough but a shallow one nearby
    warned of real weather that just didn't clear the ground-truth bar.
    """
    times = [h.t for h in hours]
    app_times = [t for t, a in zip(times, active) if a]
    eps = episodes(times, active)

    hits, leads = [], []
    for tr in troughs:
        fires = [t for t in app_times
                 if timedelta(hours=0.5) <= (tr.t - t) <= timedelta(hours=HIT_WINDOW_H)]
        if fires:
            hits.append(tr)
            leads.append((tr.t - min(fires)).total_seconds() / 3600.0)

    false_eps, near_shallow = [], 0
    for start, end in eps:
        if any(timedelta(0) <= (tr.t - start) <= timedelta(hours=FA_WINDOW_H)
               for tr in troughs):
            continue
        false_eps.append((start, end))
        if any(timedelta(0) <= (tr.t - start) <= timedelta(hours=FA_WINDOW_H)
               for tr in shallow):
            near_shallow += 1

    frontal = [tr for tr in troughs if tr.frontal]
    frontal_hits = [tr for tr in hits if tr.frontal]
    valid_hours = sum(1 for h in hours if h.n >= front.MIN_RING_STATIONS)
    return {
        "label": label,
        "troughs": len(troughs), "hits": len(hits),
        "pod": len(hits) / len(troughs) if troughs else 0.0,
        "frontal": len(frontal), "frontal_hits": len(frontal_hits),
        "frontal_pod": len(frontal_hits) / len(frontal) if frontal else 0.0,
        "episodes": len(eps), "false": len(false_eps),
        "far": len(false_eps) / len(eps) if eps else 0.0,
        "false_shallow": near_shallow,
        "lead_med": statistics.median(leads) if leads else None,
        "duty": len(app_times) / valid_hours if valid_hours else 0.0,
        "hit_troughs": hits, "leads": leads, "false_eps": false_eps,
        "active": active,
    }


def gate_signal(hours: List[HourStats], *, grad_min: float, coh_min: float,
                fall_min: float, persist_h: int = 0,
                own_fall_max: Optional[float] = None) -> List[bool]:
    """The production gate as a boolean series, with two candidate refinements:
    `persist_h` demands N consecutive passing hours before warning (kills
    single-hour flicker), `own_fall_max` additionally requires the center's own
    tendency at or below the given value (a front headed here should show at
    least the start of a local fall)."""
    raw = []
    for h in hours:
        ok = _status(h, grad_min=grad_min, coh_min=coh_min, fall_min=fall_min) == "approaching"
        if ok and own_fall_max is not None and (h.own is None or h.own > own_fall_max):
            ok = False
        raw.append(ok)
    if persist_h <= 0:
        return raw
    out = []
    for i, ok in enumerate(raw):
        need = range(max(0, i - persist_h), i + 1)
        out.append(ok and all(raw[j] for j in need))
    return out


def own_signal(hours: List[HourStats], fall_max: float) -> List[bool]:
    """Baseline: the single-station rule the app effectively already has —
    warn whenever the center's own 3h tendency is at or below `fall_max`."""
    return [h.own is not None and h.own <= fall_max for h in hours]


# ---- main ----------------------------------------------------------------------


def main() -> None:
    stations = json.loads((DATA_DIR / "stations.json").read_text())
    cos_lat = math.cos(math.radians(stations[CENTER_ID]["lat"]))
    clat, clon = stations[CENTER_ID]["lat"], stations[CENTER_ID]["lon"]
    for sid, meta in stations.items():
        meta["dx"] = (meta["lon"] - clon) * front.KM_PER_DEG_LAT * cos_lat
        meta["dy"] = (meta["lat"] - clat) * front.KM_PER_DEG_LAT

    series, winds_raw = {}, {}
    for sid in list(stations):
        path = DATA_DIR / f"{sid}.csv"
        if not path.exists():
            del stations[sid]
            continue
        obs, winds = load_station(sid)
        if len(obs) < 4000:  # a station that's mostly missing would skew the ring
            print(f"  dropping {sid}: only {len(obs)} obs")
            del stations[sid]
            continue
        series[sid] = obs
        winds_raw[sid] = winds
    print(f"{len(stations)} stations loaded")

    times_idx = {sid: [o.t for o in obs] for sid, obs in series.items()}
    start = min(t[0] for t in times_idx.values()) + timedelta(hours=6)
    end = max(t[-1] for t in times_idx.values())
    hours = []
    t = start.replace(minute=0, second=0, microsecond=0)
    while t <= end:
        hours.append(t)
        t += timedelta(hours=1)

    print(f"replaying {len(hours)} hours: {hours[0]:%Y-%m-%d} .. {hours[-1]:%Y-%m-%d}")
    stats = field_stats(stations, series, times_idx, hours)

    # ground truth at the center
    center_obs = series[CENTER_ID]
    grid, p = hourly_series(center_obs, clon, hours[0], hours[-1])
    wind_at = {o.t.replace(minute=0, second=0): w
               for o, w in zip(center_obs, winds_raw[CENTER_ID]) if w is not None}
    troughs = find_troughs(grid, p, wind_at)
    # A looser trough set for the false-alarm autopsy: weather that was real
    # but didn't clear the scoring bar.
    global FALL_MIN
    strict_fall = FALL_MIN
    FALL_MIN = 1.2
    shallow = find_troughs(grid, p, wind_at)
    FALL_MIN = strict_fall
    print(f"{len(troughs)} ground-truth troughs "
          f"({sum(1 for tr in troughs if tr.frontal)} with a frontal wind shift); "
          f"{len(shallow)} at the shallow bar\n")

    def fmt(r: dict) -> str:
        lead = f"{r['lead_med']:.1f}h" if r["lead_med"] is not None else "—"
        return (f"{r['label']:<34} | POD {r['hits']:>3}/{r['troughs']} = {r['pod']:.0%}  "
                f"frontal {r['frontal_hits']:>2}/{r['frontal']} = {r['frontal_pod']:.0%}  "
                f"FAR {r['false']:>3}/{r['episodes']:<3} = {r['far']:.0%} "
                f"(shallow {r['false_shallow']})  lead {lead}  duty {r['duty']:.1%}")

    def run(label, **kw):
        return evaluate(label, stats, gate_signal(stats, **kw), troughs, shallow)

    prod = run("production g.5 c.3 f-1.0",
               grad_min=front.MIN_GRADIENT, coh_min=front.MIN_COHERENCE,
               fall_min=front.MIN_FALL)

    print("=== production vs single-station baselines ===")
    print(fmt(prod))
    for fm in (-0.5, -1.0, -1.5):
        b = evaluate(f"baseline own<={fm}", stats, own_signal(stats, fm),
                     troughs, shallow)
        print(fmt(b))
    print()

    print("=== refinements on production gate ===")
    print(fmt(run("  +persist 2h", grad_min=0.5, coh_min=0.3, fall_min=-1.0,
                  persist_h=2)))
    print(fmt(run("  +own falling (<= -0.3)", grad_min=0.5, coh_min=0.3,
                  fall_min=-1.0, own_fall_max=-0.3)))
    print(fmt(run("  +persist 2h +own falling", grad_min=0.5, coh_min=0.3,
                  fall_min=-1.0, persist_h=2, own_fall_max=-0.3)))
    print()

    print("=== threshold sweep (gradient x coherence x min-fall) ===")
    for g in (0.3, 0.5, 0.8):
        for c in (0.20, 0.30, 0.45):
            for f in (-1.0, -1.5):
                print(fmt(run(f"g{g} c{c} f{f}", grad_min=g, coh_min=c, fall_min=f)))
        print()

    print("=== sweep with persist 2h + own falling ===")
    for g in (0.3, 0.5, 0.8):
        for f in (-1.0, -1.5):
            print(fmt(run(f"g{g} c0.3 f{f} +p2 +own", grad_min=g, coh_min=0.3,
                          fall_min=f, persist_h=2, own_fall_max=-0.3)))
    print()

    # direction check on production hits, at first and last fire before each trough
    hourly_all = {sid: hourly_series(series[sid], stations[sid]["lon"],
                                     hours[0], hours[-1])
                  for sid in stations}
    active_by_t = {h.t: a for h, a in zip(stats, prod["active"])}
    bearing_by_t = {h.t: h.falls_bearing for h in stats}
    stats_by_t = {h.t: h for h in stats}
    first_errs, last_errs, cent_first, cent_last = [], [], [], []
    for tr in prod["hit_troughs"]:
        truth = propagation_bearing(tr.t, stations, hourly_all)
        if truth is None:
            continue
        fires = [tr.t - timedelta(hours=k) for k in range(1, HIT_WINDOW_H + 1)]
        fires = [t for t in fires if active_by_t.get(t)
                 and bearing_by_t.get(t) is not None]
        if not fires:
            continue
        first, last = min(fires), max(fires)
        first_errs.append(ang_err(bearing_by_t[first], truth))
        last_errs.append(ang_err(bearing_by_t[last], truth))
        cf = centroid_bearing(first, stats_by_t)
        cl = centroid_bearing(last, stats_by_t)
        if cf is not None:
            cent_first.append(ang_err(cf, truth))
        if cl is not None:
            cent_last.append(ang_err(cl, truth))

    print("=== direction (production hits with a scoreable propagation fit) ===")
    for name, errs in (("gradient @ first fire", first_errs),
                       ("gradient @ last fire", last_errs),
                       ("centroid-track @ first fire", cent_first),
                       ("centroid-track @ last fire", cent_last)):
        if errs:
            print(f"  {name}: median error {statistics.median(errs):.0f} deg, "
                  f"within 45 deg {sum(1 for e in errs if e <= 45)}/{len(errs)}, "
                  f"within 90 deg {sum(1 for e in errs if e <= 90)}/{len(errs)}")
    print()

    # Candidate observational ETA: time for the fall centroid to close on the
    # center at its tracked speed. Evaluated at every approaching hour in the
    # 12 h before each hit trough (signed error: negative = predicted early).
    eta_errs = []
    for tr in prod["hit_troughs"]:
        for k in range(1, HIT_WINDOW_H + 1):
            t = tr.t - timedelta(hours=k)
            if not active_by_t.get(t):
                continue
            c1 = fall_centroid(stats_by_t.get(t))
            c0 = fall_centroid(stats_by_t.get(t - timedelta(hours=4)))
            if c1 is None or c0 is None:
                continue
            mx, my = c1[0] - c0[0], c1[1] - c0[1]
            speed = math.hypot(mx, my) / 4.0  # km/h
            if speed < 8.0:
                continue
            closing = -(c1[0] * mx + c1[1] * my) / (4.0 * speed)  # km/h toward us
            if closing < 5.0:
                continue
            pred = math.hypot(*c1) / closing
            eta_errs.append(pred - k)
    if eta_errs:
        print("=== observational ETA (fall-centroid closing speed, all pre-trough fires) ===")
        print(f"  n={len(eta_errs)}  median signed error {statistics.median(eta_errs):+.1f} h  "
              f"median |error| {statistics.median([abs(e) for e in eta_errs]):.1f} h  "
              f"within 3 h: {sum(1 for e in eta_errs if abs(e) <= 3)}/{len(eta_errs)}")
        print()

    # per-event table for the production run — the "would it have helped" list
    print("=== ground-truth troughs (production run) ===")
    hit_ts = {tr.t for tr in prod["hit_troughs"]}
    for tr in troughs:
        mark = "HIT " if tr.t in hit_ts else "MISS"
        shift = f"{tr.wind_shift:.0f}deg" if tr.wind_shift is not None else "  — "
        kind = "frontal" if tr.frontal else "       "
        print(f"  {mark} {tr.t:%Y-%m-%d %H:%M}Z  fall {tr.depth:>4.1f}  "
              f"rise {tr.rise:>4.1f}  shift {shift:>6} {kind}")


if __name__ == "__main__":
    main()
