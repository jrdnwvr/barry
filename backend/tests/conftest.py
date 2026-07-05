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


def sample_forecast():
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
    return {
        "hourly": {
            "time": times,
            # Continue the observed fall (ends ~1009.6) so the merged series the
            # interpreter sees has no boundary kink; -0.3 hPa/h matches the curve.
            "pressure_msl": [1009.4 - 0.3 * i for i in range(n)],
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

    def handler(self, request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if "aviationweather.gov" in url:
            self.awc_calls.append(request)
            if self.awc_fail:
                return httpx.Response(503, text="blocked")
            ids = request.url.params.get("ids", "").split(",")
            recs = []
            for sid in ids:
                if sid:
                    recs.extend(sample_metars(sid))
            return httpx.Response(200, json=recs)
        if "open-meteo.com" in url:
            self.om_calls.append(request)
            if self.om_fail:
                return httpx.Response(503, text="down")
            return httpx.Response(200, json=sample_forecast())
        return httpx.Response(404)


@pytest.fixture
def upstream():
    return FakeUpstream()


@pytest.fixture
def client(upstream):
    transport = httpx.MockTransport(upstream.handler)
    return httpx.AsyncClient(transport=transport, timeout=5.0)
