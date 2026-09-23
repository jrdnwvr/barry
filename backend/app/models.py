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
    # The rest of each METAR, kept so the reading can see a wind shift, a
    # temperature drop, or a category change, not just pressure. km/h, °C.
    windKmh: Optional[float] = None
    windDir: Optional[float] = None
    gustKmh: Optional[float] = None
    temp: Optional[float] = None
    dewpoint: Optional[float] = None
    visibilitySM: Optional[float] = None
    ceilingFt: Optional[int] = None
    fltCat: Optional[str] = None


class LightningOut(BaseModel):
    """Thunderstorm / lightning state decoded from one METAR (lightning.py).
    Absent means "nothing reported", never "no lightning": a field without
    a sensor says nothing. `status` is thunderstorm (at the field, ~5 NM),
    vicinity (5 to 10 NM) or distant (10 to 30 NM)."""

    status: str
    frequency: Optional[str] = None        # occasional | frequent | continuous
    types: List[str] = Field(default_factory=list)   # IC, CC, CG
    directions: List[str] = Field(default_factory=list)   # SW, "W-NW", ALQDS
    moving: Optional[str] = None           # direction the storm is moving toward
    since: Optional[datetime] = None       # TSB time, when the storm is here


class CloudLayer(BaseModel):
    """One sky layer from the METAR: cover (FEW/SCT/BKN/OVC/VV, or CLR/SKC
    with no base) and its base in feet AGL."""

    cover: str
    baseFt: Optional[int] = None


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
    fltCatDerived: bool = False            # True when AWC left it blank and Barry
                                           # worked it out from ceiling/visibility
    wx: Optional[str] = None               # present weather ("-TSRA BR")
    lightning: Optional[LightningOut] = None
    clouds: List[CloudLayer] = Field(default_factory=list)   # every layer, lowest first


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
    # Convection + mixing (storm outlook, boundary layer card)
    cape: Optional[float] = None            # J/kg
    weather_code: Optional[int] = None      # WMO code; 95/96/99 = thunderstorm
    boundary_layer: Optional[float] = None  # m AGL
    cin: Optional[float] = None             # J/kg convective inhibition (negative = capped)
    # Ride estimate inputs
    radiation: Optional[float] = None       # W/m² shortwave at the surface
    temp80m: Optional[float] = None         # °C
    temp180m: Optional[float] = None        # °C
    wind80m: Optional[float] = None         # km/h


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


class SignalOut(BaseModel):
    """One piece of evidence about the change, with when it happens/happened.
    `source` is "metar" (observed at the station) or "model" (forecast)."""

    kind: str
    at: datetime
    text: str
    source: str


class ExplanationOut(BaseModel):
    """What else agrees with the pressure signal, and what doesn't. Pressure
    leads; these are corroboration, labeled by source, never a replacement."""

    summary: str
    supporting: List[SignalOut] = Field(default_factory=list)
    conflicting: List[SignalOut] = Field(default_factory=list)


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
    explanation: Optional[ExplanationOut] = None


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
    fltCatDerived: bool = False         # category worked out from ceiling/visibility
    obsTime: Optional[datetime] = None
    visibilitySM: Optional[float] = None
    ceilingFt: Optional[int] = None
    ceilingCover: Optional[str] = None
    temp: Optional[float] = None        # °C
    dewpoint: Optional[float] = None    # °C
    altim: Optional[float] = None       # hPa
    slp: Optional[float] = None         # sea-level pressure, hPa (when reported)
    presTend: Optional[float] = None    # station-reported 3 h tendency, hPa
    wx: Optional[str] = None            # present weather ("-TSRA BR")
    lightning: Optional[LightningOut] = None
    raw: Optional[str] = None           # the METAR as transmitted


class FieldPoint(BaseModel):
    """One sample of the radar's model field: 10 m wind (km/h, degrees FROM)
    and boundary-layer top (m AGL) for the current hour."""

    lat: float
    lon: float
    windKmh: float
    windDeg: float
    blM: Optional[float] = None
    capeJkg: Optional[float] = None     # convective energy this hour


class FieldGridResponse(BaseModel):
    points: List[FieldPoint] = Field(default_factory=list)
    cachedAt: datetime


# ---- Aloft: the vertical column at a point ---------------------------------

