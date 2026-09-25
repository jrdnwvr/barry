"""HRRR from the bucket: index files, the Lambert grid, the pull into the
model store, and the map layers served from it."""
import os
from datetime import datetime, timedelta, timezone

import numpy as np
import pytest

from app import grib
from app.modelstore import ModelStore
from app.scheduler import Scheduler
from app.service import PressureService
from app.sources import hrrr

FIX = os.path.join(os.path.dirname(__file__), "fixtures")
NOW = datetime(2026, 9, 25, 3, 10, tzinfo=timezone.utc)      # expected cycle 02z
CYCLE = datetime(2026, 9, 25, 2, tzinfo=timezone.utc)
# The middle of the Ohio valley grid, and a box around it.
LAT, LON = 38.4, -84.4


def _centre(points):
    return min(points, key=lambda p: (p.lat - LAT) ** 2 + (p.lon - LON) ** 2)


@pytest.fixture
def hrrr_on(monkeypatch):
    monkeypatch.setenv("BARRY_HRRR", "1")
    monkeypatch.setattr("app.service._now", lambda: NOW)


def test_index_ranges_and_merging():
    with open(os.path.join(FIX, "hrrr_sfc.grib2.idx")) as fh:
        entries = grib.parse_idx(fh.read())
    assert [e.name for e in entries][:3] == ["ABSV", "UGRD", "VGRD"]
    r = grib.byte_ranges(entries, [("UGRD", "10 m above ground"), ("MSLMA", "mean sea level")])
    assert r[("UGRD", "10 m above ground")] == (entries[1].offset, entries[2].offset - 1)
    r = grib.byte_ranges(entries, [("PRATE", "surface")])
    assert r[("PRATE", "surface")][1] is None                  # the last message runs to the end
    merged = grib.merge_ranges([(0, 9), (10, 19), (40, 49), (50, None)])
    assert merged == [(0, 19), (40, None)]
    assert grib.merge_ranges([(0, 9), (15, 19)], gap=10) == [(0, 19)]


def test_the_hrrr_grid_round_trips_and_starts_where_ncep_says():
    g = grib.LambertGrid(1799, 1059, 21.138123, 237.280472, 262.5, 38.5, 38.5, 3000, 3000)
    i, j = g.ij(21.138123, 237.280472 - 360)
    assert abs(i) < 1e-6 and abs(j) < 1e-6
    lat, lon = g.latlon(1798, 1058)
    assert abs(lat - 47.8423) < 1e-3 and abs(lon - -60.9178) < 1e-3   # HRRR's last point
    i, j = g.ij(39.1, -84.42)
    lat, lon = g.latlon(i, j)
    assert abs(lat - 39.1) < 1e-9 and abs(lon - -84.42) < 1e-9
    # Grid north is east of true north east of LoV, west of it to the west.
    assert g.rotation(-80.0) > 0 > g.rotation(-110.0)


def test_split_messages_follows_the_length_fields():
    with open(os.path.join(FIX, "hrrr_prs.grib2"), "rb") as fh:
        data = fh.read()
    assert len(grib.split_messages(data)) == 120


@pytest.mark.asyncio
async def test_the_map_feed_is_pulled_by_range(client, upstream):
    store = ModelStore(None)
    n = await hrrr.pull(client, store, hrrr.MAP, CYCLE)
    assert n == len(hrrr.FIELDS) * len(hrrr.FHRS)
    gets = [c for c in upstream.hrrr_calls if c[1] == "GET" and not c[2].endswith(".idx")]
    # Per hour: the surface fields sit together after the unwanted first
    # message (one request), the pressure ones likewise.
    assert all(c[0] == "aws" and c[3] for c in gets) and len(gets) == 2 * len(hrrr.FHRS)
    assert store.cycles("hrrr") == [CYCLE]
    assert store.load("hrrr", CYCLE, 1, "u10").dtype == np.float32


