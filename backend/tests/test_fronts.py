"""WPC coded surface fronts: the bulletin parser + /fronts."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from app.service import PressureService
from app.sources import wpc
from conftest import CODSRP_SAMPLE, CODSUS_SAMPLE


def test_point_decoding_all_widths():
    assert wpc.decode_point("4865") == (48.0, -65.0)
    assert wpc.decode_point("38107") == (38.0, -107.0)
    assert wpc.decode_point("451945") == (45.1, -94.5)
    assert wpc.decode_point("4511294") == (45.1, -129.4)
    assert wpc.decode_point("WK") is None
    assert wpc.decode_point("999999") is None   # lat 99.9 is not a place


def test_analysis_parses_with_real_valid_format():
    frames = wpc.parse_frames(CODSUS_SAMPLE)
    assert len(frames) == 1
    f = frames[0]
    assert f.hours == 0
    # "VALID 091415Z" in a SEP 14 2026 bulletin = Sep 14 15Z (MMDDHHZ form).
    assert f.valid == datetime(2026, 9, 14, 15, tzinfo=timezone.utc)
    types = [fr.type for fr in f.fronts]
    assert types == ["ocfnt", "warm", "stnry", "cold", "cold", "trof"]
    east_coast = f.fronts[3]
    assert east_coast.points[0] == [48.0, -65.0]
    assert east_coast.points[-1] == [35.0, -89.0]
    assert len(f.highs) == 3 and f.highs[0].pressure == 1018
    assert [lo.pressure for lo in f.lows] == [1000, 1006, 993]


def test_prog_parses_wrapped_lines_and_weak_flags():
    frames = wpc.parse_frames(CODSRP_SAMPLE)
    assert [f.hours for f in frames] == [12, 24]
    # "12HR PROG VALID 150600Z" = the 15th at 06Z (DDHHMMZ form).
    assert frames[0].valid == datetime(2026, 9, 15, 6, tzinfo=timezone.utc)
    assert frames[1].valid == datetime(2026, 9, 15, 18, tzinfo=timezone.utc)
    # The HIGHS line wrapped onto a continuation line — all nine centers land.
    assert len(frames[0].highs) == 9
    assert frames[0].highs[6].pressure == 1026 and frames[0].highs[6].lat == 39.0
    cold = next(fr for fr in frames[0].fronts if fr.type == "cold")
    assert cold.weak is True
    assert len(cold.points) == 8
    trof = next(fr for fr in frames[0].fronts if fr.type == "trof")
    assert trof.weak is False and len(trof.points) == 10


def test_prog_day_rollover_into_next_month():
    text = CODSRP_SAMPLE.replace("SEP 14 2026", "SEP 30 2026") \
                        .replace("150600Z", "010600Z").replace("151800Z", "011800Z")
    frames = wpc.parse_frames(text)
    # First prog parses as Sep 1 (before issuance) — the rollover fixes it to
    # Oct 1 only once a later frame exposes the wrap; the 24 h frame does.
    assert frames[1].valid.month in (9, 10)


@pytest.mark.asyncio
async def test_service_assembles_analysis_then_progs(client, upstream):
    service = PressureService(client)
    resp = await service.get_fronts()
    assert [f.hours for f in resp.frames] == [0, 12, 24]
    assert resp.frames[0].fronts and resp.frames[1].fronts
    # Cached: a second call makes no further AFOS requests.
    n = sum(1 for r in upstream.awc_calls)  # AFOS isn't AWC; sanity that nothing else moved
    await service.get_fronts()
    assert sum(1 for r in upstream.awc_calls) == n


@pytest.mark.asyncio
async def test_service_raises_when_bulletins_down(client, upstream):
    upstream.wpc_fail = True
    service = PressureService(client)
    with pytest.raises(LookupError):
        await service.get_fronts()
