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
    times = s.radar.times()
    assert len(times) == 13 and all(b - a == 600 for a, b in zip(times, times[1:]))
    assert times[-1] == int(datetime(2026, 9, 25, 3, 0, tzinfo=timezone.utc).timestamp())
    assert await s.poll_radar() == 0                             # held
    f = await s.get_radar_frames()
    assert f.host == "https://barry.wide-stack.com" and len(f.frames) == 7
    assert f.frames[-1].path == f"/radar/tiles/{times[-1]}" and not any(x.nowcast for x in f.frames)


@pytest.mark.asyncio
async def test_a_tile_draws_the_storm_in_universal_blue(client, upstream, mrms_on):
    from app.main import app
    s = PressureService(client)
    await s.poll_radar()
    app.state.service = s
    t = s.radar.times()[-1]
    x, y, px, py = tile_of(39.1, -84.5, 7)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        r = await c.get(f"/radar/tiles/{t}/512/7/{x}/{y}/2/0_1.png")
        assert r.status_code == 200 and r.headers["content-type"] == "image/png"
        assert "immutable" in r.headers["cache-control"]
        img = read_png(r.content)
        assert img[py, px].tolist() == ub(45)
        assert (await c.get(f"/radar/tiles/{t - 1}/512/7/{x}/{y}/2/0_1.png")).status_code == 404
        assert (await c.get(f"/radar/tiles/{t}/512/7/999/{y}/2/0_1.png")).status_code == 404
        # Far from any echo: an empty tile, small.
        ex, ey, _, _ = tile_of(20.0, -150.0, 7)
        empty = await c.get(f"/radar/tiles/{t}/512/7/{ex}/{ey}/2/0_1.png")
        assert empty.status_code == 200 and len(empty.content) < 3000 and not read_png(empty.content).any()


@pytest.mark.asyncio
async def test_a_one_pixel_storm_survives_a_continental_view(client, upstream, mrms_on):
    s = PressureService(client)
    await s.poll_radar()
    t = s.radar.times()[-1]
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
