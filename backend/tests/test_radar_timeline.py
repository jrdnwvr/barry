"""The radar's longer clock: two hours back and the nowcast to an hour on
the hour span, six hours back and twelve ahead on the day span, and the
nowcast's own score deciding how far ahead it is shown."""
from datetime import datetime, timedelta, timezone

import httpx
import numpy as np
import pytest

from app import radar
from app.service import PressureService

NOW = datetime(2026, 9, 25, 3, 7, 30, tzinfo=timezone.utc)
T0 = int(datetime(2026, 9, 25, 3, 0, tzinfo=timezone.utc).timestamp())
HOUR = "2026-09-25T03"


@pytest.fixture
def mrms_on(monkeypatch, upstream):
    monkeypatch.setenv("BARRY_MRMS", "1")
    monkeypatch.setattr("app.service._now", lambda: NOW)
    upstream.clock = lambda: NOW


def good(n=8):
    """A lead's counts with a CSI of 0.8 against persistence's 0.5."""
    return [80, 10, 10, 50, 25, 25, n]


@pytest.mark.asyncio
async def test_builds_before_the_spans_get_the_list_they_always_did(client, upstream, mrms_on):
    s = PressureService(client)
    await s.poll_radar()
    s._nowcast_scores = {"last": T0, "hours": {HOUR: {str(m): good() for m in (40, 50, 60)}}}
    f = await s.get_radar_frames()
    assert [x.time for x in f.frames] == [T0 + 600 * k for k in range(-6, 4)]
    assert [x.kind for x in f.frames] == ["observed"] * 7 + ["nowcast"] * 3


@pytest.mark.asyncio
async def test_the_hour_span_goes_two_hours_back_and_thirty_minutes_ahead_unscored(client, upstream, mrms_on):
    s = PressureService(client)
    await s.poll_radar()
    f = await s.get_radar_frames(span="hour")
    assert [x.time for x in f.frames] == [T0 + 600 * k for k in range(-12, 4)]
    assert [x.nowcast for x in f.frames] == [False] * 13 + [True] * 3


@pytest.mark.asyncio
async def test_a_lead_past_thirty_minutes_is_listed_while_its_score_holds(client, upstream, mrms_on):
    s = PressureService(client)
    await s.poll_radar()
    weak = [35, 40, 25, 30, 40, 30, 8]                 # CSI 0.35: under the bar
    s._nowcast_scores = {"last": T0, "hours": {HOUR: {"40": good(), "50": good(), "60": weak}}}
    assert s.nowcast_leads() == 5
    f = await s.get_radar_frames(span="hour")
    assert [x.time - T0 for x in f.frames if x.nowcast] == [600, 1200, 1800, 2400, 3000]
    assert f.frames[-1].path == f"/radar/tiles/{T0 + 5}"
    # A lead that holds beyond one that doesn't is not shown: no gaps.
    s._nowcast_scores["hours"][HOUR] = {"40": weak, "50": good(), "60": good()}
    assert s.nowcast_leads() == 3
    # Too few frames checked, or no better than leaving the rain in place.
    s._nowcast_scores["hours"][HOUR] = {"40": good(3)}
    assert s.nowcast_leads() == 3
    s._nowcast_scores["hours"][HOUR] = {"40": [50, 25, 25, 50, 25, 25, 8]}
    assert s.nowcast_leads() == 3
    # Scores older than three hours do not count.
    s._nowcast_scores["hours"] = {"2026-09-24T22": {"40": good()}}
    assert s.nowcast_leads() == 3


@pytest.mark.asyncio
async def test_each_new_frame_scores_every_lead_once(client, upstream, mrms_on):
    s = PressureService(client)
    await s.poll_radar()
    hours = s._nowcast_scores["hours"]
    assert s._nowcast_scores["last"] == T0 and sorted(hours[HOUR], key=int) == ["10", "20", "30", "40", "50", "60"]
    row = hours[HOUR]["30"]
    # The mock's storm does not move: the nowcast and persistence both hit it all.
    assert row[0] > 0 and row[1:3] == [0, 0] and row[3:6] == row[0:3] and row[6] == 1
    await s.poll_radar()                                # same newest frame
    assert hours[HOUR]["30"][6] == 1
    out = s.nowcast_scores()
    assert out["shownMin"] == 30 and out["leads"][0] == {"leadMin": 10, "csi": 1.0, "persistence": 1.0, "frames": 1}
    assert out["days"][0]["day"] == "2026-09-25"


