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


def test_awos_method_matches_the_broadcast_rule_of_thumb():
    # Sea level, 35 °C: 20 °C above ISA -> 2,400 ft, dry, no humidity term.
    assert abs(conditions.density_altitude_awos_ft(1013.25, 35.0) - 2400) < 5
    assert abs(conditions.density_altitude_awos_ft(1013.25, 15.0)) < 1
    # Denver-ish field on a standard day reads its own pressure altitude.
    sp = conditions.station_pressure_hpa(1013.25, 1655.0)
    pa = conditions.pressure_altitude_ft(sp)
    assert abs(pa - 1655.0 * 3.28084) < 60
    assert abs(conditions.density_altitude_awos_ft(sp, 15.0 - 0.0065 * 1655.0) - pa) < 5


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


def test_station_metadata_survives_a_sparse_newest_report():
    # A SPECI without elev/lat/lon must not erase the elevation the hourly
    # reports carry — that blanked the density-altitude card in production.
    from app.sources.aviationweather import parse_records
    from conftest import _metar_record

    full = _metar_record("KLUK", 1_700_000_000, 1012.0, altim=1012.7)
    sparse = _metar_record("KLUK", 1_700_003_600, 1011.8, altim=1012.5)
    for k in ("elev", "lat", "lon", "name"):
        sparse[k] = None
    parsed = parse_records([full, sparse])["KLUK"]
    assert parsed["elev"] == 147.0
    assert parsed["lat"] == 39.103 and parsed["name"] == "Test Field"
    assert parsed["current"].altim == 1012.5   # current obs still the newest


# ---- integration -------------------------------------------------------------


@pytest.mark.asyncio
async def test_combined_carries_conditions(client, upstream):
    service = PressureService(client)
    resp = await service.get_combined("KLUK")
    c = resp.conditions
    assert c is not None
    # METAR fixture: 27°C / 18°C dew point, altim ~1010 hPa, 147 m elevation.
    assert c.fieldElevationFt == pytest.approx(482, abs=2)
    assert 1800 <= c.densityAltitudeFt <= 2400          # AWOS method, dry
    assert c.densityAltitudeHumidFt >= c.densityAltitudeFt   # dew point 18 °C adds a little
    assert len(c.daForecast) >= 6      # forecast hours carry temp/dew/pressure
    # Fixture night is 55% cloud with a widening spread: honest silence.
    assert c.fog is None
    # Every sky layer rides along for the clouds row, lowest first.
    layers = [(l.cover, l.baseFt) for l in resp.pressure.current.clouds]
    assert layers == [("SCT", 2500), ("BKN", 4500)]


def test_clear_sky_is_a_layer_not_an_absence():
    from app.sources.aviationweather import _cloud_layers
    raw = "METAR KLUK 170053Z 00000KT 10SM CLR 26/23 A3026 RMK AO2 LTG DSNT NW"
    assert [l.cover for l in _cloud_layers([], raw)] == ["CLR"]        # AWC sends [] for CLR
    assert _cloud_layers([], "METAR KXYZ 170053Z 00000KT 10SM 26/23 A3026") == []
    assert [(l.cover, l.baseFt) for l in _cloud_layers([{"cover": "OVC", "base": 800}], raw)] == [("OVC", 800)]


# ---- boundary layer + storm outlook -------------------------------------------


def _hours(n, **kw):
    out = []
    for i in range(n):
        vals = {k: (v[i] if isinstance(v, list) else v) for k, v in kw.items()}
        out.append(ForecastHour(t=T0 + timedelta(hours=i), **vals))
    return out


def test_boundary_layer_now_and_forecast_in_hundreds_of_feet():
    hrs = _hours(16, boundary_layer=[300.0 + 150.0 * i for i in range(16)])
    now_ft, fc = conditions.boundary_layer(hrs, T0 + timedelta(minutes=20))
    assert now_ft == 1000                          # 300 m -> 984 ft -> 1000
    assert len(fc) == 12 and fc[-1].ft == 6900     # 12 h window, 100 ft steps
    assert conditions.boundary_layer(_hours(3), T0) == (None, [])