class AloftLevel(BaseModel):
    """One model pressure level, in the units the app draws: feet MSL from
    the geopotential height, knots, degrees, whole percent."""
    hPa: int
    ft: int
    tempC: float
    dewC: Optional[float] = None
    dirDeg: Optional[float] = None
    spdKt: Optional[float] = None
    cloudPct: Optional[int] = None


class AloftCloud(BaseModel):
    """A run of consecutive levels at or above half cover. `icing` when any
    level in the run sits between 0 and -20 C, where supercooled water lives."""
    baseFt: int
    topFt: int
    coverPct: int
    icing: bool = False


class AloftSurface(BaseModel):
    tempC: Optional[float] = None
    dewC: Optional[float] = None
    dirDeg: Optional[float] = None
    spdKt: Optional[float] = None


class AloftHour(BaseModel):
    t: datetime
    levels: List[AloftLevel] = Field(default_factory=list)
    clouds: List[AloftCloud] = Field(default_factory=list)
    surface: Optional[AloftSurface] = None
    freezingFt: Optional[int] = None
    blAglFt: Optional[int] = None


class AloftResponse(BaseModel):
    hours: List[AloftHour] = Field(default_factory=list)
    source: str = "open-meteo"
    cachedAt: datetime
    # The model did not answer and this is the last good column, trimmed to
    # the hours still ahead. Clients may say so.
    stale: bool = False


class TafPeriod(BaseModel):
    """One TAF forecast period, decoded by AWC. `change` is None for the base
    period, else FM | BECMG | TEMPO | PROB30 | PROB40."""

    timeFrom: datetime
    timeTo: datetime
    change: Optional[str] = None
    windDir: Optional[float] = None     # degrees; None = variable
    windKt: Optional[float] = None
    gustKt: Optional[float] = None
    visibilitySM: Optional[float] = None
    ceilingFt: Optional[int] = None
    ceilingCover: Optional[str] = None
    wx: Optional[str] = None
    fltCat: Optional[str] = None


class TafOut(BaseModel):
    station: str
    issueTime: Optional[datetime] = None
    validFrom: Optional[datetime] = None
    validTo: Optional[datetime] = None
    raw: Optional[str] = None
    periods: List[TafPeriod] = Field(default_factory=list)


class TrackRecordOut(BaseModel):
    """Barry's own scorecard at this station: trend calls that matched what
    the pressure then did, over the last `days`. Absent until there are
    enough scored calls to mean anything."""

    right: int
    total: int
    days: int


class ContourLine(BaseModel):
    """One contour polyline: `level` (hPa for isobars, hPa/3 h for
    isallobars) and [[lat, lon], ...]."""

    level: float
    points: List[List[float]]


class GridOut(BaseModel):
    """A regular lat/lon lattice of values (row 0 = south, col 0 = west);
    null where no station is near enough. The app shades it as a gradient."""

    lat0: float
    lon0: float
    dlat: float
    dlon: float
    ny: int
    nx: int
    values: List[List[Optional[float]]]


class FieldExtremum(BaseModel):
    """An H (maximum) or L (minimum) of a gridded field, with its value."""

    kind: str
    lat: float
    lon: float
    value: float


class PressureFieldResponse(BaseModel):
    isobars: List[ContourLine] = Field(default_factory=list)
    isallobars: List[ContourLine] = Field(default_factory=list)
    pressureGrid: Optional[GridOut] = None
    tendencyGrid: Optional[GridOut] = None
    tendencyExtrema: List[FieldExtremum] = Field(default_factory=list)
    stations: int = 0
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


class RadarFrameOut(BaseModel):
    """One radar frame: unix valid time and the RainViewer tile path."""

    time: int
    path: str
    nowcast: bool = False


class RadarFramesResponse(BaseModel):
    host: str
    frames: List[RadarFrameOut] = Field(default_factory=list)
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


