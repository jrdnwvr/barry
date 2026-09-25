"""Radar from MRMS: frames every ten minutes, tiles in RainViewer's shape
and colours, and RainViewer when Barry has no fresh frames."""
import math
import struct
import zlib
from datetime import datetime, timedelta, timezone

import httpx
import numpy as np
import pytest

from app import radar
from app.service import PressureService

NOW = datetime(2026, 9, 25, 3, 7, 30, tzinfo=timezone.utc)


@pytest.fixture
def mrms_on(monkeypatch, upstream):
    monkeypatch.setenv("BARRY_MRMS", "1")
    monkeypatch.setattr("app.service._now", lambda: NOW)
    upstream.clock = lambda: NOW


def read_png(data: bytes) -> np.ndarray:
    """RGBA pixels from the PNGs radar.png_rgba writes (filter 0 rows)."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, w, h, idat = 8, 0, 0, b""
    while pos < len(data):
        n = struct.unpack(">I", data[pos:pos + 4])[0]
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h = struct.unpack(">II", body[:8])
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    raw = np.frombuffer(zlib.decompress(idat), dtype=np.uint8).reshape(h, w * 4 + 1)
    assert (raw[:, 0] == 0).all()
    return raw[:, 1:].reshape(h, w, 4)


def tile_of(lat, lon, z):
    n = 2 ** z
    xf = (lon + 180) / 360 * n
    yf = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
    return int(xf), int(yf), int((xf % 1) * 512), int((yf % 1) * 512)


def ub(dbz):
    c = {int(k): v for k, v in __import__("json").load(open(radar.__file__.replace("radar.py", "data/radar_universal_blue.json"))).items()}[dbz]
    return [int(c[i:i + 2], 16) for i in (0, 2, 4, 6)]


@pytest.mark.asyncio
async def test_frames_every_ten_minutes_for_two_hours(client, upstream, mrms_on):
    s = PressureService(client)
    assert await s.poll_radar() == 13
    times = s.radar.observed()
    assert len(times) == 13 and all(b - a == 600 for a, b in zip(times, times[1:]))
    assert times[-1] == int(datetime(2026, 9, 25, 3, 0, tzinfo=timezone.utc).timestamp())
    assert await s.poll_radar() == 0                             # held
    f = await s.get_radar_frames()
    assert f.host == "https://barry.wide-stack.com" and len(f.frames) == 10
    past = [x for x in f.frames if not x.nowcast]
    cast = [x for x in f.frames if x.nowcast]
    assert len(past) == 7 and past[-1].path == f"/radar/tiles/{times[-1]}"
    # The next half hour: valid times ten minutes apart, URLs naming the run.
    assert [x.time for x in cast] == [times[-1] + 600 * k for k in (1, 2, 3)]
    assert [x.path for x in cast] == [f"/radar/tiles/{times[-1] + k}" for k in (1, 2, 3)]
    assert s.radar.tile(times[-1] + 2, 7, 34, 49) is not None


@pytest.mark.asyncio
async def test_a_tile_draws_the_storm_in_universal_blue(client, upstream, mrms_on):
    from app.main import app
    s = PressureService(client)
    await s.poll_radar()
    app.state.service = s
    t = s.radar.observed()[-1]
    x, y, px, py = tile_of(39.1, -84.5, 7)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        r = await c.get(f"/radar/tiles/{t}/512/7/{x}/{y}/2/0_1.png")
        assert r.status_code == 200 and r.headers["content-type"] == "image/png"
        assert "immutable" in r.headers["cache-control"]
        img = read_png(r.content)
        assert img[py, px].tolist() == ub(45)
        miss = await c.get(f"/radar/tiles/{t - 1}/512/7/{x}/{y}/2/0_1.png")
        assert miss.status_code == 404 and miss.headers["cache-control"] == "no-store"
        assert (await c.get(f"/radar/tiles/{t}/512/7/999/{y}/2/0_1.png")).status_code == 404
        # Far from any echo: an empty tile, small.
        ex, ey, _, _ = tile_of(20.0, -150.0, 7)
        empty = await c.get(f"/radar/tiles/{t}/512/7/{ex}/{ey}/2/0_1.png")
        assert empty.status_code == 200 and len(empty.content) < 3000 and not read_png(empty.content).any()


@pytest.mark.asyncio
async def test_a_one_pixel_storm_survives_a_continental_view(client, upstream, mrms_on):
    s = PressureService(client)
    await s.poll_radar()
    t = s.radar.observed()[-1]
    x, y, px, py = tile_of(39.9, -84.2, 4)
    img = read_png(s.radar.tile(t, 4, x, y))
    # The 60 dBZ pixel is smaller than a pixel at zoom 4; the pooled copy keeps it.
    near = img[max(0, py - 2):py + 3, max(0, px - 2):px + 3].reshape(-1, 4).tolist()
    assert ub(60) in near
    assert s.radar.sample(t, 39.1, -84.5) == 45.0 and s.radar.sample(t, 42.0, -90.0) is None


@pytest.mark.asyncio
async def test_rainviewer_when_barrys_frames_are_stale(client, upstream, mrms_on, monkeypatch):
    s = PressureService(client)
    await s.poll_radar()
    monkeypatch.setattr("app.service._now", lambda: NOW + timedelta(minutes=45))
    f = await s.get_radar_frames()
    assert f.host == "https://tilecache.rainviewer.com"


def test_png_writer_round_trips():
    img = np.zeros((4, 3, 4), dtype=np.uint8)
    img[1, 2] = [10, 20, 30, 255]
    assert (read_png(radar.png_rgba(img)) == img).all()
    assert radar.pool(np.array([[0, 5], [7, 1]], dtype=np.uint8)).tolist() == [[7]]


@pytest.mark.asyncio
async def test_rainviewer_by_default_when_configured_and_mrms_on_request(client, upstream, mrms_on, monkeypatch):
    monkeypatch.setenv("BARRY_RADAR_SOURCE", "rainviewer")
    s = PressureService(client)
    await s.poll_radar()
    assert (await s.get_radar_frames()).host == "https://tilecache.rainviewer.com"
    assert (await s.get_radar_frames("mrms")).host == "https://barry.wide-stack.com"



@pytest.mark.asyncio
async def test_a_newer_frame_replaces_the_nowcast(client, upstream, mrms_on, monkeypatch):
    s = PressureService(client)
    await s.poll_radar()
    base = s.radar.observed()[-1]
    assert s.radar.casts(base) == [base + 1, base + 2, base + 3]
    later = NOW + timedelta(minutes=10)
    monkeypatch.setattr("app.service._now", lambda: later)
    upstream.clock = lambda: later
    await s.poll_radar()
    new = s.radar.observed()[-1]
    assert new == base + 600 and s.radar.casts(new) == [new + 1, new + 2, new + 3]
    assert not s.radar.casts(base) and len(s.radar.observed()) == 13


def test_motion_follows_a_moving_storm():
    rng = np.random.default_rng(1)
    tex = (rng.random((200, 300)) * 60 + 110).astype(np.uint8)
    prev = np.zeros((1200, 1600), np.uint8)
    cur = np.zeros((1200, 1600), np.uint8)
    prev[400:600, 500:800] = tex
    cur[408:608, 516:816] = tex                      # 8 down, 16 across in ten minutes
    vy, vx, _ = radar.motion(radar.pooled(prev, 2), radar.pooled(cur, 2))
    by, bx = 500 // 4 // radar.BLOCK, 650 // 4 // radar.BLOCK
    assert (vy[by, bx], vx[by, bx]) == (2.0, 4.0)
    nxt = radar.advect(cur, vy, vx, 1)
    ys, xs = np.nonzero(nxt)
    assert (ys.min(), xs.min()) == (416, 532)


@pytest.mark.asyncio
async def test_the_chance_of_lightning_in_the_next_hour_comes_with_the_frames(client, upstream, mrms_on):
    from app.main import app
    s = PressureService(client)
    await s.poll_radar()
    f = await s.get_radar_frames()
    assert f.lightningNext is not None and f.lightningNext.path == f"/radar/lightning/{f.lightningNext.time}"
    app.state.service = s
    x, y, px, py = tile_of(39.1, -84.5, 7)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        r = await c.get(f"{f.lightningNext.path}/512/7/{x}/{y}.png")
        assert r.status_code == 200 and "immutable" in r.headers["cache-control"]
        assert read_png(r.content)[py, px].tolist() == [140, 77, 242, 107]      # 60 percent
    assert await s._poll_lightning_next(NOW) is False                           # held