@pytest.mark.asyncio
async def test_a_cycle_is_pulled_and_the_winds_come_out_earth_relative(client, upstream, hrrr_on):
    s = PressureService(client)
    assert await s.poll_hrrr() > 0
    assert s.models.cycles("hrrr") == [CYCLE]
    assert s.models.cycles("hrrr-col") == [CYCLE]
    assert s.models.cycles("hrrr-colx") == [datetime(2026, 9, 25, 0, tzinfo=timezone.utc)]
    assert max(s.models.hours("hrrr-colx", datetime(2026, 9, 25, 0, tzinfo=timezone.utc))) == 3
    resp = await s.get_field_grid(LAT, LON, 3.0, 5.0)
    assert resp.source == "hrrr" and len(resp.points) == s.HRRR_COLS * s.HRRR_ROWS
    p = _centre(resp.points)
    assert abs(p.windDeg - 270) <= 1 and abs(p.windKmh - 36.0) < 0.5
    assert p.blM == 900 and p.capeJkg == 500
    # Held: the next pass asks for indexes and pulls nothing.
    before = len(upstream.hrrr_calls)
    assert await s.poll_hrrr() == 0
    assert all(c[1] == "HEAD" for c in upstream.hrrr_calls[before:])


@pytest.mark.asyncio
async def test_the_aloft_column_comes_from_the_column_feeds(client, upstream, hrrr_on, monkeypatch):
    monkeypatch.setattr("app.sources.hrrr.EXTENDED_LAST", 30)
    s = PressureService(client)
    await s.poll_hrrr()
    a = await s.get_aloft(LAT, LON)
    assert a.source == "hrrr" and len(a.hours) == 25
    assert a.hours[0].t == datetime(2026, 9, 25, 3, tzinfo=timezone.utc)
    h = a.hours[0]
    lv = {l.hPa: l for l in h.levels}
    assert 1000 not in lv and 975 in lv                        # 1000 hPa is under the 200 m ground
    assert abs(lv[850].tempC - 5.2) < 0.2 and abs(lv[850].spdKt - 29.2) < 0.3 and lv[850].dirDeg == 250
    assert lv[850].cloudPct == 80 and lv[700].cloudPct == 0 and lv[700].dewC is not None
    assert [c.baseFt for c in h.clouds] == [lv[850].ft]
    assert abs(h.surface.tempC - 16.85) < 0.06 and abs(h.surface.dewC - 9.85) < 0.06 and h.surface.dirDeg == 270
    assert h.freezingFt == 7572 and h.blAglFt == 2953
    # The west third stands at 1,600 m: nothing below it.
    west = await s.get_aloft(LAT, -87.3)
    assert min(l.ft for l in west.hours[0].levels) > 1600 * 3.28


@pytest.mark.asyncio
async def test_the_column_falls_back_off_the_grid(client, upstream, hrrr_on):
    s = PressureService(client)
    await s.poll_hrrr()
    assert (await s.get_aloft(45.0, -120.0)).source == "open-meteo"


@pytest.mark.asyncio
async def test_winds_aloft_from_the_store(client, upstream, hrrr_on):
    s = PressureService(client)
    await s.poll_hrrr()
    resp = await s.get_field_levels(LAT, LON, 3.0, 5.0)
    assert resp.source == "hrrr"
    lv = {l.hPa: l for l in _centre(resp.points).levels}
    assert set(lv) == {925, 850, 700, 600, 500}
    assert abs(lv[850].windDeg - 250) <= 1 and abs(lv[850].windKmh - 54.0) < 0.5
    assert abs(lv[500].windKmh - 108.0) < 0.5
    # West of 86 W the ground stands above 850 hPa: those levels are left out there.
    west = [p for p in resp.points if p.lon < -86.1]
    assert west and all({l.hPa for l in p.levels} == {700, 600, 500} for p in west)


@pytest.mark.asyncio
async def test_height_contours_run_east_and_west_at_chart_intervals(client, upstream, hrrr_on):
    s = PressureService(client)
    await s.poll_hrrr()
    h = await s.get_heights(LAT, LON, 2.0, 4.0, 850)
    assert h.intervalM == 30 and h.lines and h.run == CYCLE
    assert h.validTime == CYCLE + timedelta(hours=1)
    for line in h.lines:
        assert line.level % 30 == 0
        lats = [p[0] for p in line.points]
        assert max(lats) - min(lats) < 0.1                     # heights vary with latitude only
        # 1,500 m at 38.5 N, 60 m less per degree north.
        assert abs(np.mean(lats) - (38.5 + (1500 - line.level) / 60)) < 0.05
    assert (await s.get_heights(LAT, LON, 2.0, 4.0, 500)).intervalM == 60
    # No 850 hPa contours over the high ground in the west.
    assert all(pt[1] > -86.2 for line in h.lines for pt in line.points)


