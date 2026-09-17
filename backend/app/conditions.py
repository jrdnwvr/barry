"""Field conditions — density altitude (now + forecast) and radiation fog risk.

Two small models a GA pilot actually uses, both computed from data the app
already fetches:

DENSITY ALTITUDE — via the full air-density calculation with virtual
temperature, not the flight-computer approximation (humidity is worth a few
hundred feet on a muggy day, and we have the dew point anyway):
  - now: METAR temp/dewpoint/altimeter + field elevation (altimeter setting ->
    station pressure by the standard-atmosphere reduction)
  - forecast: Open-Meteo temperature_2m / dew_point_2m / surface_pressure —
    the model reports station-level pressure directly, so no reduction at all
The point of the FORECAST is the takeoff-performance decision: "3,100 ft if
you go at 9 AM, 5,200 ft if you wait for 4 PM" turns a surprise into a choice.

RADIATION FOG — rule-based scan of the coming night: the classic recipe is a
small and closing temperature/dew-point spread, light wind, and a clear sky to
radiate under. Scored over the sunset -> sunrise window; the burn-off estimate
is the first post-sunrise hour where the spread reopens. Deliberately ONLY the
radiation-fog story: advection/precip fog are different machines and guessing
at them from these inputs would be theater. Quiet night -> no output at all
(the front-watch rule: silence is the default state).
"""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import List, Optional, Sequence, Tuple

from .models import ConditionsOut, DAPoint, FogOut, ForecastHour, RideOut, StormOut, SunTimes, TafOut

# --- Density altitude tunables -----------------------------------------------

DA_FORECAST_HOURS = 15      # enough to cover "this morning vs this afternoon"
DA_ROUND_FT = 50            # model-derived numbers shouldn't pretend to 1 ft

# --- Boundary layer + storm tunables -------------------------------------------

BL_FORECAST_HOURS = 12      # "rising to 6,500 ft by 3 PM"
BL_ROUND_FT = 100
STORM_HOURS = 12
THUNDER_CODES = {95, 96, 99}   # WMO weather codes with a thunderstorm in them
CAPE_POSSIBLE = 1000.0      # J/kg: enough fuel to say "possible" without a
                            # thunder code; a moderately unstable afternoon

# --- Ride tunables --------------------------------------------------------------
# Thermals: surface sun (W/m²) and the lapse rate between 2 m and 180 m
# (°C/km; dry adiabatic is 9.8, steeper is superadiabatic and thermals
# trigger easily), scaled by layer depth (w* grows with the cube root of
# depth). Mechanical: gusts at 10 m and the 10 m -> 80 m speed difference.
RIDE_SUN_LO, RIDE_SUN_HI = 100.0, 550.0        # W/m²: none .. strong
RIDE_LAPSE_LO, RIDE_LAPSE_HI = 4.0, 10.0       # °C/km: stable .. superadiabatic
RIDE_DEPTH_REF_M = 1500.0
RIDE_GUST_LO, RIDE_GUST_HI = 25.0, 60.0        # km/h (~13 .. 32 kt)
RIDE_SHEAR_LO, RIDE_SHEAR_HI = 10.0, 35.0      # km/h between 10 m and 80 m
RIDE_CHOP, RIDE_BUMPY = 0.25, 0.6              # score thresholds
RIDE_HOURS = 12

# --- Fog tunables -------------------------------------------------------------

FOG_SPREAD_MAX = 2.5        # °C dewpoint depression that supports fog
FOG_WIND_MAX = 10.0         # km/h — stronger mixing keeps the layer stirred
FOG_CLOUD_MAX = 40.0        # % — need a mostly clear sky to radiate under
FOG_PRECIP_MAX = 40         # % — a rainy night is a different (wetter) story
FOG_MIN_HOURS = 2           # consecutive qualifying hours to say anything
LIKELY_SPREAD = 1.5         # stricter bar for "likely"
LIKELY_CLOUD = 25.0
LIKELY_WIND = 7.0
LIKELY_HOURS = 3
CLEAR_SPREAD = 3.0          # spread reopening past this after sunrise = burn-off
CLEAR_SEARCH_H = 6          # give up on a burn-off estimate after this


# --- Density altitude ---------------------------------------------------------


