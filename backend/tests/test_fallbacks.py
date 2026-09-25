"""Every answer from a fallback instead of the NOAA feeds is logged with
why and where, summed by day on /fallbacks, and survives a restart."""
from datetime import datetime, timedelta, timezone

import httpx
import pytest

from app import fallbacks
from app.service import PressureService

NOW = datetime(2026, 9, 25, 3, 10, tzinfo=timezone.utc)


@pytest.fixture
def noaa_on(monkeypatch, upstream):
    monkeypatch.setenv("BARRY_HRRR", "1")
    monkeypatch.setenv("BARRY_MRMS", "1")
    monkeypatch.setattr("app.service._now", lambda: NOW)
    upstream.clock = lambda: NOW


@pytest.mark.asyncio
async def test_every_fallback_is_logged_with_its_reason_and_place(client, upstream, noaa_on, monkeypatch):
    from app.main import app
    s = PressureService(client)
    # Before any run is held there is nothing to serve.
    assert (await s.get_forecast(39.1, -84.5)).source == "open-meteo"
    await s.poll_hrrr()
    assert (await s.get_field_grid(39.1, -84.5, 3.0, 5.0)).source == "hrrr"   # from the store: no event
    # Off the fixture grid, every point route falls back, and says so.
    assert (await s.get_forecast(45.0, -120.0)).source == "open-meteo"
    assert (await s.get_field_grid(45.0, -120.0, 3.0, 5.0)).source == "open-meteo"
    with pytest.raises(LookupError):                     # logged before Open-Meteo answers with nothing
        await s.get_field_levels(45.0, -120.0, 3.0, 5.0)
    assert (await s.get_aloft(45.0, -120.0)).source == "open-meteo"
    # No MRMS frames yet, then frames that have gone stale.
    assert (await s.get_radar_frames()).host == "https://tilecache.rainviewer.com"
    await s.poll_radar()
    assert (await s.get_radar_frames()).host == "https://barry.wide-stack.com"
    monkeypatch.setattr("app.service._now", lambda: NOW + timedelta(minutes=45))
    assert (await s.get_radar_frames()).host == "https://tilecache.rainviewer.com"
    # AWC down: the observed curve from Open-Meteo's surface pressure.
    upstream.awc_fail = True
    assert (await s.get_pressure("KLUK")).source == "open-meteo (fallback)"

    seen = {(e["kind"], e["reason"], e["where"]) for e in s.fallbacks.events()}
    assert ("forecast", "no-data", "39.1,-84.5") in seen
    assert ("forecast", "off-grid", "45.0,-120.0") in seen
    assert ("field", "off-grid", "45.0,-120.0") in seen
    assert ("levels", "off-grid", "45.0,-120.0") in seen
    assert ("aloft", "off-grid", "45.0,-120.0") in seen
    assert ("radar", "no-data", "radar") in seen and ("radar", "stale", "radar") in seen
    assert ("pressure", "upstream", "KLUK") in seen
    assert not any(w == "39.1,-84.5" and (k, r) != ("forecast", "no-data") for k, r, w in seen)

    # The same fallback again within ten minutes is one event, not two.
    n = len(s.fallbacks.events())
    monkeypatch.setattr("app.service._now", lambda: NOW + timedelta(minutes=5))
    await s.get_field_grid(45.0, -120.0, 3.0, 5.0)
    assert len(s.fallbacks.events()) == n

    # The route sums it by day and lists the newest first.
    app.state.service = s
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        r = await c.get("/fallbacks?days=3")
    assert r.status_code == 200
    body = r.json()
    day = body["days"][0]
    assert day["day"] == "2026-09-25" and day["events"] == n
    assert day["byKind"]["forecast"] == {"no-data": 1, "off-grid": 1}
    assert day["byKind"]["radar"] == {"no-data": 1, "stale": 1}
    assert body["recent"][0]["t"] >= body["recent"][-1]["t"] and body["total"] == n


def test_the_log_survives_a_restart_and_forgets_old_events(tmp_path, monkeypatch):
    monkeypatch.setenv("BARRY_DATA_DIR", str(tmp_path))
    log = fallbacks.Log()
    assert log.note("radar", "stale", "radar", NOW)
    assert not log.note("radar", "stale", "radar", NOW + timedelta(minutes=5))
    assert log.note("radar", "stale", "radar", NOW + timedelta(minutes=11))
    assert log.flush(NOW + timedelta(minutes=11))
    again = fallbacks.Log()
    assert [e["t"] for e in again.events()] == [NOW.isoformat(), (NOW + timedelta(minutes=11)).isoformat()]
    assert again.summary(1, NOW)["days"][0]["byKind"] == {"radar": {"stale": 2}}
    assert again.flush(NOW + timedelta(days=61)) and again.events() == []
    assert fallbacks.Log().events() == []