@pytest.mark.asyncio
async def test_the_day_span_is_on_the_hour_from_six_back_to_twelve_ahead(client, upstream, mrms_on, monkeypatch):
    later = NOW + timedelta(minutes=20)                 # newest frame 03:20
    monkeypatch.setattr("app.service._now", lambda: later)
    upstream.clock = lambda: later
    s = PressureService(client)
    await s.poll_radar()
    base = T0 + 1200
    s._nowcast_scores = {"last": base, "hours": {HOUR: {"40": good()}}}
    grid = {"lat0": 45.0, "lon0": -95.0, "dlat": 0.05, "dlon": 0.05}
    codes = np.zeros((40, 40), np.uint8)
    codes[10:20, 10:20] = 150
    # A run from 02:00: 04:00 is its second hour, 05:00 its third; and an
    # older run's fourth hour for 05:00, which the newer one supersedes.
    four, five = T0 + 3600, T0 + 7200
    for key in (four + 2, five + 3, five + 4):
        s.radar_model.put(key, codes, grid)
    f = await s.get_radar_frames(span="day")
    past = [x for x in f.frames if x.kind == "observed"]
    # Every twenty minutes from 21:20, six hours before the newest frame at 03:20.
    assert [x.time for x in past] == [base - 1200 * k for k in range(18, -1, -1)]
    ahead = [x for x in f.frames if x.nowcast]
    # 04:00 is forty minutes out and the nowcast has earned forty: it wins
    # over the model there. 05:00 is the model's, from the newer run.
    assert [(x.time, x.kind, x.path) for x in ahead] == [
        (four, "nowcast", f"/radar/tiles/{base + 4}"), (five, "model", f"/radar/model/{five + 3}")]
    # Without the score, 04:00 falls to the model.
    s._nowcast_scores = {"last": base, "hours": {}}
    f = await s.get_radar_frames(span="day")
    assert [(x.time, x.kind) for x in f.frames if x.nowcast][0] == (four, "model")

    from app.main import app
    app.state.service = s
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        r = await c.get(f"/radar/model/{five + 3}/512/6/15/23/2/0_1.png")
        assert r.status_code == 200 and "immutable" in r.headers["cache-control"]
        assert (await c.get(f"/radar/model/{five + 9}/512/6/15/23/2/0_1.png")).status_code == 404
        listed = (await c.get("/radar/frames?span=day")).json()
        assert listed["frames"][-1]["kind"] == "model"
        assert (await c.get("/radar/frames?span=week")).status_code == 422


def test_two_steps_of_motion_blend_into_one():
    z = np.zeros((2, 2), np.float32)
    newer = (np.array([[2, 0], [1, 0]], np.float32), np.array([[4, 0], [0, 0]], np.float32), None)
    older = (np.array([[4, 3], [0, 0]], np.float32), np.array([[2, 1], [0, 0]], np.float32), None)
    vy, vx = radar.blend_motion(newer, older)
    # Both moving: the mean. One moving: that one. Neither: still.
    assert vy.tolist() == [[3, 3], [1, 0]] and vx.tolist() == [[3, 1], [0, 0]]
    assert radar.blend_motion((z, z, None), (z, z, None))[0].tolist() == z.tolist()


def test_the_score_counts_hits_misses_and_false_alarms_at_20_dbz():
    rain, none = radar.SCORE_CODE, radar.SCORE_CODE - 1
    pred = np.array([[rain, rain, none, none]], np.uint8)
    obs = np.array([[rain, none, rain, none]], np.uint8)
    assert radar.score_counts(pred, obs) == (1, 1, 1)
    assert radar.csi(1, 1, 1) == pytest.approx(1 / 3) and radar.csi(0, 0, 0) is None


