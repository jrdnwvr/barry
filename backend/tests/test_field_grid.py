"""/radar/field: the radar's wind + boundary-layer grid via the backend."""

from __future__ import annotations

import pytest

from app.service import PressureService


@pytest.mark.asyncio
async def test_grid_is_7x5_from_one_call_with_current_hour_bl(client, upstream):
    service = PressureService(client)
    resp = await service.get_field_grid(39.1, -84.5, 3.0, 3.0)
    assert len(resp.points) == 35
    assert len(upstream.om_calls) == 1
    req = upstream.om_calls[0]
    assert req.url.params["current"] == "wind_speed_10m,wind_direction_10m"
    assert req.url.params["hourly"] == "boundary_layer_height,cape"
    p = resp.points[0]
    assert p.windKmh == 10.0 and p.windDeg == 240.0
    assert p.blM == 900.0                      # the current hour, not another
    lats = {round(p.lat, 3) for p in resp.points}
    lons = {round(p.lon, 3) for p in resp.points}
    assert len(lats) == 5 and len(lons) == 7   # rows x cols
    # Grid is inset 12% inside the region.
    assert min(lats) == pytest.approx(39.1 - 3.0 * 0.38, abs=1e-3)
    assert max(lons) == pytest.approx(-84.5 + 3.0 * 0.38, abs=1e-3)


@pytest.mark.asyncio
async def test_nearby_regions_share_one_upstream_call(client, upstream):
    service = PressureService(client)
    await service.get_field_grid(39.10, -84.50, 3.0, 3.0)
    await service.get_field_grid(39.12, -84.51, 3.2, 2.9)     # quantizes to the same cell
    assert len(upstream.om_calls) == 1
    await service.get_field_grid(40.10, -84.50, 3.0, 3.0)     # a real move
    assert len(upstream.om_calls) == 2


@pytest.mark.asyncio
async def test_upstream_failure_surfaces(client, upstream):
    upstream.om_fail = True
    with pytest.raises(Exception):
        await PressureService(client).get_field_grid(39.1, -84.5, 3.0, 3.0)


@pytest.mark.asyncio
async def test_a_failed_grid_is_not_retried_for_a_minute(client, upstream):
    from app.cache import CachedFailure
    service = PressureService(client)
    upstream.om_fail = True
    with pytest.raises(Exception):
        await service.get_field_grid(39.1, -84.5, 3.0, 3.0)
    with pytest.raises(CachedFailure):
        await service.get_field_grid(39.1, -84.5, 3.0, 3.0)
    assert len(upstream.om_calls) == 1
