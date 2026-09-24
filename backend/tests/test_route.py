"""A route between two fields: geometry, the corridor, and the route itself."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import httpx
import pytest

from app import route
from app.service import PressureService


def test_distance_and_track_position():
    luk, day = (39.103, -84.419), (39.902, -84.219)
    assert route.distance_nm(*luk, *day) == pytest.approx(48.9, abs=0.3)
    along, off = route.track_position(luk, day, (39.5, -84.2))
    assert along == pytest.approx(25.3, abs=0.5) and off == pytest.approx(5.5, abs=0.5)
    behind, _ = route.track_position(luk, day, (38.8, -84.5))
    assert behind < 0


def test_a_front_across_the_line_is_found_where_it_crosses():
    cold = SimpleNamespace(type="cold", points=[[39.5, -85.5], [39.5, -83.0]])
    parallel = SimpleNamespace(type="warm", points=[[38.0, -85.0], [38.0, -83.0]])
    hits = route.front_crossings((39.103, -84.419), (39.902, -84.219), [cold, parallel])
    assert [t for t, _ in hits] == ["cold"]
    assert hits[0][1] == pytest.approx(24, abs=4)


def test_worst_category_and_taf_at_arrival():
    assert route.worst(["VFR", "IFR", None, "MVFR"]) == "IFR"
    assert route.worst([None]) is None
    t0 = datetime(2026, 9, 24, 18, tzinfo=timezone.utc)
    p = lambda ch, a, b, cat: SimpleNamespace(change=ch, timeFrom=t0 + timedelta(hours=a),
                                               timeTo=t0 + timedelta(hours=b), fltCat=cat)
    periods = [p(None, 0, 6, "VFR"), p("FM", 3, 12, "MVFR"), p("TEMPO", 3, 5, "IFR")]
    prevailing, temporary = route.taf_at(periods, t0 + timedelta(hours=4))
    assert prevailing.fltCat == "MVFR" and [x.fltCat for x in temporary] == ["IFR"]


def test_sunset_is_close_to_the_almanac():
    s = route.sunset(39.103, -84.419, datetime(2026, 9, 24, tzinfo=timezone.utc))
    assert s.hour == 23 and 25 <= s.minute <= 38          # 7:31 PM EDT
    before = route.minutes_from_sunset(39.103, -84.419, s - timedelta(minutes=52))
    assert before == -52
    assert route.minutes_from_sunset(39.103, -84.419, s - timedelta(hours=6)) is None


@pytest.mark.asyncio
async def test_the_route_from_held_data(client, upstream):
    service = PressureService(client)
    r = await service.get_route("KI67", "KILN", speed_kt=100)
    assert r.dep.station == "KI67" and r.dest.station == "KILN"
    assert r.distanceNm == pytest.approx(route.distance_nm(r.depLat, r.depLon, r.destLat, r.destLon), abs=0.2)
    assert r.eteMin == round(r.distanceNm / 100 * 60)
    assert all(s.offNm <= 15 and 0 <= s.alongNm <= r.distanceNm for s in r.corridor)
    assert [s.alongNm for s in r.corridor] == sorted(s.alongNm for s in r.corridor)
    assert all(s.id not in ("KI67", "KILN") for s in r.corridor)
    again = await service.get_route("KI67", "KILN", speed_kt=100)
    assert again is r or again == r                      # held five minutes


@pytest.mark.asyncio
async def test_the_route_endpoint_checks_its_ids(client):
    from app.main import app
    app.state.service = PressureService(client)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        assert (await c.get("/route?from=KI67&to=../x")).status_code == 422
        ok = await c.get("/route?from=KI67&to=KILN&speedKt=120")
        assert ok.status_code == 200 and ok.json()["dep"]["station"] == "KI67"
