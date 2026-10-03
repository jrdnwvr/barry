"""/radar/field: the radar's wind grid. A held run is covered in
test_radar_timeline (the shared lattice) and test_hrrr_feed; here, the
grid with no run held, and how long a grid is kept."""

from __future__ import annotations

import pytest

from app.service import PressureService


@pytest.mark.asyncio
async def test_no_run_held_gives_no_points_and_logs_it(client, upstream):
    service = PressureService(client)
    resp = await service.get_field_grid(39.1, -84.5, 3.0, 3.0)
    assert resp.points == [] and resp.source is None
    assert ("field", "off", "39.1,-84.5") in {(e["kind"], e["reason"], e["where"]) for e in service.fallbacks.events()}


def test_grids_are_held_until_just_past_the_next_model_hour(monkeypatch):
    from datetime import datetime, timezone
    from app import service as svc
    monkeypatch.setattr(svc, "_now", lambda: datetime(2026, 9, 24, 14, 20, tzinfo=timezone.utc))
    assert svc._until_model_hour() == 45 * 60
    monkeypatch.setattr(svc, "_now", lambda: datetime(2026, 9, 24, 14, 58, tzinfo=timezone.utc))
    assert svc._until_model_hour() == svc.FIELD_TTL   # never under ten minutes
