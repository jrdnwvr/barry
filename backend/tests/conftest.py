"""Shared fixtures: a mocked httpx client that fakes AWC + Open-Meteo upstreams."""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import httpx
import pytest


def _metar_record(sid, obs_time, slp, *, altim=None, pres_tend=None, name="Test Field",
                  wspd=10, wdir=230, wgst=None):
    return {
        "icaoId": sid,
        "obsTime": obs_time,
        "slp": slp,
        "altim": altim,
        "presTend": pres_tend,
        "name": name,
        "lat": 39.103,
        "lon": -84.419,
        "wspd": wspd,
        "wdir": wdir,
        "wgst": wgst,
        "visib": "10+",
        "clouds": [{"cover": "SCT", "base": 2500}, {"cover": "BKN", "base": 4500}],
        "fltCat": "VFR",
    }


def sample_metars(sid="KLUK", *, with_pres_tend=True):
    """A 4-point series, 1h apart, falling 1012 -> 1009.6 over 3h (delta -2.4).

    Anchored to wall-clock time so the interpreter's trailing-window logic sees
    "recent" data regardless of when the test suite runs."""
    end = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    base = int((end - timedelta(hours=3)).timestamp())
    pts = [
        (base + 0 * 3600, 1012.0),
        (base + 1 * 3600, 1011.2),
        (base + 2 * 3600, 1010.4),
        (base + 3 * 3600, 1009.6),
    ]
    recs = []
    for i, (t, slp) in enumerate(pts):
        pt = -2.4 if (with_pres_tend and i == len(pts) - 1) else None
        # Newest record carries a gust so the METAR-wind extraction is exercised.
        gust = 18 if i == len(pts) - 1 else None
        recs.append(_metar_record(sid, t, slp, altim=slp + 0.7, pres_tend=pt, wgst=gust))
    return recs


def sample_bbox_metars(pattern):
    """A ring of 8 stations ~100 km around KLUK with a linear tendency field.

    Each station reports altimeter only (exercises the SLP-fallback path), two
    obs 3h apart. Patterns:
      west_falls  d(x) = -1.0 + 0.015x -> -2.5 hPa/3h at the west station,
                  +0.5 at the east one (gradient 1.5 hPa/3h per 100 km, east-up:
                  the classic "front to the west" signature)
      east_falls  mirrored (falls to the east — the "it moved through" field)
      flat        incoherent +/-0.1 wobble -> no call
    """
    end = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    base = int((end - timedelta(hours=3)).timestamp())
    origin_lat, origin_lon = 39.103, -84.419
    recs = []
    import math
    for i, bearing in enumerate(range(0, 360, 45)):
        dist = 100.0
        x = dist * math.sin(math.radians(bearing))  # km east
        y = dist * math.cos(math.radians(bearing))  # km north
        lat = origin_lat + y / 111.32
        lon = origin_lon + x / (111.32 * math.cos(math.radians(origin_lat)))
        if pattern == "west_falls":
            d = -1.0 + 0.015 * x
        elif pattern == "east_falls":
            d = -1.0 - 0.015 * x
        else:  # flat
            d = 0.1 if i % 2 == 0 else -0.1
        sid = f"KR{i}A"
        for t, altim in ((base, 1015.0), (base + 3 * 3600, 1015.0 + d)):
            rec = _metar_record(sid, t, None, altim=altim, name=f"Ring {i}")
            rec["lat"] = round(lat, 4)
            rec["lon"] = round(lon, 4)
            recs.append(rec)
    return recs


def sample_forecast(trough=False):
    # Forecast hours follow the latest observed sample (sample_metars ends at
    # `now` rounded to the hour). Open-Meteo's "time" field is ISO without TZ
    # in the local timezone of the request — the parser treats it as UTC, which
    # is fine for the test (we just need a contiguous hourly sequence).
    start = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    times = [
        (start + timedelta(hours=i)).strftime("%Y-%m-%dT%H:%M")
        for i in range(12)
    ]
    n = len(times)
    if trough:
        # A genuine pressure trough at hour 5 (fall gentle enough not to trip the
        # interpreter's rapid_fall shortcut, which would preempt approaching_trough).
        pressures = [1009.4 - 0.5 * i if i <= 5 else 1006.9 + 0.8 * (i - 5)
                     for i in range(n)]
    else:
        # Continue the observed fall (ends ~1009.6) so the merged series the
        # interpreter sees has no boundary kink; -0.3 hPa/h matches the curve.
        pressures = [1009.4 - 0.3 * i for i in range(n)]
    return {
        "hourly": {
            "time": times,
            "pressure_msl": pressures,
            "surface_pressure": [1008.0 - 0.3 * i for i in range(n)],
            "windspeed_10m": [8.0 + 1.5 * i for i in range(n)],
            "winddirection_10m": [210 for _ in range(n)],
            "wind_gusts_10m": [14.0 + 2.5 * i for i in range(n)],
            # precip crosses 40% partway through
            "precipitation_probability": [10, 15, 20, 30, 45, 60, 70, 65, 50, 40, 30, 20],
        }
    }


class FakeUpstream:
    """Records calls and serves canned AWC / Open-Meteo responses."""

    def __init__(self):
        self.awc_calls = []
        self.om_calls = []
        self.awc_fail = False
        self.om_fail = False
        # Front-watch knobs: what a bbox query returns ("west_falls" /
        # "east_falls" / "flat" / None = empty body) and whether the forecast
        # curve contains a real trough (drives the interpreter's ETA).
        self.bbox_pattern = None
        self.om_trough = False

    def handler(self, request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if "aviationweather.gov" in url:
            self.awc_calls.append(request)
            if self.awc_fail:
                return httpx.Response(503, text="blocked")
            if request.url.params.get("bbox"):
                if self.bbox_pattern is None:
                    return httpx.Response(200, text="")
                return httpx.Response(200, json=sample_bbox_metars(self.bbox_pattern))
            ids = request.url.params.get("ids", "").split(",")
            recs = []
            for sid in ids:
                # Like real AWC: only K-prefixed identifiers report (typing
                # "LUK" or "I67" returns nothing; "KLUK"/"KI67" work).
                if sid and sid.startswith("K"):
                    recs.extend(sample_metars(sid))
            if not recs:
                # Faithful to real AWC: unknown identifiers get an EMPTY BODY,
                # not an empty JSON array — this exact quirk broke normalization
                # in production while the tests passed.
                return httpx.Response(200, text="")
            return httpx.Response(200, json=recs)
        if "open-meteo.com" in url:
            self.om_calls.append(request)
            if self.om_fail:
                return httpx.Response(503, text="down")
            return httpx.Response(200, json=sample_forecast(trough=self.om_trough))
        return httpx.Response(404)


@pytest.fixture
def upstream():
    return FakeUpstream()


@pytest.fixture
def client(upstream):
    transport = httpx.MockTransport(upstream.handler)
    return httpx.AsyncClient(transport=transport, timeout=5.0)