@pytest.mark.asyncio
async def test_off_the_grid_the_map_falls_back_to_open_meteo(client, upstream, hrrr_on):
    s = PressureService(client)
    await s.poll_hrrr()
    resp = await s.get_field_grid(45.0, -120.0, 3.0, 5.0)       # outside the fixture grid
    assert resp.source == "open-meteo"
    with pytest.raises(LookupError):
        await s.get_heights(45.0, -120.0, 2.0, 4.0, 850)


@pytest.mark.asyncio
async def test_a_late_bucket_sends_the_pull_to_nomads_as_whole_files(client, upstream, hrrr_on, monkeypatch):
    late = CYCLE + timedelta(minutes=hrrr.EXPECTED_AFTER_MIN + hrrr.LATE_MIN + 5)
    monkeypatch.setattr("app.service._now", lambda: late)
    upstream.hrrr_aws = {CYCLE - timedelta(hours=1)}
    upstream.hrrr_nomads = {CYCLE}
    s = PressureService(client)
    assert await s.poll_hrrr() > 0
    assert s.models.cycles("hrrr") == [CYCLE]
    gets = [c for c in upstream.hrrr_calls if c[1] == "GET" and not c[2].endswith(".idx") and "t02z" in c[2]]
    assert gets and all(c[0] == "nomads" and c[3] is None for c in gets)
    # The column feeds wait for the bucket rather than pull whole files.
    assert s.models.cycles("hrrr-col") == [CYCLE - timedelta(hours=1)]


@pytest.mark.asyncio
async def test_not_late_yet_means_the_older_cycle_from_the_bucket(client, upstream, hrrr_on, monkeypatch):
    # Expected at 58 minutes, only late at 68: at 62 the bucket gets the benefit.
    monkeypatch.setattr("app.service._now", lambda: CYCLE + timedelta(minutes=62))
    upstream.hrrr_aws = {CYCLE - timedelta(hours=1)}
    upstream.hrrr_nomads = {CYCLE}
    s = PressureService(client)
    await s.poll_hrrr()
    assert s.models.cycles("hrrr") == [CYCLE - timedelta(hours=1)]
    assert not any(c[0] == "nomads" for c in upstream.hrrr_calls)


@pytest.mark.asyncio
async def test_the_store_survives_a_restart_and_keeps_two_cycles(client, upstream, hrrr_on, tmp_path, monkeypatch):
    monkeypatch.setenv("BARRY_DATA_DIR", str(tmp_path))
    s = PressureService(client)
    await s.poll_hrrr()
    for k in (1, 2):
        later = NOW + timedelta(hours=k)
        monkeypatch.setattr("app.service._now", lambda later=later: later)
        await s.poll_hrrr()
    assert s.models.cycles("hrrr") == [CYCLE + timedelta(hours=2), CYCLE + timedelta(hours=1)]
    assert sorted(p.name for p in (tmp_path / "model" / "hrrr").iterdir()) == ["2026092503", "2026092504"]
    again = ModelStore(tmp_path / "model")
    assert again.cycles("hrrr") == s.models.cycles("hrrr")
    arr = again.load("hrrr", CYCLE + timedelta(hours=2), 1, "hpbl")
    assert arr is not None and float(arr[5, 5]) == 900.0


@pytest.mark.asyncio
async def test_the_model_loop_runs_and_health_notices_a_quiet_feed(client, upstream, hrrr_on, monkeypatch):
    import asyncio
    monkeypatch.setenv("BARRY_GLM", "0")
    monkeypatch.setenv("BARRY_LAMP", "0")
    s = PressureService(client)
    sched = Scheduler(s, interval_seconds=600)
    sched.start()
    try:
        for _ in range(200):
            if s.hrrr_ok_at is not None:
                break
            await asyncio.sleep(0.01)
        assert s.hrrr_ok_at is not None
        assert "hrrr fields stale" not in sched.problems(NOW)[1]
        assert "hrrr fields stale" in sched.problems(NOW + timedelta(hours=4))[1]
    finally:
        await sched.stop()
    assert "model loop exited" in sched.problems(NOW)[0]


