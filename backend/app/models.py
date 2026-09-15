"""Normalized response schemas — the contract both apps consume (brief §5).

Field names match the JSON contract exactly. Note `class` is a Python keyword, so
the TendencyOut model aliases the `cls` field to serialize as "class".
"""

from __future__ import annotations

from datetime import datetime
from typing import List, Optional

from pydantic import BaseModel, ConfigDict, Field


class SeriesPoint(BaseModel):
    t: datetime
    slp: Optional[float] = None
    altim: Optional[float] = None


class CurrentObs(BaseModel):
    slp: Optional[float] = None
    presTend: Optional[float] = None
    altim: Optional[float] = None          # altimeter setting (hPa) — DA input
    temp: Optional[float] = None           # °C, from the latest METAR
    dewpoint: Optional[float] = None       # °C
    # Wind from the latest METAR — a real measurement, preferred over the model
    # forecast for "now" (METAR-first, Open-Meteo supplements). km/h + degrees;
    # windgust is only present when the station reported one (inherently notable).
    windspeed: Optional[float] = None
    winddir: Optional[float] = None
    windgust: Optional[float] = None
    # Aviation conditions from the same METAR (drives the watch METAR complication).
    visibilitySM: Optional[float] = None   # statute miles ("10+" parses to 10.0)
    ceilingFt: Optional[int] = None        # lowest broken/overcast layer base
    ceilingCover: Optional[str] = None     # cover of that layer (BKN/OVC), or the
                                           # lowest layer / CLR when no ceiling
    fltCat: Optional[str] = None           # VFR / MVFR / IFR / LIFR


