"""D3: the station's TAF, decoded, on /combined."""

from __future__ import annotations

import pytest

from app.service import PressureService


@pytest.mark.asyncio
async def test_taf_periods_decoded(client, upstream):
    combined = await PressureService(client).get_combined("KLUK")
    taf = combined.taf
    assert taf is not None and taf.station == "KLUK" and taf.raw.startswith("TAF KLUK")
    assert taf.issueTime is not None and taf.issueTime.hour == 17     # ISO string parsed
    assert [p.change for p in taf.periods] == [None, "FM", "TEMPO", "FM"]
    fm = taf.periods[1]
    assert fm.windDir == 310 and fm.windKt == 15 and fm.gustKt == 25
    assert fm.ceilingFt == 4000 and fm.ceilingCover == "BKN" and fm.fltCat == "VFR"
    tempo = taf.periods[2]
    assert tempo.visibilitySM == 4 and tempo.wx == "-RA BR" and tempo.fltCat == "MVFR"
    assert tempo.windDir is None


@pytest.mark.asyncio
async def test_taf_cached_and_absent_stations_cached_too(client, upstream):
    service = PressureService(client)
    await service.get_taf("KLUK"); await service.get_taf("KLUK")
    assert upstream.taf_calls == 1
    assert await service.get_taf("KI69") is None
    assert await service.get_taf("KI69") is None
    assert upstream.taf_calls == 2                     # the "none issued" answer is cached


@pytest.mark.asyncio
async def test_taf_failure_never_blocks_combined(client, upstream):
    upstream.taf_fail = True
    combined = await PressureService(client).get_combined("KLUK")
    assert combined.taf is None and combined.verdict