@pytest.mark.asyncio
async def test_turbulence_and_icing_now_come_with_the_column(client, upstream, hrrr_on):
    from app.sources import hazards
    upstream.clock = lambda: NOW
    s = PressureService(client)
    assert await s.poll_hazards() == 11 + 60
    assert s.models.cycles("gtg") == [datetime(2026, 9, 25, 3, 0, tzinfo=timezone.utc)]
    assert s.models.cycles("cip") == [datetime(2026, 9, 25, 2, tzinfo=timezone.utc)]
    assert await s.poll_hazards() == 0                          # held
    a = await s.get_aloft(LAT, LON)                             # Open-Meteo's column, NOAA's hazards
    assert a.source == "open-meteo" and a.turbulence and a.icing
    edr = {l.ft: l.edr for l in a.turbulence.levels}
    assert edr[5100] == 0.3 and edr[6100] == 0.3 and edr[3100] == 0.05
    ice = {l.ft: l for l in a.icing.levels}
    assert ice[7500].severity == 3 and ice[7500].prob == 0.6 and ice[7500].sld == 0.2
    assert ice[5000].severity == 0
    # High ground in the west: nothing below it.
    w = await s.get_aloft(LAT, -87.3)
    assert min(l.ft for l in w.turbulence.levels) > 1600 * 3.28
    assert hazards.ft_name("edr", 30) == "edr_100" and hazards.ft_name("icp", 152.4) == "icp_500"


@pytest.mark.asyncio
async def test_old_hazards_are_not_served(client, upstream, hrrr_on, monkeypatch):
    s = PressureService(client)
    await s.poll_hazards()
    monkeypatch.setattr("app.service._now", lambda: NOW + timedelta(hours=3))
    upstream.clock = lambda: NOW + timedelta(hours=3)
    upstream.hazards_missing = {"gtg", "cip"}
    await s.poll_hazards()
    a = await s.get_aloft(LAT, LON)
    assert a.turbulence is None and a.icing is None


@pytest.mark.asyncio
async def test_the_point_forecast_is_hrrr_with_nbm_over_its_first_hours(client, upstream, hrrr_on, monkeypatch):
    monkeypatch.setattr("app.sources.hrrr.FC_LAST", 18)
    monkeypatch.setattr("app.sources.hrrr.EXTENDED_FC_LAST", 48)
    monkeypatch.setattr("app.sources.nbm.FHRS", tuple(range(1, 37)))
    s = PressureService(client)
    await s.poll_hrrr()
    run = datetime(2026, 9, 25, 0, tzinfo=timezone.utc)
    assert s.models.cycles("nbm") == [run]                      # 01z is not a three-hourly run
    f = await s.get_forecast(LAT, LON)
    # The forecast feed waits for all 18 hours (about 90 minutes), so at
    # 03:10 its run is 01z.
    assert f.source == "hrrr+nbm" and f.hourly[0].t == CYCLE - timedelta(hours=1)
    assert f.hourly[-1].t == run + timedelta(hours=48)        # the 00z run's last hour
    h = f.hourly[0]                                             # 01z: NBM's first hour
    assert (h.temperature, h.dewpoint, h.cloudcover, h.precip_prob) == (20.0, 12.0, 70.0, 60)
    assert (h.windspeed, h.winddir, h.windgust) == (18.0, 180, 32.4)
    assert h.weather_code == 95                                 # thunder 35 percent in the hour
    assert abs(h.pressure_msl - 1016.2) < 0.6 and h.cape == 500 and h.cin == -20 and h.boundary_layer == 900
    assert h.wind80m == 50.4 and h.radiation == 300
    late = next(x for x in f.hourly if x.t == run + timedelta(hours=40))   # past NBM's 36 hours
    assert abs(late.temperature - 16.85) < 0.06 and late.windspeed == 36.0 and late.winddir == 270
    assert late.precip_prob is None and late.weather_code == 1 and late.cloudcover == 40
    assert f.sun.sunset and f.sun.sunrise
    assert any(x.hour == 23 and x.day == 25 for x in f.sun.sunset)   # about 7:30 PM EDT
    c = await s.get_combined("KLUK")
    assert c.forecast.source == "hrrr+nbm" and c.sources.forecast == "hrrr+nbm"
    assert (await s.get_forecast(45.0, -120.0)).source == "open-meteo"


def test_weather_codes_from_probabilities():
    from app.modelfields import weather_code
    assert weather_code(40, 20, 0, 0, 30) == 95
    assert weather_code(10, 70, 0, 800, 90) == 80 and weather_code(10, 70, 0, 50, 90) == 61
    assert weather_code(None, None, 0.5, 0, 90) == 61 and weather_code(None, None, 0.0, 0, 90) == 3
    assert [weather_code(0, 0, 0, 0, c) for c in (10, 30, 60, 95)] == [0, 1, 2, 3]
