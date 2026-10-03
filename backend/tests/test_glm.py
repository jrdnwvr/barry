"""GOES GLM lightning: the file parser, the flash store, and the endpoint."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app import flashes as fl
from app.service import PressureService
from app.sources import glm
from app.sources.glm import Flash
from conftest import sample_glm_file, sample_s3_listing

NOW = datetime(2026, 9, 17, 0, 10, 0, tzinfo=timezone.utc)


def test_listing_and_start_time():
    keys = glm.parse_listing(sample_s3_listing(NOW))
    assert len(keys) == 2 and all(k.endswith(".nc") for k, _ in keys)
    key = keys[0][0]
    assert glm.start_time(key) == NOW - timedelta(minutes=2)
    assert glm.start_time("junk") is None
    assert glm.list_url("noaa-goes19", NOW).endswith("prefix=GLM-L2-LCFA/2026/260/00/")


def test_parse_file_applies_scaling_and_time_base():
    key = "GLM-L2-LCFA/2026/260/00/OR_GLM-L2-LCFA_G19_s20262600008000_e20262600008200_c20262600008216.nc"
    data = sample_glm_file(NOW - timedelta(minutes=2), [(39.10, -84.42, 5.0), (40.0, -85.0, 12.0), (0.0, 0.0, 3.0)],
                           quality=[0, 0, 3])
    out = glm.parse_file(data, key)
    assert len(out) == 2                       # the bad-quality flash is dropped
    assert out[0].lat == pytest.approx(39.10, abs=1e-3) and out[0].lon == pytest.approx(-84.42, abs=1e-3)
    assert out[0].t == pytest.approx((NOW - timedelta(minutes=2)).timestamp() + 5.0, abs=0.01)
    assert out[1].t == pytest.approx((NOW - timedelta(minutes=2)).timestamp() + 12.0, abs=0.01)
    assert out[0].energy > 0


def test_store_bins_prunes_and_finds_the_nearest_with_drift():
    s = fl.FlashStore()
    t0 = NOW.timestamp()
    # A cluster 40 km NW of Lunken drifting SE over the window (older half
    # farther out, newer half closer), plus one stale flash and one far one.
    old = [Flash(t0 - 700 + i, 39.45 + 0.001 * i, -84.85, 1.0) for i in range(8)]
    new = [Flash(t0 - 200 + i, 39.30 + 0.001 * i, -84.65, 1.0) for i in range(8)]
    s.add(old + new + [Flash(t0 - 2000, 39.2, -84.5, 1.0), Flash(t0, 45.0, -84.5, 1.0)], NOW)
    assert len(s) == 17
    cells = s.cells(39.103, -84.419, 3.0, NOW)
    assert sum(c.count for c in cells) == 16
    # The two halves of the drifting cluster are far enough apart to be two
    # storms; the lone far flash is below the cluster floor.
    clusters = s.clusters(cells, NOW)
    assert len(clusters) == 2 and all(c.flashes == 8 for c in clusters)
    assert all(c.points[0] == c.points[-1] and len(c.points) >= 4 for c in clusters)
    assert clusters[0].recent >= 0 and s.response(39.103, -84.419, 3.0, NOW).clusters
    assert min(c.ageSec for c in cells) <= 200
    n = s.nearest(39.103, -84.419, NOW)
    assert n.source == "glm" and n.status == "strikes" and n.flashes == 16
    assert n.cardinal == "NW" and 15 <= n.distanceMi <= 20
    assert n.moving == "SE" and n.towardYou is True
    assert n.speedKmh is not None and n.speedKmh > 8 and n.etaAt is not None and n.etaAt > NOW
    # Reversed in time: the cluster moves away.
    s2 = fl.FlashStore()
    s2.add([Flash(f.t + 500, f.lat, f.lon, 1.0) for f in old] + [Flash(f.t - 500, f.lat, f.lon, 1.0) for f in new], NOW)
    assert s2.nearest(39.103, -84.419, NOW).towardYou is False
    assert fl.FlashStore().nearest(39.103, -84.419, NOW) is None


def test_believed_flashes_are_kept_for_hours_and_served_by_the_mark():
    """A cluster two hours ago and one just now: each sits in the frames
    whose twenty-minute window holds it, with ages from the mark; the
    live window has only the newer; a lone old flash is never believed and
    so never kept; and the history is pruned at six and a half hours."""
    s = fl.FlashStore()
    t0 = NOW.timestamp()
    then = t0 - 2 * 3600
    old = [Flash(then - 100 + i, 39.45 + 0.001 * i, -84.85, 1.0) for i in range(6)]
    new = [Flash(t0 - 100 + i, 39.30 + 0.001 * i, -84.65, 1.0) for i in range(6)]
    s.add(old + [Flash(then - 50, 40.5, -84.0, 1.0)], datetime.fromtimestamp(then, tz=timezone.utc))
    s.credible()                                   # believed then, into the history
    s.add(new, NOW)                                # the window moves on; the old ones leave it
    assert len(s) == 6 and sum(c.count for c in s.cells(39.103, -84.419, 3.0, NOW)) == 6
    frames = s.frames(39.103, -84.419, 3.0, NOW)
    marks = [f.time for f in frames]
    assert len(frames) == 37 and marks == sorted(marks) and all(m % 600 == 0 for m in marks)
    held = {f.time: sum(c.count for c in f.cells) for f in frames}
    first_old = next(m for m in marks if m >= then)
    assert held[first_old] == 6 and held[first_old + 600] == 6 and held[first_old + 1200] == 0
    assert held[marks[-1]] == 6 and all(c.ageSec <= 100 + 600 for f in frames if f.time == marks[-1] for c in f.cells)
    assert sum(held.values()) == 18                # the old six in two marks, the new six in the last
    s.prune(NOW + timedelta(hours=5))
    assert len(s._history) == 6                    # the cluster from then is gone


@pytest.mark.asyncio
async def test_poll_feeds_the_slice_and_combined(client, upstream, monkeypatch):
    # Frozen clocks on both sides: the fake used to mint keys from the real
    # clock, so a second boundary between the two polls made "nothing new"
    # false once in a few hundred runs.
    monkeypatch.setattr("app.service._now", lambda: NOW)
    upstream.clock = lambda: NOW
    service = PressureService(client)
    await service.poll_lightning()
    assert upstream.s3_lists >= 2 and upstream.s3_files >= 2        # both satellites
    resp = await service.get_lightning(39.1, -84.5)
    assert resp.coverage and resp.cells and resp.cells[0].count >= 1
    # A second poll fetches nothing new (keys already seen).
    files_before = upstream.s3_files
    await service.poll_lightning()
    assert upstream.s3_files == files_before
    combined = await service.get_combined("KLUK")
    assert combined.lightningNearby is not None and combined.lightningNearby.source == "glm"


@pytest.mark.asyncio
async def test_glm_outage_is_quiet(client, upstream):
    upstream.s3_fail = True
    service = PressureService(client)
    await service.poll_lightning()                # logs, never raises
    resp = await service.get_lightning(39.1, -84.5)
    assert resp.cells == [] and resp.coverage is False


# ---- Which flashes to believe ------------------------------------------------

def _store(echo):
    """A store whose radar says `echo(lat, lon)` dBZ (None: cannot see)."""
    return fl.FlashStore(echo_at=lambda la, lo, t: echo(la, lo))


def test_a_lone_flash_in_clear_air_is_not_lightning_nearby():
    t0 = NOW.timestamp()
    s = _store(lambda la, lo: -99.0)                              # the radar sees no echo anywhere
    s.add([Flash(t0 - 60, 39.3, -84.6, 1.0)], NOW)
    assert s.nearest(39.1, -84.5, NOW) is None
    assert s.cells(39.1, -84.5, 2.0, NOW) == [] and s.dropped == 1
    # The same flash over a storm the radar sees: believed.
    s2 = _store(lambda la, lo: 42.0)
    s2.add([Flash(t0 - 60, 39.3, -84.6, 1.0)], NOW)
    near = s2.nearest(39.1, -84.5, NOW)
    assert near is not None and near.flashes == 1 and s2.dropped == 0


def test_in_clear_air_it_takes_three_flashes_together():
    t0 = NOW.timestamp()
    s = _store(lambda la, lo: None)                               # no radar there (offshore, or none held)
    two = [Flash(t0 - 60, 39.30, -84.60, 1.0), Flash(t0 - 50, 39.35, -84.55, 1.0)]
    s.add(two, NOW)
    assert s.nearest(39.1, -84.5, NOW) is None
    s.add([Flash(t0 - 40, 39.32, -84.58, 1.0)], NOW)              # a third within 20 km
    near = s.nearest(39.1, -84.5, NOW)
    assert near is not None and near.flashes == 3
    # Three spread 30 km apart are still three lone flashes.
    s3 = _store(lambda la, lo: None)
    s3.add([Flash(t0 - 60, 39.0, -84.0, 1.0), Flash(t0 - 50, 39.27, -84.0, 1.0), Flash(t0 - 40, 39.54, -84.0, 1.0)], NOW)
    assert s3.nearest(39.2, -84.1, NOW) is None


def test_weak_echo_does_not_back_a_flash_and_a_backed_flash_stays_backed():
    t0 = NOW.timestamp()
    echo = {"dbz": 25.0}
    s = _store(lambda la, lo: echo["dbz"])
    s.add([Flash(t0 - 60, 39.3, -84.6, 1.0)], NOW)
    assert s.nearest(39.1, -84.5, NOW) is None                    # 25 dBZ: rain, not a thunderstorm core
    echo["dbz"] = 35.0
    s.add([], NOW)                                                # a newer radar frame, checked on the next poll
    assert s.nearest(39.1, -84.5, NOW) is not None
    echo["dbz"] = -99.0
    s.add([], NOW)
    assert s.nearest(39.1, -84.5, NOW) is not None                # the storm was there when it flashed


@pytest.mark.asyncio
async def test_the_service_checks_flashes_against_its_own_radar(client, upstream, monkeypatch):
    """The MRMS fixture has a 45 dBZ cell over Cincinnati and nothing near
    Cleveland: a flash over the cell is lightning nearby, a lone one near
    Cleveland is not."""
    monkeypatch.setenv("BARRY_MRMS", "1")
    now = datetime(2026, 9, 25, 3, 7, 30, tzinfo=timezone.utc)
    monkeypatch.setattr("app.service._now", lambda: now)
    upstream.clock = lambda: now
    s = PressureService(client)
    await s.poll_radar()
    t0 = now.timestamp()
    s.flashes.add([Flash(t0 - 60, 39.10, -84.50, 1.0), Flash(t0 - 60, 41.40, -81.70, 1.0)], now)
    assert s._echo_at(39.10, -84.50, t0) >= 40 and s._echo_at(41.40, -81.70, t0) < 0
    over = s.flashes.nearest(39.05, -84.45, now)
    assert over is not None and over.distanceMi <= 5
    assert s.flashes.nearest(41.45, -81.75, now) is None and s.flashes.dropped == 1