def test_the_pooled_copy_is_carried_as_far_as_the_full_one():
    rng = np.random.default_rng(1)
    tex = (rng.random((200, 300)) * 60 + 110).astype(np.uint8)
    prev = np.zeros((1200, 1600), np.uint8)
    cur = np.zeros((1200, 1600), np.uint8)
    prev[400:600, 500:800] = tex
    cur[408:608, 516:816] = tex                         # 8 down, 16 across in ten minutes
    lvl = radar.MOTION_LEVEL
    vy, vx, _ = radar.motion(radar.pooled(prev, lvl), radar.pooled(cur, lvl))
    small = radar.advect(radar.pooled(cur, lvl), vy, vx, 3, level=lvl)
    ys, xs = np.nonzero(small)
    # Three steps of (8, 16) full-resolution points is (6, 12) pooled ones.
    assert (ys.min(), xs.min()) == (408 // 4 + 6, 516 // 4 + 12)


# ---- isobars on the same clock ---------------------------------------------------

HRRR_NOW = datetime(2026, 9, 25, 3, 10, tzinfo=timezone.utc)      # the forecast feed's run is 02z
LAT, LON = 38.4, -84.4


@pytest.fixture
def hrrr_on(monkeypatch, upstream):
    monkeypatch.setenv("BARRY_HRRR", "1")
    monkeypatch.setattr("app.service._now", lambda: HRRR_NOW)
    upstream.clock = lambda: HRRR_NOW


def station_table(lat=LAT, lon=LON, n=10):
    """Stations on a lattice over a 7 by 9 degree box, pressure rising 4 hPa
    a degree north."""
    from app.models import StationObs
    out = []
    for j in range(n):
        for i in range(n):
            la = lat - 3.5 + 7.0 * j / (n - 1)
            lo = lon - 4.5 + 9.0 * i / (n - 1)
            out.append(StationObs(id=f"S{j}{i}", lat=la, lon=lo, slp=round(1012.0 + 4.0 * (la - lat), 1)))
    return out


def grid_mean_diff(a, b):
    d = [x - y for ra, rb in zip(a.values, b.values) for x, y in zip(ra, rb) if x is not None and y is not None]
    assert d
    return sum(d) / len(d), max(d) - min(d)


@pytest.mark.asyncio
async def test_isobars_for_each_hour_past_from_snapshots_ahead_from_the_models_change(client, upstream, hrrr_on):
    from app import modelfields
    from app.modelstore import _cycle_name
    s = PressureService(client)
    await s.poll_hrrr()
    table = station_table()

    async def bulk(*a, **k):
        return table
    s.metar_bulk = bulk
    # The stations read 3, 2 and 1 hPa higher three, two and one snapshots ago.
    s._bulk_history = []
    for h in (3, 2, 1, 0):
        at = HRRR_NOW - timedelta(hours=h, minutes=5)
        s._bulk_history.append((at, {o.id: (at, o.slp + h, None, o.lat, o.lon) for o in table}))
    # And the model raises the pressure 2 hPa an hour from its analysis.
    feed, cycle = modelfields.MSLP_FEED, datetime(2026, 9, 25, 2, tzinfo=timezone.utc)
    k = s.models.grid(feed, cycle)["pack"].index("mslp")
    for fhr in s.models.hours(feed, cycle):
        arr = np.array(s.models.load(feed, cycle, fhr, "pack"), dtype=np.float32)
        arr[:, :, k] += 2.0 * fhr
        s.models._mem[(feed, _cycle_name(cycle), fhr, "pack")] = arr

    out = await s.get_pressure_series(LAT, LON, 2.0, 4.0)
    at = lambda h, m=0: int(datetime(2026, 9, 25, h, m, tzinfo=timezone.utc).timestamp())
    # A snapshot five minutes before each hour from midnight; none before.
    # Then now itself, then the model's hours.
    assert [(f.time, f.kind) for f in out.frames] == [
        (at(0), "observed"), (at(1), "observed"), (at(2), "observed"), (at(3), "observed"),
        (at(3, 10), "now"), (at(4), "model"), (at(5), "model")]
    assert out.run == cycle and out.stepHPa in (2.0, 4.0)
    now = out.frames[4].pressureGrid
    for i, h in enumerate((3, 2, 1, 0)):
        mean, spread = grid_mean_diff(out.frames[i].pressureGrid, now)
        assert abs(mean - h) < 0.06 and spread < 0.25
    # 03:10 sits a sixth of the way from the run's first hour to its second:
    # the model is 2.33 hPa up by then, 4 by 04:00, 6 by 05:00.
    for i, rise in ((5, 4 - 7 / 3), (6, 6 - 7 / 3)):
        mean, spread = grid_mean_diff(out.frames[i].pressureGrid, now)
        assert abs(mean - rise) < 0.06 and spread < 0.25
    # One lattice for every frame, values to a hundredth.
    shape = lambda g: (g.lat0, g.lon0, g.dlat, g.dlon, g.ny, g.nx)
    assert len({shape(f.pressureGrid) for f in out.frames}) == 1
    vals = [v for row in now.values for v in row if v is not None]
    assert vals and all(round(v, 2) == v for v in vals) and any(round(v, 1) != v for v in vals)

    from app.main import app
    app.state.service = s
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        r = await c.get(f"/radar/pressure/series?lat={LAT}&lon={LON}&latSpan=2&lonSpan=4")
        body = r.json()
        assert r.status_code == 200 and len(body["frames"]) == 7 and "pressureGrid" in body["frames"][0]


@pytest.mark.asyncio
async def test_off_the_models_grid_the_series_has_only_the_past(client, upstream, hrrr_on):
    s = PressureService(client)
    await s.poll_hrrr()
    table = station_table(lat=47.0, lon=-122.0)                    # outside the fixture's grid

    async def bulk(*a, **k):
        return table
    s.metar_bulk = bulk
    at = HRRR_NOW - timedelta(minutes=5)
    s._bulk_history = [(at, {o.id: (at, o.slp, None, o.lat, o.lon) for o in table})]
    far = await s.get_pressure_series(47.0, -122.0, 2.0, 4.0)
    assert [f.kind for f in far.frames] == ["observed", "now"] and far.run is None
    # Too few stations to grid: no frames at all, and no error.
    s._bulk_history = []
    table.clear()
    empty = await s.get_pressure_series(20.0, -150.0, 2.0, 4.0)
    assert empty.frames == []


# ---- the model's radar past the nowcast --------------------------------------------

@pytest.mark.asyncio
async def test_the_models_reflectivity_becomes_radar_frames(client, upstream, hrrr_on, monkeypatch):
    from test_radar_mrms import read_png, tile_of, ub
    s = PressureService(client)
    await s.poll_hrrr()
    run = int(datetime(2026, 9, 25, 2, tzinfo=timezone.utc).timestamp())
    # The 02z run's three hours: 03:00 (ten minutes gone, still kept), 04:00, 05:00.
    assert s.radar_model.times() == [run + 3600 * h + h for h in (1, 2, 3)]
    assert s._model_radar_keys(datetime(2026, 9, 25, 2, tzinfo=timezone.utc)) == s.radar_model.times()
    key = run + 2 * 3600 + 2
    # 40 dBZ north of 39 N and east of 84 W in the fixture, nothing elsewhere.
    x, y, px, py = tile_of(39.6, -83.0, 7)
    img = read_png(s.radar_model.tile(key, 7, x, y))
    assert img[py, px].tolist() == ub(40)
    x, y, px, py = tile_of(38.0, -86.0, 7)
    assert not read_png(s.radar_model.tile(key, 7, x, y))[py, px].any()
    assert s.radar_model.sample(key, 39.6, -83.0) == 40.0 and s.radar_model.sample(key, 45.0, -100.0) is None
    assert await s.poll_hrrr() == 0 and len(s.radar_model.times()) == 3       # nothing made twice

    # Two hours on: 03:00 and 04:00 are gone by more than an hour.
    later = HRRR_NOW + timedelta(hours=2)
    monkeypatch.setattr("app.service._now", lambda: later)
    s._purge_model_radar(later)
    assert s.radar_model.times() == [run + 3 * 3600 + 3]
    # A third run's frames push the oldest run's out.
    grid = {"lat0": 45.0, "lon0": -95.0, "dlat": 0.05, "dlon": 0.05}
    for r in (run + 3600, run + 7200):
        s.radar_model.put(r + 6 * 3600 + 6, np.zeros((4, 4), np.uint8), grid)
    s._purge_model_radar(later)
    assert s.radar_model.times() == [run + 3600 + 6 * 3600 + 6, run + 7200 + 6 * 3600 + 6]


def test_model_frames_cover_the_models_domain_at_three_hundredths_of_a_degree():
    from app import modelradar
    ny, nx = modelradar.shape()
    g = modelradar.grid()
    assert (ny, nx) == (1067, 2467)
    # The last row and column's centres: just inside 21 N and 60.5 W.
    assert g["lat0"] - (ny - 1) * g["dlat"] == pytest.approx(21.005)
    assert g["lon0"] + (nx - 1) * g["dlon"] == pytest.approx(-60.505)


# ---- the wind grid past the view's edges ---------------------------------------------

@pytest.mark.asyncio
async def test_a_padded_wind_grid_is_on_a_lattice_every_region_shares(client, upstream, hrrr_on):
    s = PressureService(client)
    await s.poll_hrrr()
    # The fixture's grid runs about 37 to 40.4 N and 88 to 81.5 W.
    a = await s.get_field_grid(38.6, -85.0, 1.0, 2.0, pad=0.5)
    key = lambda r: {(p.lat, p.lon) for p in r.points}
    lats, lons = sorted({p.lat for p in a.points}), sorted({p.lon for p in a.points})
    # A degree down in eight rows is an eighth of a degree; two across in eleven, a fifth.
    assert all(abs(y - x - 0.125) < 1e-6 for x, y in zip(lats, lats[1:]))
    assert all(abs(y - x - 0.2) < 1e-6 for x, y in zip(lons, lons[1:]))
    assert all(abs(v / 0.125 - round(v / 0.125)) < 1e-6 for v in lats)
    # Half a span past each edge: 37.6 to 39.6 N and 87 to 83 W, the lattice points inside.
    assert (lats[0], lats[-1]) == (37.625, 39.5) and (lons[0], lons[-1]) == (-87.0, -83.0)
    # The view moved a third of its width east: every point the two cover is the same point.
    b = await s.get_field_grid(38.6, -84.35, 1.0, 2.0, pad=0.5)
    shared = key(a) & key(b)
    assert len(shared) > len(a.points) / 2 and key(b) - key(a)
    west_edge = min(p.lon for p in b.points)
    assert {k for k in key(a) if k[1] >= west_edge} <= key(b)
    # Winds aloft come on the same lattice.
    lv = await s.get_field_levels(38.6, -85.0, 1.0, 2.0, pad=0.5)
    assert {(p.lat, p.lon) for p in lv.points} <= key(a) and lv.points
    # Without the pad: the eleven by eight inside the view, as before.
    plain = await s.get_field_grid(38.6, -85.0, 1.0, 2.0)
    assert len(plain.points) == s.HRRR_COLS * s.HRRR_ROWS
    assert max(p.lon for p in plain.points) < -84.0

    from app.main import app
    app.state.service = s
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        r = await c.get("/radar/field?lat=38.6&lon=-85&latSpan=1&lonSpan=2&pad=0.5")
        assert r.status_code == 200 and len(r.json()["points"]) == len(a.points)
        assert (await c.get("/radar/field?lat=38.6&lon=-85&latSpan=1&lonSpan=2&pad=2")).status_code == 422


def test_the_lattice_step_is_the_smallest_that_keeps_the_view_to_its_rows():
    step = PressureService.lattice_step
    assert step(1.0, 8) == 0.125 and step(3.2, 8) == 0.4 and step(3.0, 8) == 0.4
    assert step(0.1, 8) == 0.05                     # never finer than the first step
    assert step(200.0, 8) == 8.0                    # nor coarser than the last
