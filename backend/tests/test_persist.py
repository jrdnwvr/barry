"""E6: bulk history survives a restart when BARRY_DATA_DIR is set."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app import persist
from app.service import PressureService
from test_front_history import ring_table


def test_history_roundtrip_through_disk(client, tmp_path, monkeypatch):
    monkeypatch.setenv("BARRY_DATA_DIR", str(tmp_path))
    now = datetime.now(timezone.utc)
    a = PressureService(client)
    a._record_snapshot(ring_table(now - timedelta(hours=2), 0), now - timedelta(hours=2))
    a._record_snapshot(ring_table(now, 1), now)
    assert (tmp_path / "bulk_history.pkl").exists()

    b = PressureService(client)                    # "after a restart"
    assert len(b._bulk_history) == 2
    assert b.history_span_h(now) == 2.0


def test_no_data_dir_means_cold_start(client, monkeypatch):
    monkeypatch.delenv("BARRY_DATA_DIR", raising=False)
    assert persist.save("x", 1) is False and persist.load("x") is None
    assert PressureService(client)._bulk_history == []
