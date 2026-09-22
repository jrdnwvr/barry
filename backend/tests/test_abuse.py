"""Sweeps a scraper or a bug would produce, each asserting the thing that
must stay bounded: upstream calls, cache entries, concurrent CPU work."""
import asyncio
import threading
import time

import pytest

from app import pressure_field
from app.service import PressureService


@pytest.mark.asyncio
async def test_coordinate_sweep_inside_one_cell_is_one_forecast_call(client, upstream):
    s = PressureService(client)
    for i in range(100):
        await s.get_forecast(39.10 + (i % 10) * 0.004, -84.40 - (i // 10) * 0.004)
    assert len(upstream.om_calls) == 1
    assert len([k for k in s.cache._store if k.startswith("forecast:")]) <= 2


@pytest.mark.asyncio
async def test_box_size_sweep_is_bounded_in_cache_entries(client, upstream):
    s = PressureService(client)
    for i in range(300):
        await s.get_station_obs(39.1, -84.4, half=0.5 + i * 0.097)
    assert len([k for k in s.cache._store if k.startswith("stations:")]) <= 60
    assert upstream.bulk_calls == 1
    for i in range(300):
        await s.get_lightning(39.1, -84.4, half=0.5 + i * 0.0185)
    assert len([k for k in s.cache._store if k.startswith("lightning:")]) <= 12


@pytest.mark.asyncio
async def test_span_sweep_makes_a_bounded_number_of_grids(client, upstream):
    s = PressureService(client)
    for i in range(40):
        await s.get_pressure_field(39.1, -84.4, 1.0 + i * 0.01, 1.0 + i * 0.01)
    assert len([k for k in s.cache._store if k.startswith("pfield:")]) <= 5
    assert upstream.bulk_calls == 1


@pytest.mark.asyncio
async def test_grid_builds_run_two_at_a_time(client, upstream, monkeypatch):
    s = PressureService(client)
    lock = threading.Lock()
    running = [0]
    peak = [0]
    real = pressure_field.build

    def slow(*a, **k):
        with lock:
            running[0] += 1
            peak[0] = max(peak[0], running[0])
        try:
            time.sleep(0.03)
            return real(*a, **k)
        finally:
            with lock:
                running[0] -= 1

    monkeypatch.setattr(pressure_field, "build", slow)
    await asyncio.gather(*(s.get_pressure_field(30.0 + i, -90.0, 2.0, 2.0) for i in range(6)))
    assert peak[0] == 2