def vapor_pressure_hpa(td_c: float) -> float:
    """Saturation vapor pressure at the dew point (Magnus/Tetens), hPa."""
    return 6.1078 * 10.0 ** (7.5 * td_c / (237.3 + td_c))


def station_pressure_hpa(altim_hpa: float, elev_m: float) -> float:
    """Altimeter setting -> actual station pressure (standard-atmosphere lapse)."""
    return altim_hpa * (1.0 - 0.0065 * elev_m / 288.15) ** 5.2559


def density_altitude_ft(station_hpa: float, t_c: float, td_c: float) -> float:
    """DA from station pressure + temp + dew point via virtual temperature."""
    e = vapor_pressure_hpa(td_c) * 100.0        # Pa
    p = station_hpa * 100.0                     # Pa
    tv = (t_c + 273.15) / (1.0 - (e / p) * (1.0 - 0.622))
    rho = p / (287.05 * tv)                     # kg/m³
    return 145442.16 * (1.0 - (rho / 1.225) ** 0.234969)


def _round_ft(ft: float) -> int:
    return int(round(ft / DA_ROUND_FT) * DA_ROUND_FT)


# --- Fog scan -----------------------------------------------------------------


def _hour_supports_fog(h: ForecastHour) -> Optional[bool]:
    """None = can't judge (missing inputs); else does this hour support fog."""
    if h.temperature is None or h.dewpoint is None:
        return None
    spread = h.temperature - h.dewpoint
    if spread > FOG_SPREAD_MAX:
        return False
    if h.windspeed is not None and h.windspeed > FOG_WIND_MAX:
        return False
    if h.cloudcover is not None and h.cloudcover > FOG_CLOUD_MAX:
        return False
    if h.precip_prob is not None and h.precip_prob > FOG_PRECIP_MAX:
        return False
    return True


def _hour_is_prime(h: ForecastHour) -> bool:
    spread = (h.temperature or 99) - (h.dewpoint or 0)
    return (spread <= LIKELY_SPREAD
            and (h.windspeed is None or h.windspeed <= LIKELY_WIND)
            and (h.cloudcover is None or h.cloudcover <= LIKELY_CLOUD))


def _night_windows(sun: SunTimes, now: datetime) -> List[Tuple[datetime, datetime]]:
    """(sunset, following sunrise + 2h) pairs that haven't fully ended yet."""
    windows = []
    for ss in sun.sunset:
        sr = next((s for s in sun.sunrise if s > ss), None)
        if sr is None:
            continue
        end = sr + timedelta(hours=2)
        if end > now:
            windows.append((ss, end))
    return sorted(windows)


def scan_fog(hours: Sequence[ForecastHour], sun: Optional[SunTimes],
             now: datetime) -> Optional[FogOut]:
    if sun is None or not sun.sunset or not sun.sunrise:
        return None
    for start, end in _night_windows(sun, now):
        night = [h for h in hours if max(start, now) <= h.t <= end]
        if not night:
            continue
        # Longest consecutive run of supporting hours.
        best_run: List[ForecastHour] = []
        run: List[ForecastHour] = []
        for h in night:
            ok = _hour_supports_fog(h)
            if ok:
                run.append(h)
                if len(run) > len(best_run):
                    best_run = list(run)
            elif ok is False:
                run = []
            # ok is None (unjudgeable hour): neither extends nor breaks the run
        if len(best_run) < FOG_MIN_HOURS:
            continue

        prime = 0
        max_prime = 0
        for h in best_run:
            prime = prime + 1 if _hour_is_prime(h) else 0
            max_prime = max(max_prime, prime)
        risk = "likely" if max_prime >= LIKELY_HOURS else "possible"

        sunrise = end - timedelta(hours=2)
        clearing = next(
            (h.t for h in hours
             if sunrise <= h.t <= sunrise + timedelta(hours=CLEAR_SEARCH_H)
             and h.temperature is not None and h.dewpoint is not None
             and (h.temperature - h.dewpoint) >= CLEAR_SPREAD),
            None,
        )
        detail = (
            "The temperature and dew point close up overnight with light wind "
            "and a mostly clear sky. Classic radiation fog setup."
            if risk == "likely" else
            "The spread gets close overnight. If the wind stays down and the "
            "sky stays clear, patchy fog is on the table."
        )
        return FogOut(risk=risk, onset=best_run[0].t, clearing=clearing,
                      detail=detail)
    return None