def test_storm_outlook_thunder_code_is_likely_and_cape_alone_says_nothing():
    codes = [1] * 12
    codes[5] = 95
    hrs = _hours(12, weather_code=codes, cape=[200.0 + 100.0 * i for i in range(12)])
    st = conditions.scan_storms(hrs, None, T0)
    assert st.risk == "likely" and st.start == T0 + timedelta(hours=5) and st.source == "model"
    assert st.end == T0 + timedelta(hours=6) and st.capeMax == 1300
    # A warm afternoon with fuel and nothing to set it off: silence.
    quiet = _hours(12, weather_code=1, cape=[200.0 + 120.0 * i for i in range(12)])
    assert conditions.scan_storms(quiet, None, T0) is None
    # Fuel plus showers under a weak cap: possible, at that hour.
    codes = [1] * 12
    codes[7] = 80
    trig = _hours(12, weather_code=codes, cape=1400.0, cin=-10.0)
    st = conditions.scan_storms(trig, None, T0)
    assert st.risk == "possible" and st.start == T0 + timedelta(hours=7)
    # The same hour under a strong cap: nothing.
    capped = _hours(12, weather_code=codes, cape=1400.0, cin=-120.0)
    assert conditions.scan_storms(capped, None, T0) is None
    assert conditions.scan_storms(_hours(12, weather_code=1, cape=300.0), None, T0) is None


def test_storm_outlook_leads_with_observed_lightning():
    from app.models import LightningNearby
    near = LightningNearby(station="GLM", distanceMi=40, bearingDeg=270.0, cardinal="W", status="strikes",
                           at=T0, moving="E", towardYou=True, source="glm", flashes=120,
                           speedKmh=40.0, etaAt=T0 + timedelta(hours=1.6))
    codes = [1] * 12
    codes[4] = 95
    hrs = _hours(12, weather_code=codes, cape=900.0)
    st = conditions.scan_storms(hrs, None, T0, nearby=near)
    assert st.risk == "observed" and st.distanceMi == 40 and st.cardinal == "west"
    assert st.etaAt == near.etaAt and st.towardYou is True and st.source == "glm"
    assert st.forecastStart == T0 + timedelta(hours=4)      # more expected later
    away = near.model_copy(update={"towardYou": False, "etaAt": None, "moving": "W"})
    assert "away" in conditions.scan_storms(hrs, None, T0, nearby=away).detail


def test_storm_outlook_takes_the_taf_too():
    from app.models import TafOut, TafPeriod
    taf = TafOut(station="KLUK", periods=[
        TafPeriod(timeFrom=T0 + timedelta(hours=3), timeTo=T0 + timedelta(hours=6),
                  change="TEMPO", wx="TSRA"),
    ])
    st = conditions.scan_storms(_hours(12, weather_code=1, cape=300.0), taf, T0)
    assert st.risk == "likely" and st.source == "taf"
    assert st.start == T0 + timedelta(hours=3) and st.end == T0 + timedelta(hours=6)
    # A TAF thunderstorm that already ended says nothing.
    old = TafOut(station="KLUK", periods=[
        TafPeriod(timeFrom=T0 - timedelta(hours=6), timeTo=T0 - timedelta(hours=2), change="TEMPO", wx="TSRA")])
    assert conditions.scan_storms(_hours(12, weather_code=1, cape=300.0), old, T0) is None


# ---- ride estimate --------------------------------------------------------------


def test_summer_afternoon_is_bumpy_thermal_and_settles_at_dusk():
    # Strong sun, superadiabatic lowest layer, deep layer, light wind until
    # hour 6; then the sun goes and the lapse flips to an inversion.
    hrs = _hours(12,
                 radiation=[700.0] * 6 + [50.0] * 6,
                 temperature=[31.0] * 6 + [24.0] * 6,
                 temp180m=[28.5] * 6 + [25.0] * 6,          # 14 °C/km, then inversion
                 boundary_layer=[1800.0] * 6 + [200.0] * 6,
                 windspeed=8.0, windgust=15.0, wind80m=12.0)
    r = conditions.ride(hrs, T0)
    assert r.band == "bumpy" and r.kind == "thermal" and r.topFt == 5900
    assert r.changeBand == "smooth" and r.changeAt == T0 + timedelta(hours=6)


def test_windy_winter_day_is_chop_from_wind_not_thermals():
    hrs = _hours(12, radiation=120.0, temperature=2.0, temp180m=1.5,     # 2.8 °C/km: stable
                 boundary_layer=900.0, windspeed=30.0, windgust=48.0, wind80m=52.0)
    r = conditions.ride(hrs, T0)
    assert r.kind == "wind" and r.band in ("chop", "bumpy") and r.thermal == 0.0
    assert r.changeBand is None


def test_calm_night_is_smooth_and_missing_inputs_give_nothing():
    hrs = _hours(12, radiation=0.0, temperature=10.0, temp180m=12.0, boundary_layer=150.0,
                 windspeed=5.0, windgust=8.0, wind80m=9.0)
    r = conditions.ride(hrs, T0)
    assert r.band == "smooth" and r.score == 0.0
    assert conditions.ride(_hours(12, windspeed=5.0), T0) is None or conditions.ride(_hours(12), T0) is None
