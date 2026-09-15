"""Runway table + crosswind inputs on /combined, and the App Store pages."""

from __future__ import annotations

import pytest

from app import runways
from app.main import privacy_page, support_page
from app.service import PressureService


def test_known_airport_has_true_headings():
    rws = runways.for_station("kluk")
    idents = {(r.le, r.he) for r in rws}
    assert ("03R", "21L") in idents
    for r in rws:
        assert 0 <= r.leHeading < 360 and 0 <= r.heHeading < 360
        # Reciprocal ends face opposite ways: the difference is ~180.
        assert abs((r.heHeading - r.leHeading) % 360 - 180) < 15


def test_longest_first_and_unknown_is_empty():
    rws = runways.for_station("KCVG")
    lengths = [r.lengthFt or 0 for r in rws]
    assert lengths == sorted(lengths, reverse=True)
    assert runways.for_station("ZZZZ") == []


@pytest.mark.asyncio
async def test_combined_carries_runways(client):
    service = PressureService(client)
    combined = await service.get_combined("KLUK")
    assert combined.runways, "KLUK should have runways"
    first = combined.runways[0]
    assert first.le and first.he and first.lengthFt


@pytest.mark.asyncio
async def test_privacy_and_support_pages():
    for page in (privacy_page, support_page):
        resp = await page()
        assert resp.media_type == "text/html"
        assert "Barry" in open(resp.path, encoding="utf-8").read()
