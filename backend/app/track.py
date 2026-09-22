"""Verdict track record (C5 + D6): Barry keeps its own trend calls per
station and scores each one against what the pressure then did.

A call is "right" when the direction it named (falling / rising / steady)
matches the observed change over the following 3 h, using the same ±0.5 hPa
bands the tendency table draws its lines at. Calls are scored once they are
old enough to have an answer; the log is pruned to 30 days. Pure functions
over plain dicts so they persist as-is and test without I/O.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import Dict, List, Optional, Sequence, Tuple

from .models import SeriesPoint, TrackRecordOut

RECORD_EVERY_MIN = 30.0     # one call logged per station per half hour
SCORE_AFTER_H = 3.0         # the horizon the call was about
SCORE_WINDOW_H = 1.5        # tolerance for finding a report near t+3h
KEEP_DAYS = 30
MIN_CALLS = 5               # below this, say nothing
BAND = 0.5                  # hPa: |d| < BAND is "steady"

FALLING = {"falling", "falling_mod", "falling_fast"}
RISING = {"rising", "rising_fast"}


def _direction(trend: str) -> str:
    if trend in FALLING:
        return "falling"
    if trend in RISING:
        return "rising"
    return "steady"


def _pressure_at(series: Sequence[SeriesPoint], t: datetime, tol_h: float) -> Optional[float]:
    best = None
    for p in series:
        v = p.slp if p.slp is not None else p.altim
        if v is None:
            continue
        dt = abs((p.t - t).total_seconds()) / 3600.0
        if dt <= tol_h and (best is None or dt < best[0]):
            best = (dt, v)
    return best[1] if best else None


def record(log: List[dict], now: datetime, trend: str, confidence: float) -> List[dict]:
    """Append a call unless one was logged within RECORD_EVERY_MIN; prune."""
    cutoff = now - timedelta(days=KEEP_DAYS)
    log = [r for r in log if r["t"] >= cutoff]
    if log and (now - log[-1]["t"]).total_seconds() < RECORD_EVERY_MIN * 60:
        return log
    log.append({"t": now, "trend": trend, "dir": _direction(trend),
                "confidence": confidence, "right": None})
    return log


def score(log: List[dict], series: Sequence[SeriesPoint], now: datetime) -> List[dict]:
    """Score every unscored call that is old enough, from the station's own
    series (the same 24 h history /combined already carries)."""
    for r in log:
        if r["right"] is not None:
            continue
        t0 = r["t"]
        if now - t0 < timedelta(hours=SCORE_AFTER_H + 0.5):
            continue
        p0 = _pressure_at(series, t0, SCORE_WINDOW_H)
        p1 = _pressure_at(series, t0 + timedelta(hours=SCORE_AFTER_H), SCORE_WINDOW_H)
        if p0 is None or p1 is None:
            # Old enough that the answer will never arrive: drop it rather
            # than count it either way.
            if now - t0 > timedelta(hours=24):
                r["right"] = "unknown"
            continue
        d = p1 - p0
        actual = "falling" if d <= -BAND else ("rising" if d >= BAND else "steady")
        r["right"] = actual == r["dir"]
        r["actual"] = actual
    return log


MAX_STATIONS = 2000         # the registry's cap; nobody scores more fields than that


def prune_all(logs: Dict[str, List[dict]], now: datetime) -> bool:
    """Drop calls older than KEEP_DAYS from every station, stations left
    with nothing, and beyond MAX_STATIONS the ones least recently called.
    Returns whether anything changed."""
    cutoff = now - timedelta(days=KEEP_DAYS)
    changed = False
    for sid in list(logs):
        kept = [r for r in logs[sid] if r["t"] >= cutoff]
        if len(kept) != len(logs[sid]):
            changed = True
            if kept:
                logs[sid] = kept
            else:
                del logs[sid]
    if len(logs) > MAX_STATIONS:
        by_last = sorted(logs, key=lambda sid: logs[sid][-1]["t"])
        for sid in by_last[: len(logs) - MAX_STATIONS]:
            del logs[sid]
        changed = True
    return changed


def summary(log: List[dict], days: int = KEEP_DAYS) -> Optional[TrackRecordOut]:
    scored = [r for r in log if r["right"] in (True, False)]
    if len(scored) < MIN_CALLS:
        return None
    right = sum(1 for r in scored if r["right"] is True)
    return TrackRecordOut(right=right, total=len(scored), days=days)
