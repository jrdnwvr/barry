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


@pytest.mark.asyncio
async def test_poll_feeds_the_slice_and_combined(client, upstream):
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
