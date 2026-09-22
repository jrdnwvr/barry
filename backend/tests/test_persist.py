import gzip
import json
import pickle
from datetime import datetime, timezone

from app import persist


def test_round_trip_keeps_datetimes_and_nesting(tmp_path, monkeypatch):
    monkeypatch.setenv("BARRY_DATA_DIR", str(tmp_path))
    t = datetime(2026, 9, 21, 20, 0, tzinfo=timezone.utc)
    obj = {"KLUK": [{"t": t, "trend": "falling", "confidence": 0.7, "right": None}]}
    assert persist.save("track_log", obj)
    assert (tmp_path / "track_log.json.gz").exists()
    back = persist.load("track_log")
    assert back == obj and isinstance(back["KLUK"][0]["t"], datetime)
    # nothing but JSON on disk
    with gzip.open(tmp_path / "track_log.json.gz") as f:
        json.loads(f.read())


def test_legacy_pickle_is_migrated_once_then_gone(tmp_path, monkeypatch):
    monkeypatch.setenv("BARRY_DATA_DIR", str(tmp_path))
    with open(tmp_path / "registry.pkl", "wb") as f:
        pickle.dump(["KLUK", "KCVG"], f)
    assert persist.load("registry") == ["KLUK", "KCVG"]
    assert not (tmp_path / "registry.pkl").exists()
    assert (tmp_path / "registry.json.gz").exists()
    assert persist.load("registry") == ["KLUK", "KCVG"]


def test_unstorable_objects_fail_closed(tmp_path, monkeypatch):
    monkeypatch.setenv("BARRY_DATA_DIR", str(tmp_path))
    assert persist.save("x", {"f": lambda: 1}) is False
    assert persist.load("x") is None