class StormOut(BaseModel):
    """Thunderstorm outlook. Three honest states: storms OBSERVED nearby
    (lightning within 100 mi, with drift and an arrival estimate), storms
    LIKELY here later (model thunder code or TAF), or POSSIBLE (energy plus
    a trigger the model can see). Absent on a merely warm day."""

    risk: str                              # "observed" | "likely" | "possible"
    start: Optional[datetime] = None       # forecast window start / arrival estimate
    end: Optional[datetime] = None
    capeMax: Optional[int] = None          # J/kg, peak in the window
    source: str = "model"                  # model | taf | both | glm | metar
    detail: str
    # Observed storms: where they are and where they are going.
    distanceMi: Optional[int] = None
    cardinal: Optional[str] = None
    moving: Optional[str] = None
    towardYou: Optional[bool] = None
    etaAt: Optional[datetime] = None       # when the cluster reaches you, if it holds
    # Forecast window when observed storms are also forecast to continue.
    forecastStart: Optional[datetime] = None
    forecastEnd: Optional[datetime] = None


class RideOut(BaseModel):
    """How bumpy the boundary layer is likely to be, estimated from what
    drives turbulence (sun and near-surface lapse rate for thermals, gusts
    and low-level shear for mechanical chop). An estimate from the model,
    never a measurement and never a pilot report."""

    band: str                              # smooth | chop | bumpy
    kind: str                              # thermal | wind | mixed
    topFt: Optional[int] = None            # the layer top now, ft AGL
    score: float                           # 0..1+, for tuning
    thermal: float                         # the two terms, for tuning
    mechanical: float
    changeBand: Optional[str] = None       # the next different band within 12 h
    changeAt: Optional[datetime] = None


class ConditionsOut(BaseModel):
    """Field conditions (conditions.py): density altitude now + forecast, the
    boundary layer, the fog outlook and the storm outlook. All optional,
    each piece degrades independently."""

    densityAltitudeFt: Optional[int] = None   # now, the AWOS method (dry air)
    densityAltitudeHumidFt: Optional[int] = None   # with the dew point's humidity
    fieldElevationFt: Optional[int] = None
    daForecast: List[DAPoint] = Field(default_factory=list)
    boundaryLayerFt: Optional[int] = None     # model layer top now, ft AGL
    blForecast: List[DAPoint] = Field(default_factory=list)
    fog: Optional[FogOut] = None
    storm: Optional[StormOut] = None
    ride: Optional[RideOut] = None


class LightningCell(BaseModel):
    """One map cell of GLM flashes: centre, flashes in the window, and the
    age of the newest one (seconds)."""

    lat: float
    lon: float
    count: int
    ageSec: int


class LightningCluster(BaseModel):
    """A group of touching flash cells: the electrified part of one storm.
    `points` is a closed outline (lat, lon pairs), `flashes` the count in
    the window, `recent` the count in the last five minutes."""

    points: List[List[float]]
    flashes: int
    recent: int
    newestAgeSec: int


class LightningResponse(BaseModel):
    """Flashes seen from orbit over the last `windowSec`, binned to
    `binDeg` cells, inside the requested box. `coverage` is False when the
    feed has not been read recently (an empty map then means "unknown",
    not "no lightning")."""

    cells: List[LightningCell] = Field(default_factory=list)
    clusters: List[LightningCluster] = Field(default_factory=list)
    windowSec: int = 1200
    binDeg: float = 0.02
    coverage: bool = False
    source: str = "NOAA GOES Geostationary Lightning Mapper"
    cachedAt: datetime


class LightningNearby(BaseModel):
    """The nearest station reporting lightning within LIGHTNING_RADIUS_KM of
    the user's station, from the bulk METAR table: how far, which way, how
    old the report is, and whether the storm's reported motion brings it
    toward the user. `continuesUntil` is the storm outlook's end when the
    forecast keeps thunder going."""

    station: str
    name: Optional[str] = None
    distanceMi: int
    bearingDeg: float
    cardinal: str
    status: str                            # thunderstorm | vicinity | distant | strikes
    at: datetime                           # the report's observation time (GLM: newest flash)
    moving: Optional[str] = None           # the storm's reported motion (toward)
    towardYou: Optional[bool] = None       # None = unknown or sideways
    continuesUntil: Optional[datetime] = None
    source: str = "metar"                  # metar (a station's report) | glm (flashes)
    flashes: Optional[int] = None          # GLM: flashes within 100 mi over the window
    speedKmh: Optional[float] = None       # GLM: the cluster's drift speed
    etaAt: Optional[datetime] = None       # GLM: arrival if it keeps coming


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
    taf: Optional[TafOut] = None
    trackRecord: Optional[TrackRecordOut] = None
    lightningNearby: Optional[LightningNearby] = None
    sources: Optional[Sources] = None
    verdict: str
