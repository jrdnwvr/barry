"""Lightning decoded from the METAR body and remarks (lightning.py)."""

from __future__ import annotations

from datetime import datetime, timezone

from app import lightning
from app.sources.aviationweather import parse_metar_cache
from conftest import METAR_CACHE_HEADER

OBS = datetime(2026, 9, 16, 19, 53, tzinfo=timezone.utc)


def test_thunderstorm_in_the_body_with_remarks():
    lt = lightning.parse("KLUK 161953Z 24012G22KT 3SM +TSRA BR BKN025CB OVC040 24/21 A2992 "
                         "RMK AO2 TSB42 FRQ LTGICCG OHD TS OHD MOV NE P0021", "+TSRA BR", OBS)
    assert lt.status == "thunderstorm"
    assert lt.frequency == "frequent"
    assert lt.types == ["IC", "CG"]
    assert lt.moving == "NE"
    assert lt.since == OBS.replace(minute=42)


def test_vicinity_and_distant():
    vc = lightning.parse("KCVG 161952Z 18008KT 10SM VCTS SCT040 28/20 A2995 RMK AO2 LTG DSNT SW-NW",
                         "VCTS", OBS)
    assert vc.status == "vicinity" and vc.directions == ["SW-NW"]
    d = lightning.parse("KILN 161953Z 20006KT 10SM CLR 27/19 A2996 RMK AO2 LTG DSNT ALQDS", None, OBS)
    assert d.status == "distant" and d.directions == ["ALQDS"] and d.since is None
    # No qualifier at all: reported lightning counts as close by.
    n = lightning.parse("KXYZ 161953Z 20006KT 10SM CLR 27/19 A2996 RMK OCNL LTGIC W", None, OBS)
    assert n.status == "vicinity" and n.frequency == "occasional" and n.directions == ["W"]


def test_ended_sensor_out_and_quiet_say_nothing():
    assert lightning.parse("KLUK 161953Z 24012KT 10SM SCT040 24/21 A2992 RMK AO2 TSB05E31", None, OBS) is None
    assert lightning.parse("KLUK 161953Z 24012KT 10SM SCT040 24/21 A2992 RMK AO2 TSNO", None, OBS) is None
    assert lightning.parse("KLUK 161953Z 24012KT 10SM SCT040 24/21 A2992 RMK AO2 SLP132", None, OBS) is None
    assert lightning.parse(None, None, OBS) is None


def test_began_minute_after_the_observation_means_last_hour():
    lt = lightning.parse("KLUK 161953Z 24012KT 3SM TSRA BKN025 24/21 A2992 RMK AO2 TSB58", "TSRA", OBS)
    assert lt.since == OBS.replace(hour=18, minute=58)
    lt = lightning.parse("KLUK 161953Z 24012KT 3SM TSRA BKN025 24/21 A2992 RMK AO2 TSB1815", "TSRA", OBS)
    assert lt.since == OBS.replace(hour=18, minute=15)


def test_bulk_cache_rows_carry_lightning():
    row = ('"METAR KDAY 161953Z 22010KT 5SM TSRA BKN030CB 25/21 A2990 RMK AO2 LTGICCG VC S",KDAY,'
           '2026-09-16T19:53:00.000Z,39.9020,-84.2190,25,21,220,10,,5,29.90,,,,TRUE,,,,,,TSRA,BKN,3000,,,,,,,'
           'MVFR,,,,,,,,,,,,METAR,306')
    obs = parse_metar_cache(METAR_CACHE_HEADER + "\n" + row + "\n")
    assert len(obs) == 1
    assert obs[0].wx == "TSRA"
    assert obs[0].lightning.status == "thunderstorm"
    assert obs[0].lightning.types == ["IC", "CG"]


def test_nearest_lightning_prefers_a_storm_over_distant_flashes():
    from datetime import timedelta
    from app.models import LightningOut, StationObs
    now = OBS
    def st(sid, lat, lon, status, moving=None, age_min=10):
        return StationObs(id=sid, lat=lat, lon=lon, obsTime=now - timedelta(minutes=age_min),
                          lightning=LightningOut(status=status, moving=moving))
    table = [
        st("KNEAR", 39.20, -84.42, "distant"),                 # ~11 km north
        st("KSTORM", 39.30, -84.62, "thunderstorm", "SE"),     # ~28 km NW, moving SE
        st("KOLD", 39.12, -84.40, "thunderstorm", age_min=200),  # stale
        st("KFAR", 41.50, -84.42, "thunderstorm"),             # 266 km, out of range
    ]
    n = lightning.nearest(table, 39.103, -84.419, now)
    assert n.station == "KSTORM" and n.status == "thunderstorm"
    assert n.cardinal == "NW" and 15 <= n.distanceMi <= 20
    assert n.towardYou is True                                 # SE-bound storm to the NW
    table[1] = st("KSTORM", 39.30, -84.62, "thunderstorm", "NW")
    assert lightning.nearest(table, 39.103, -84.419, now).towardYou is False
    table[1] = st("KSTORM", 39.30, -84.62, "thunderstorm", "NE")
    assert lightning.nearest(table, 39.103, -84.419, now).towardYou is None
    assert lightning.nearest(table[2:], 39.103, -84.419, now) is None


def test_bulk_row_without_a_category_gets_one_derived_and_flagged():
    row = ('"METAR KFKR 170155Z AUTO 13004KT OVC041 23/22 A3025 RMK AO2 PWINO",KFKR,'
           '2026-09-17T01:55:00.000Z,40.2730,-86.5620,23,22,130,4,,,30.25,,,,TRUE,,,,,,,OVC,4100,,,,,,,'
           ',,,,,,,,,,,,METAR,262')
    obs = parse_metar_cache(METAR_CACHE_HEADER + "\n" + row + "\n")
    assert obs[0].fltCat == "VFR" and obs[0].fltCatDerived is True      # ceiling 4,100 ft, no visibility
    assert obs[0].visibilitySM is None
    # A reported category is never marked derived.
    full = parse_metar_cache(METAR_CACHE_HEADER + "\n" + row.replace(",,,,,,,,,,,,METAR", "MVFR,,,,,,,,,,,,METAR", 1) + "\n")
    assert full[0].fltCat == "MVFR" and full[0].fltCatDerived is False
