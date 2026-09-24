"""AWC advisories: SIGMETs, G-AIRMETs, PIREPs, parsed from real feeds and
cut to a map box."""

from __future__ import annotations

import json
import os

import pytest

from app.service import PressureService
from app.sources import advisories as adv

FIX = os.path.join(os.path.dirname(__file__), "fixtures")


def _load(name):
    with open(os.path.join(FIX, name), encoding="utf-8") as fh:
        return json.load(fh)


def test_convective_sigmets_parse_with_outline_and_tops():
    areas = adv.parse_sigmets(_load("awc_airsigmet.json"))
    assert areas and all(a.kind == "convective" for a in areas)
    a = areas[0]
    assert a.label.startswith("Convective SIGMET") and len(a.points) >= 3
    assert a.topFt == 43000 and a.validTo > a.validFrom
    assert "CONVECTIVE SIGMET" in (a.raw or "")


def test_gairmets_keep_areas_at_the_current_hour_and_skip_freezing_lines():
    areas = adv.parse_gairmets(_load("awc_gairmet.json"))
    hazards = {a.hazard for a in areas}
    assert "IFR" in hazards and "FZLVL" not in hazards
    turb = next(a for a in areas if a.hazard == "TURB-LO")
    assert turb.baseFt == 5000 and turb.topFt == 22000 and turb.label == "AIRMET Turb"
    ifr = next(a for a in areas if a.hazard == "IFR")
    assert ifr.raw and "CIG BLW 010" in ifr.raw


def test_pireps_keep_turbulence_and_icing_reports_only():
    raw = _load("awc_pirep.json")
    reps = adv.parse_pireps(raw)
    assert reps and len(reps) < len(raw)
    assert all(r.turbulence or r.icing for r in reps)
    assert any(r.turbulence == "MOD" for r in reps)
    assert all(r.altFt is None or r.altFt % 100 == 0 for r in reps)


@pytest.mark.asyncio
async def test_the_slice_holds_what_touches_the_box_and_pulls_once(client, upstream):
    service = PressureService(client)
    everywhere = await service.get_advisories(39.0, -98.0, half=30.0)
    assert everywhere.areas and everywhere.pireps
    near = await service.get_advisories(39.1, -84.5, half=3.0)
    assert near.pireps and all(36.0 <= p.lat <= 42.2 for p in near.pireps)
    far = await service.get_advisories(30.0, -112.0, half=2.0)   # the fixture's reports are all near Cincinnati
    assert far.pireps == []
    await service.get_advisories(40.0, -90.0, half=6.0)
    assert upstream.adv_calls == 3            # one per feed, shared by every later slice


@pytest.mark.asyncio
async def test_a_down_feed_gives_an_empty_layer_not_an_error(client, upstream):
    upstream.adv_fail = True
    service = PressureService(client)
    resp = await service.get_advisories(39.1, -84.5)
    assert resp.areas == [] and resp.pireps == []
