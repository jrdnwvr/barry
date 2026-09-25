"""LAMP station guidance: the bulletin parser, the poll, and where it shows."""
import os
from datetime import datetime, timedelta, timezone

import pytest

from app.scheduler import Scheduler
from app.service import PressureService, _now
from app.sources import lamp

FIXTURE = os.path.join(os.path.dirname(__file__), "fixtures", "lamp_lav.txt")


def test_the_bulletin_reads_by_column():
    with open(FIXTURE, encoding="utf-8") as fh:
        table = lamp.parse(fh.read())
    assert set(table) == {"KLUK", "KI69", "KDAY", "KCVG"}
    k = table["KLUK"]
    assert k.runTime == datetime(2026, 9, 24, 21, 30, tzinfo=timezone.utc)
    assert len(k.hours) == 25
    first = k.hours[0]
    # 22 UTC: CIG 5 (2,000 to 3,000 ft) makes it MVFR; wind 050 at 7.
    assert first.t == datetime(2026, 9, 24, 22, tzinfo=timezone.utc)
    assert (first.fltCat, first.cigFt, first.visSM) == ("MVFR", 2500, 10.0)
    assert (first.windDir, first.windKt, first.gustKt) == (50.0, 7.0, None)
    assert first.cloud == "OV" and first.obv is None
    # The hours cross midnight into the next day.
    assert k.hours[2].t == datetime(2026, 9, 25, 0, tzinfo=timezone.utc)
    assert k.hours[-1].t == datetime(2026, 9, 25, 22, tzinfo=timezone.utc)
    # Fog at 11 UTC with visibility 3 to 5 miles: MVFR by visibility alone.
    fog = next(h for h in k.hours if h.t.hour == 11)
    assert fog.obv == "FG" and fog.fltCat == "MVFR"


def test_a_field_with_no_taf_has_guidance_and_short_rows_are_fine():
    with open(FIXTURE, encoding="utf-8") as fh:
        table = lamp.parse(fh.read())
    k = table["KI69"]                 # no TAF, no CLD, TYP or OBV rows
    assert len(k.hours) == 25 and all(h.cloud is None for h in k.hours)
    assert k.hours[0].fltCat == "MVFR" and k.hours[3].fltCat == "VFR"


@pytest.mark.parametrize("cig,vis,cat", [
    (8, 7, "VFR"), (6, 6, "VFR"), (5, 7, "MVFR"), (8, 5, "MVFR"), (4, 7, "MVFR"),
    (3, 7, "IFR"), (8, 4, "IFR"), (8, 3, "IFR"), (2, 7, "LIFR"), (8, 2, "LIFR"),
    (1, 1, "LIFR"), (None, None, None), (None, 7, "VFR"),
])
def test_flight_category_from_the_bands(cig, vis, cat):
    assert lamp.flight_category(cig, vis) == cat


def test_the_run_waits_eight_minutes_past_the_half_hour():
    at = lambda h, m: datetime(2026, 9, 24, h, m, tzinfo=timezone.utc)
    assert lamp.run_for(at(21, 38)) == at(21, 30)
    assert lamp.run_for(at(21, 37)) == at(20, 30)
    assert lamp.run_for(at(0, 10)) == datetime(2026, 9, 23, 23, 30, tzinfo=timezone.utc)
    assert lamp.bulletin_path(at(21, 30)) == "lmp/prod/lmp.20260924/lmp.t2130z.lavtxt.ascii"


@pytest.mark.asyncio
async def test_poll_pulls_each_run_once_and_falls_back_an_hour_on_a_cold_start(client, upstream):
    s = PressureService(client)
    run = lamp.run_for(_now())
    upstream.lamp_missing = {run}
    assert await s.poll_lamp() == 4
    assert s.lamp_run == run - timedelta(hours=1)
    assert len(upstream.nomads_calls) == 2
    upstream.lamp_missing = set()
    assert await s.poll_lamp() == 4 and s.lamp_run == run
    assert await s.poll_lamp() == 0                       # held: no request
    assert len(upstream.nomads_calls) == 3


@pytest.mark.asyncio
async def test_combined_carries_lamp_from_this_hour_on(client, upstream):
    s = PressureService(client)
    await s.poll_lamp()
    c = await s.get_combined("KLUK", tz_minutes=-240)
    assert c.lamp is not None and c.lamp.station == "KLUK"
    start = _now().replace(minute=0, second=0, microsecond=0)
    assert all(h.t >= start for h in c.lamp.hours) and c.lamp.hours
    assert (await s.get_combined("KILN")).lamp is None      # a site LAMP doesn't cover


@pytest.mark.asyncio
async def test_old_guidance_is_not_served(client, upstream, monkeypatch):
    s = PressureService(client)
    await s.poll_lamp()
    later = _now() + timedelta(hours=7)
    monkeypatch.setattr("app.service._now", lambda: later)
    assert s.get_lamp("KLUK") is None


@pytest.mark.asyncio
async def test_the_route_arrives_by_lamp_where_there_is_no_taf(client, upstream):
    s = PressureService(client)
    await s.poll_lamp()
    r = await s.get_route("KLUK", "KI69", speed_kt=100)
    assert r.hasTaf is False and r.arriveSource == "lamp" and r.arriveCat in ("VFR", "MVFR", "IFR", "LIFR")
    r = await s.get_route("KI69", "KLUK", speed_kt=100)
    assert r.hasTaf is True and r.arriveSource == "taf"


@pytest.mark.asyncio
async def test_the_scheduler_keeps_lamp_and_health_reports_it(client, upstream, monkeypatch):
    monkeypatch.setenv("BARRY_GLM", "0")
    s = PressureService(client)
    sched = Scheduler(s, interval_seconds=600)
    sched.start()
    try:
        for _ in range(50):
            if s.lamp_run is not None:
                break
            import asyncio
            await asyncio.sleep(0.01)
        assert s.lamp_run is not None
        assert sched.problems(_now()) == ([], [])
        dead, stale = sched.problems(_now() + timedelta(hours=4))
        assert "lamp guidance stale" in stale
    finally:
        await sched.stop()
    assert "lamp loop exited" in sched.problems(_now())[0]
