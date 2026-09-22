"""The health check can fail, and fails for the right reasons."""
import asyncio
from datetime import timedelta

import httpx
import pytest

from app.scheduler import Scheduler
from app.service import PressureService, _now


@pytest.mark.asyncio
async def test_a_fresh_start_is_healthy_and_a_dead_loop_is_not(client, upstream, monkeypatch):
    monkeypatch.setenv("BARRY_GLM", "0")
    s = PressureService(client)
    sched = Scheduler(s, interval_seconds=600)
    assert sched.problems(_now())[0] == ["scheduler not started"]
    sched.start()
    try:
        await asyncio.sleep(0)                         # let the first cycle begin
        dead, stale = sched.problems(_now())
        assert dead == [] and stale == []
        # Twenty minutes and the bulk table never came: degraded, not dead.
        dead, stale = sched.problems(_now() + timedelta(minutes=21))
        assert dead == [] and stale == ["bulk metar table missing"]
        # Half an hour without a cycle finishing: the loop is stuck.
        dead, _ = sched.problems(_now() + timedelta(minutes=31))
        assert dead == ["refresh loop stalled"]
    finally:
        await sched.stop()
    assert "refresh loop exited" in sched.problems(_now())[0]


@pytest.mark.asyncio
async def test_healthz_reports_the_process_and_the_data_separately(client, upstream, monkeypatch):
    from app.main import app
    monkeypatch.setenv("BARRY_GLM", "0")
    s = PressureService(client)
    sched = Scheduler(s, interval_seconds=600)
    app.state.service, app.state.scheduler = s, sched
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        r = await c.get("/healthz")
        assert r.status_code == 503 and r.json()["status"] == "unhealthy"
        sched.start()
        try:
            await sched.refresh_once()
            r = await c.get("/healthz")
            assert r.status_code == 200 and r.json()["status"] == "ok"
            assert r.json()["bulk_ok_at"] is not None
            # The bulk table goes silent: still 200 for the container, 503 for a strict monitor.
            s.bulk_ok_at = _now() - timedelta(hours=1)
            r = await c.get("/healthz")
            assert r.status_code == 200 and r.json()["status"] == "degraded"
            assert r.json()["problems"] == ["bulk metar table missing"]
            r = await c.get("/healthz?strict=1")
            assert r.status_code == 503
        finally:
            await sched.stop()
        r = await c.get("/healthz")
        assert r.status_code == 503 and "refresh loop exited" in r.json()["problems"]


@pytest.mark.asyncio
async def test_scheduler_owns_the_bulk_refresh_and_the_track_log(client, upstream, tmp_path, monkeypatch):
    monkeypatch.setenv("BARRY_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("BARRY_GLM", "0")
    s = PressureService(client)
    sched = Scheduler(s, interval_seconds=600)
    await sched.refresh_once()
    await s.metar_bulk()                                  # fresh: served from cache
    n = upstream.bulk_calls
    await sched.refresh_once()                            # the scheduler always pulls
    assert upstream.bulk_calls == n + 1
    await s.get_combined("KLUK")
    assert not (tmp_path / "track_log.json.gz").exists()
    await sched.refresh_once()
    assert (tmp_path / "track_log.json.gz").exists()


def test_track_log_prunes_old_calls_and_caps_stations():
    from app import track
    now = _now()
    logs = {"KOLD": [{"t": now - timedelta(days=40), "trend": "steady", "dir": "steady", "confidence": 1, "right": None}],
            "KLUK": [{"t": now - timedelta(days=40), "trend": "steady", "dir": "steady", "confidence": 1, "right": None},
                     {"t": now, "trend": "steady", "dir": "steady", "confidence": 1, "right": None}]}
    assert track.prune_all(logs, now)
    assert set(logs) == {"KLUK"} and len(logs["KLUK"]) == 1
    assert not track.prune_all(logs, now)
    many = {f"K{i:03d}": [{"t": now - timedelta(minutes=i), "trend": "steady", "dir": "steady", "confidence": 1, "right": None}]
            for i in range(track.MAX_STATIONS + 5)}
    assert track.prune_all(many, now)
    assert len(many) == track.MAX_STATIONS and "K000" in many and "K2004" not in many