class TendencyOut(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    delta3h: float
    cls: str = Field(serialization_alias="class")
    intensity: float


class PressureResponse(BaseModel):
    station: str
    name: Optional[str] = None
    lat: Optional[float] = None
    lon: Optional[float] = None
    elevM: Optional[float] = None          # field elevation (m) — DA input
    series: List[SeriesPoint] = Field(default_factory=list)
    current: CurrentObs = Field(default_factory=CurrentObs)
    tendency: Optional[TendencyOut] = None
    source: str
    cachedAt: datetime


class ForecastHour(BaseModel):
    t: datetime
    pressure_msl: Optional[float] = None
    windspeed: Optional[float] = None
    winddir: Optional[float] = None
    windgust: Optional[float] = None
    precip_prob: Optional[int] = None
    # Field-conditions inputs (density altitude + fog risk)
    temperature: Optional[float] = None     # °C at 2 m
    dewpoint: Optional[float] = None        # °C at 2 m
    cloudcover: Optional[float] = None      # %
    surface_pressure: Optional[float] = None  # hPa at model ground level


class SunTimes(BaseModel):
    sunrise: List[datetime] = Field(default_factory=list)
    sunset: List[datetime] = Field(default_factory=list)


class ForecastResponse(BaseModel):
    hourly: List[ForecastHour] = Field(default_factory=list)
    sun: Optional[SunTimes] = None
    source: str
    cachedAt: datetime
    # True when the upstream fetch failed and this is the last good forecast being
    # re-served (stale-if-error). Clients should say so rather than hide the loss.
    stale: bool = False


class ReadingOut(BaseModel):
    """Structured curve interpretation (brief §4.3). Computed server-side over
    the merged observed+forecast series so both clients see the same answer."""

    trend: str
    rate3h: float
    steadiness: float
    feature: str
    featureTime: Optional[datetime] = None
    confidence: float
    caveats: List[str] = Field(default_factory=list)


class FrontStationOut(BaseModel):
    """One surrounding station's own 3h tendency — a dot on the client compass."""

    id: str
    bearingDeg: float
    distanceKm: float
    tendency3h: float


class NearestFront(BaseModel):
    """The WPC-analyzed front nearest the station: what the pressure field is
    actually reacting to. Motion comes from WPC's 12 h forecast position when
    the same front can be matched there; etaHours is a linear closing estimate."""

    type: str                          # cold | warm | stnry | ocfnt | trof
    weak: bool = False
    distanceKm: float
    bearingDeg: float                  # from the station to the nearest point
    cardinal: str
    approaching: Optional[bool] = None
    etaHours: Optional[float] = None
    etaAt: Optional[datetime] = None


class FrontResponse(BaseModel):
    """Front watch (regional isallobaric analysis, see front.py). status "none"
    means a quiet field — the client renders nothing at all."""

    station: str
    nearestFront: Optional[NearestFront] = None
    status: str = "none"  # none | forecast | approaching | passing | passed
    headline: Optional[str] = None
    detail: Optional[str] = None
    bearingDeg: Optional[float] = None    # compass bearing of the falls, from the user
    cardinal: Optional[str] = None        # "west" — the word used in the copy
    eta: Optional[datetime] = None        # model trough time (interpreter featureTime)
    maxFall3h: Optional[float] = None
    ownDelta3h: Optional[float] = None
    gradient: Optional[float] = None      # hPa/3h per 100 km
    coherence: Optional[float] = None     # plane-fit R²
    stations: List[FrontStationOut] = Field(default_factory=list)
    cachedAt: datetime


class FrontLine(BaseModel):
    """One WPC front: type cold|warm|stnry|ocfnt|trof, points [[lat, lon], ...]
    in the bulletin's order (the front moves toward the LEFT of travel along
    them — the client puts the pips on that side)."""

    type: str
    weak: bool = False
    points: List[List[float]]


class PressureCenter(BaseModel):
    pressure: int
    lat: float
    lon: float


class FrontFrame(BaseModel):
    """The surface chart at one valid time: hours=0 is the analysis, 12/24/36/48
    are WPC's forecast positions."""

    hours: int
    valid: datetime
    fronts: List[FrontLine] = Field(default_factory=list)
    highs: List[PressureCenter] = Field(default_factory=list)
    lows: List[PressureCenter] = Field(default_factory=list)


class FrontsResponse(BaseModel):
    frames: List[FrontFrame] = Field(default_factory=list)   # analysis first, then progs
    source: str = "NWS Weather Prediction Center via Iowa Environmental Mesonet"
    cachedAt: datetime


class StationObs(BaseModel):
    """One reporting station's latest report, for the radar's station layer
    (wind drives the barbs; the rest fills the tap-for-details sheet)."""

    id: str
    lat: float
    lon: float
    name: Optional[str] = None
    windKt: Optional[float] = None
    windDir: Optional[float] = None     # None = variable or calm
    gustKt: Optional[float] = None
    fltCat: Optional[str] = None
    obsTime: Optional[datetime] = None
    visibilitySM: Optional[float] = None
    ceilingFt: Optional[int] = None
    ceilingCover: Optional[str] = None
    temp: Optional[float] = None        # °C
    dewpoint: Optional[float] = None    # °C
    altim: Optional[float] = None       # hPa
    raw: Optional[str] = None           # the METAR as transmitted


class FieldPoint(BaseModel):
    """One sample of the radar's model field: 10 m wind (km/h, degrees FROM)
    and boundary-layer top (m AGL) for the current hour."""

    lat: float
    lon: float
    windKmh: float
    windDeg: float
    blM: Optional[float] = None


class FieldGridResponse(BaseModel):
    points: List[FieldPoint] = Field(default_factory=list)
    cachedAt: datetime


class Runway(BaseModel):
    """One runway, both ends. Headings are degrees TRUE (OurAirports
    le_heading_degT), the same reference the METAR wind uses, so crosswind
    math needs no variation."""

    le: str                             # low-end ident, e.g. "3"
    he: str                             # high-end ident, e.g. "21"
    leHeading: float
    heHeading: float
    lengthFt: Optional[int] = None


class StationsResponse(BaseModel):
    stations: List[StationObs] = Field(default_factory=list)
    cachedAt: datetime


class HrrrMeta(BaseModel):
    """Latest HRRR model run IEM is serving tiles for. Forecast minute F on the
    tile layer is valid at run + F — the client needs this to label forecast
    frames with true times instead of guesses."""

    run: datetime
    source: str = "HRRR via Iowa Environmental Mesonet"
    cachedAt: datetime


class DAPoint(BaseModel):
    t: datetime
    ft: int


class FogOut(BaseModel):
    """Radiation fog outlook for the coming night. Only present when there IS a
    risk — a quiet night renders nothing, same rule as the front watch."""

    risk: str                              # "possible" | "likely"
    onset: Optional[datetime] = None
    clearing: Optional[datetime] = None    # burn-off estimate; None = unclear
    detail: str


class ConditionsOut(BaseModel):
    """Field conditions (conditions.py): density altitude now + forecast, and
    the fog outlook. All optional — each piece degrades independently."""

    densityAltitudeFt: Optional[int] = None   # now, from the latest METAR
    fieldElevationFt: Optional[int] = None
    daForecast: List[DAPoint] = Field(default_factory=list)
    fog: Optional[FogOut] = None


class Sources(BaseModel):
    """Where each half of the curve actually came from. Surfaces a graceful
    degradation (e.g. observed via Open-Meteo when AWC is blocked)."""

    observed: str
    forecast: Optional[str] = None


class CombinedResponse(BaseModel):
    """Primary client endpoint — the full -24h / +24h picture in one call."""

    pressure: PressureResponse
    forecast: Optional[ForecastResponse] = None
    reading: Optional[ReadingOut] = None
    conditions: Optional[ConditionsOut] = None
    runways: List[Runway] = Field(default_factory=list)
    sources: Optional[Sources] = None
    verdict: str
