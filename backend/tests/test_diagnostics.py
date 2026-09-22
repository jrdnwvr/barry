"""The diagnostics drop box: bounded, JSON only, files pruned, gated."""
import gzip
import json

import httpx
import pytest

from app import diagnostics
from app.guards import RateGate
from app.service import PressureService


@pytest.fixture
async def api(client, tmp_path, monkeypatch):
    from app.main import app
    import app.main as main_mod
    monkeypatch.setenv("BARRY_DATA_DIR", str(tmp_path))
    monkeypatch.setattr(main_mod, "_diag_gate", RateGate(per_minute=30))
    app.state.service = PressureService(client)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app, raise_app_exceptions=False),
                                 base_url="http://t") as c:
        yield c, tmp_path


@pytest.mark.asyncio
async def test_a_payload_is_stored_gzipped_by_kind(api):
    c, root = api
    body = {"metaData": {"appBuildVersion": "87"}, "applicationLaunchMetrics": {}}
    r = await c.post("/diagnostics", content=json.dumps(body), headers={"X-Barry-Kind": "diagnostic"})
    assert r.status_code == 202 and r.content == b""
    files = list((root / "diagnostics").glob("*-diagnostic-*.json.gz"))
    assert len(files) == 1
    assert json.loads(gzip.decompress(files[0].read_bytes())) == body
    r = await c.post("/diagnostics", content=json.dumps(body), headers={"X-Barry-Kind": "../etc"})
    assert r.status_code == 202
    assert len(list((root / "diagnostics").glob("*-metric-*.json.gz"))) == 1


@pytest.mark.asyncio
async def test_junk_and_oversize_are_refused_before_the_disk(api):
    c, root = api
    assert (await c.post("/diagnostics", content=b"not json")).status_code == 400
    big = b'{"a": "' + b"x" * diagnostics.DIAG_MAX_BYTES + b'"}'
    assert (await c.post("/diagnostics", content=big)).status_code == 413
    assert not list((root / "diagnostics").glob("*")) if (root / "diagnostics").exists() else True


@pytest.mark.asyncio
async def test_the_box_writes_a_bounded_number_a_minute(api):
    c, _ = api
    codes = [(await c.post("/diagnostics", content=b"{}")).status_code for _ in range(32)]
    assert codes[:30] == [202] * 30 and codes[30:] == [503, 503]


def test_prune_keeps_the_newest(tmp_path):
    for day in range(1, 13):
        (tmp_path / f"202609{day:02d}T000000-metric-{day:08x}.json.gz").write_bytes(b"x")
    assert diagnostics.prune(tmp_path, keep=10) == 2
    left = sorted(p.name for p in tmp_path.glob("*.json.gz"))
    assert len(left) == 10 and left[0].startswith("20260903") and left[-1].startswith("20260912")