# --- Boundary layer -----------------------------------------------------------


def _bl_ft(m: float) -> int:
    return int(round(m * 3.28084 / BL_ROUND_FT) * BL_ROUND_FT)


def boundary_layer(hours: Sequence[ForecastHour], now: datetime) -> tuple[Optional[int], List[DAPoint]]:
    """Model boundary-layer top now (the hour containing `now`) and for the
    next BL_FORECAST_HOURS, in feet AGL rounded to 100."""
    with_bl = [h for h in hours if h.boundary_layer is not None]
    if not with_bl:
        return None, []
    cur = min((h for h in with_bl if abs((h.t - now).total_seconds()) <= 3600),
              key=lambda h: abs((h.t - now).total_seconds()), default=None)
    now_ft = _bl_ft(cur.boundary_layer) if cur is not None else None
    horizon = now + timedelta(hours=BL_FORECAST_HOURS)
    fc = [DAPoint(t=h.t, ft=_bl_ft(h.boundary_layer)) for h in with_bl if now <= h.t <= horizon]
    return now_ft, fc


# --- Storm outlook --------------------------------------------------------------


def scan_storms(hours: Sequence[ForecastHour], taf: Optional[TafOut],
                now: datetime) -> Optional[StormOut]:
    """Thunderstorms in the next STORM_HOURS: the model's weather code says
    thunder (likely), the TAF carries TS (likely), or CAPE alone is high
    enough to call it possible. Nothing at all on a quiet day."""
    horizon = now + timedelta(hours=STORM_HOURS)
    window = [h for h in hours if now - timedelta(hours=1) <= h.t <= horizon]
    thunder = [h for h in window if h.weather_code in THUNDER_CODES]
    cape_vals = [h.cape for h in window if h.cape is not None]
    cape_max = int(round(max(cape_vals))) if cape_vals else None

    taf_ts = []
    if taf is not None:
        for p in taf.periods:
            if p.wx and "TS" in p.wx and p.timeTo >= now and p.timeFrom <= horizon:
                taf_ts.append(p)

    if thunder and taf_ts:
        start = min(thunder[0].t, max(now, taf_ts[0].timeFrom))
        end = max(thunder[-1].t, taf_ts[-1].timeTo)
        return StormOut(risk="likely", start=start, end=end, capeMax=cape_max, source="both",
                        detail="The model and the TAF both carry thunderstorms in this window.")
    if taf_ts:
        return StormOut(risk="likely", start=max(now, taf_ts[0].timeFrom), end=taf_ts[-1].timeTo,
                        capeMax=cape_max, source="taf",
                        detail="The TAF carries thunderstorms in this window.")
    if thunder:
        return StormOut(risk="likely", start=thunder[0].t, end=thunder[-1].t,
                        capeMax=cape_max, source="model",
                        detail="The model puts thunderstorms in this window.")
    if cape_max is not None and cape_max >= CAPE_POSSIBLE:
        peak = max((h for h in window if h.cape is not None), key=lambda h: h.cape)
        return StormOut(risk="possible", start=peak.t, end=None, capeMax=cape_max, source="model",
                        detail="Enough energy in the air for storms to build if something sets them off. "
                               "Nothing in the forecast says they will.")
    return None


# --- Ride estimate ---------------------------------------------------------------


def _unit(v: float, lo: float, hi: float) -> float:
    return max(0.0, min(1.0, (v - lo) / (hi - lo)))


def ride_terms(h: ForecastHour) -> Optional[Tuple[float, float]]:
    """(thermal, mechanical) for one hour, each roughly 0..1. None when
    the hour lacks the inputs for both."""
    thermal = None
    if h.radiation is not None and h.temperature is not None and h.temp180m is not None:
        lapse = (h.temperature - h.temp180m) / 0.178      # °C per km, 2 m -> 180 m
        depth = max(0.4, min(1.3, ((h.boundary_layer or 500.0) / RIDE_DEPTH_REF_M) ** (1.0 / 3.0)))
        thermal = _unit(h.radiation, RIDE_SUN_LO, RIDE_SUN_HI) * _unit(lapse, RIDE_LAPSE_LO, RIDE_LAPSE_HI) * depth
    mech = None
    if h.windgust is not None or (h.wind80m is not None and h.windspeed is not None):
        g = _unit(h.windgust or 0.0, RIDE_GUST_LO, RIDE_GUST_HI)
        sh = _unit((h.wind80m or 0.0) - (h.windspeed or 0.0), RIDE_SHEAR_LO, RIDE_SHEAR_HI) \
            if h.wind80m is not None and h.windspeed is not None else 0.0
        mech = max(0.0, min(1.0, 0.7 * g + 0.5 * sh))
    if thermal is None and mech is None:
        return None
    return (thermal or 0.0, mech or 0.0)


