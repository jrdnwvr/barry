"""C5/D6: the verdict track record."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app import track
from app.models import SeriesPoint
from app.service import PressureService

T0 = datetime(2026, 9, 15, 12, 0, tzinfo=timezone.utc)


def series(deltas_per_hour, start=T0 - timedelta(hours=6), hours=24, p0=1015.0):
    pts, p = [], p0
    for h in range(hours):
        pts.append(SeriesPoint(t=start + timedelta(hours=h), slp=round(p, 1)))
        p += deltas_per_hour(h)
    return pts


def test_record_rate_limits_and_prunes():
    log = track.record([], T0, "falling", 0.9)
    log = track.record(log, T0 + timedelta(minutes=10), "falling", 0.9)     # too soon
    log = track.record(log, T0 + timedelta(minutes=40), "rising", 0.9)
    assert [r["dir"] for r in log] == ["falling", "rising"]
    old = {"t": T0 - timedelta(days=31), "trend": "steady", "dir": "steady", "confidence": 1, "right": True}
    log = track.record([old] + log, T0 + timedelta(hours=2), "steady", 1.0)
    assert old not in log


def test_scoring_matches_direction_bands():
    falling = series(lambda h: -0.4)                    # -1.2 hPa / 3 h
    log = [{"t": T0, "trend": "falling_mod", "dir": "falling", "confidence": 1, "right": None},
           {"t": T0, "trend": "rising", "dir": "rising", "confidence": 1, "right": None},
           {"t": T0 + timedelta(hours=2), "trend": "steady", "dir": "steady", "confidence": 1, "right": None}]
    log = track.score(log, falling, T0 + timedelta(hours=4))
    assert log[0]["right"] is True and log[0]["actual"] == "falling"
    assert log[1]["right"] is False
    assert log[2]["right"] is None                      # not old enough yet
    flat = series(lambda h: 0.1)                        # +0.3 / 3 h = steady
    log2 = track.score([{"t": T0, "trend": "steady", "dir": "steady", "confidence": 1, "right": None}],
                       flat, T0 + timedelta(hours=4))
    assert log2[0]["right"] is True


def test_summary_needs_enough_calls_and_ignores_unknowns():
    log = [{"t": T0, "trend": "", "dir": "", "confidence": 1, "right": v}
           for v in (True, True, False, True, "unknown", None)]
    assert track.summary(log) is None                   # 4 scored < 5
    log.append({"t": T0, "trend": "", "dir": "", "confidence": 1, "right": True})
    out = track.summary(log)
    assert (out.right, out.total, out.days) == (4, 5, 30)


@pytest.mark.asyncio
async def test_combined_logs_and_persists(client, tmp_path, monkeypatch):
    monkeypatch.setenv("BARRY_DATA_DIR", str(tmp_path))
    service = PressureService(client)
    combined = await service.get_combined("KLUK")
    assert combined.trackRecord is None                 # first call ever
    assert len(service._track_log["KLUK"]) == 1
    assert (tmp_path / "track_log.pkl").exists()
    again = PressureService(client)                     # restart
    assert len(again._track_log["KLUK"]) == 1
