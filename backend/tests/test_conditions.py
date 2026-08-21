"""Field conditions: density altitude physics + the radiation fog scan."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app import conditions
from app.models import ForecastHour, SunTimes
from app.service import PressureService

T0 = datetime(2026, 8, 21, 0, 0, tzinfo=timezone.utc)


# ---- density altitude physics ------------------------------------------------


def test_isa_sea_level_is_zero():
    # 1013.25 hPa, 15°C, bone dry -> the definition of zero density altitude.
    da = conditions.density_altitude_ft(1013.25, 15.0, -40.0)
    assert abs(da) < 100


def test_hot_humid_sea_level_day():
    # 35°C / dew point 25°C at sea level: rule-of-thumb says ~2400 ft from
    # temperature alone; humidity adds a couple hundred more.
    da = conditions.density_altitude_ft(1013.25, 35.0, 25.0)
    assert 2400 <= da <= 2900


def test_standard_day_at_altitude_reads_field_elevation():
    # Denver-ish field on an ISA-standard day: DA should equal the elevation.
    elev_m = 1655.0
    sp = conditions.station_pressure_hpa(1013.25, elev_m)
    isa_temp = 15.0 - 0.0065 * elev_m
    da = conditions.density_altitude_ft(sp, isa_temp, -30.0)
    assert abs(da - elev_m * 3.28084) < 150


def test_humidity_always_raises_da():
    dry = conditions.density_altitude_ft(1013.25, 30.0, -20.0)
    humid = conditions.density_altitude_ft(1013.25, 30.0, 24.0)
    assert humid > dry + 100


# ---- fog scan ----------------------------------------------------------------


def hour(i, temp, dew, wind=5.0, cloud=10.0, precip=0):
    return ForecastHour(t=T0 + timedelta(hours=i), temperature=temp,
                        dewpoint=dew, windspeed=wind, cloudcover=cloud,
                        precip_prob=precip, surface_pressure=1008.0)


SUN = SunTimes(sunset=[T0 + timedelta(hours=1)],
               sunrise=[T0 + timedelta(hours=11)])


def test_classic_radiation_night_is_likely():
    hours = [hour(i, 15.0 - 0.4 * i, 14.0 - 0.3 * i) for i in range(14)]
    fog = conditions.scan_fog(hours, SUN, T0)
    assert fog is not None
    assert fog.risk == "likely"
    assert fog.onset is not None


def test_marginal_night_is_possible():
    # Spread hovers near the loose bar for only a couple of hours.
    hours = [hour(i, 18.0, 16.0, wind=9.0, cloud=35.0) for i in range(3)]
    hours += [hour(i, 20.0, 14.0) for i in range(3, 14)]
    fog = conditions.scan_fog(hours, SUN, T0)
    assert fog is not None
    assert fog.risk == "possible"


def test_wind_kills_it():
    hours = [hour(i, 15.0, 14.5, wind=20.0) for i in range(14)]
    assert conditions.scan_fog(hours, SUN, T0) is None


def test_overcast_kills_it():
    hours = [hour(i, 15.0, 14.5, cloud=85.0) for i in range(14)]
    assert conditions.scan_fog(hours, SUN, T0) is None


def test_rainy_night_stays_quiet():
    hours = [hour(i, 15.0, 14.5, precip=70) for i in range(14)]
    assert conditions.scan_fog(hours, SUN, T0) is None


def test_dry_night_stays_quiet():
    hours = [hour(i, 20.0, 8.0) for i in range(14)]
    assert conditions.scan_fog(hours, SUN, T0) is None


def test_burn_off_estimate_after_sunrise():
    # Tight all night, then the spread reopens two hours after sunrise (11 h).
    hours = [hour(i, 14.0, 13.5) for i in range(13)]
    hours += [hour(13, 18.0, 13.0), hour(14, 21.0, 13.0)]
    fog = conditions.scan_fog(hours, SUN, T0)
    assert fog is not None
    assert fog.clearing == T0 + timedelta(hours=13)


def test_no_sun_data_no_call():
    hours = [hour(i, 14.0, 13.5) for i in range(14)]
    assert conditions.scan_fog(hours, None, T0) is None


# ---- integration -------------------------------------------------------------


@pytest.mark.asyncio
async def test_combined_carries_conditions(client, upstream):
    service = PressureService(client)
    resp = await service.get_combined("KLUK")
    c = resp.conditions
    assert c is not None
    # METAR fixture: 27°C / 18°C dew point, altim ~1010 hPa, 147 m elevation.
    assert c.fieldElevationFt == pytest.approx(482, abs=2)
    assert 2000 <= c.densityAltitudeFt <= 2700
    assert len(c.daForecast) >= 6      # forecast hours carry temp/dew/pressure
    # Fixture night is 55% cloud with a widening spread: honest silence.
    assert c.fog is None