def _band(score: float) -> str:
    return "bumpy" if score >= RIDE_BUMPY else ("chop" if score >= RIDE_CHOP else "smooth")


def _kind(thermal: float, mech: float) -> str:
    if thermal >= mech * 1.3:
        return "thermal"
    if mech >= thermal * 1.3:
        return "wind"
    return "mixed"


def ride(hours: Sequence[ForecastHour], now: datetime) -> Optional[RideOut]:
    """The band for the current hour and the next different band within
    RIDE_HOURS ("Settling down after 6 PM")."""
    window = [h for h in hours if now - timedelta(hours=1) <= h.t <= now + timedelta(hours=RIDE_HOURS)]
    scored = [(h, t) for h in window if (t := ride_terms(h)) is not None]
    if not scored:
        return None
    cur_h, (th, me) = min(scored, key=lambda ht: abs((ht[0].t - now).total_seconds()))
    score = max(th, me)
    band = _band(score)
    change_band, change_at = None, None
    for h, (t2, m2) in scored:
        if h.t <= cur_h.t:
            continue
        b = _band(max(t2, m2))
        if b != band:
            change_band, change_at = b, h.t
            break
    top = int(round(cur_h.boundary_layer * 3.28084 / BL_ROUND_FT) * BL_ROUND_FT) if cur_h.boundary_layer is not None else None
    return RideOut(band=band, kind=_kind(th, me) if band != "smooth" else ("thermal" if th >= me else "wind"),
                   topFt=top, score=round(score, 2), thermal=round(th, 2), mechanical=round(me, 2),
                   changeBand=change_band, changeAt=change_at)


# --- Assembly -----------------------------------------------------------------


def build(pressure, forecast, now: datetime, taf: Optional[TafOut] = None) -> Optional[ConditionsOut]:
    """ConditionsOut from a PressureResponse + ForecastResponse (+ TAF), or
    None when nothing at all can be computed. Each piece degrades
    independently."""
    da_now = None
    elev_ft = None
    elev_m = pressure.elevM
    cur = pressure.current
    if elev_m is not None:
        elev_ft = int(round(elev_m * 3.28084))
        if cur.altim is not None and cur.temp is not None and cur.dewpoint is not None:
            sp = station_pressure_hpa(cur.altim, elev_m)
            da_now = _round_ft(density_altitude_ft(sp, cur.temp, cur.dewpoint))

    da_fc: List[DAPoint] = []
    fog = None
    storm = None
    ride_out = None
    bl_now, bl_fc = None, []
    if forecast is not None:
        horizon = now + timedelta(hours=DA_FORECAST_HOURS)
        for h in forecast.hourly:
            if h.t < now or h.t > horizon:
                continue
            if h.surface_pressure is None or h.temperature is None or h.dewpoint is None:
                continue
            da_fc.append(DAPoint(
                t=h.t,
                ft=_round_ft(density_altitude_ft(h.surface_pressure,
                                                 h.temperature, h.dewpoint)),
            ))
        fog = scan_fog(forecast.hourly, forecast.sun, now)
        bl_now, bl_fc = boundary_layer(forecast.hourly, now)
        storm = scan_storms(forecast.hourly, taf, now)
        ride_out = ride(forecast.hourly, now)
    elif taf is not None:
        storm = scan_storms([], taf, now)

    if da_now is None and not da_fc and fog is None and bl_now is None and storm is None:
        return None
    return ConditionsOut(densityAltitudeFt=da_now, fieldElevationFt=elev_ft,
                         daForecast=da_fc, boundaryLayerFt=bl_now, blForecast=bl_fc,
                         fog=fog, storm=storm, ride=ride_out)
