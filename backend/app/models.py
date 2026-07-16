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


class ForecastResponse(BaseModel):
    hourly: List[ForecastHour] = Field(default_factory=list)
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


class FrontResponse(BaseModel):
    """Front watch (regional isallobaric analysis, see front.py). status "none"
    means a quiet field — the client renders nothing at all."""

    station: str
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


class HrrrMeta(BaseModel):
    """Latest HRRR model run IEM is serving tiles for. Forecast minute F on the
    tile layer is valid at run + F — the client needs this to label forecast
    frames with true times instead of guesses."""

    run: datetime
    source: str = "HRRR via Iowa Environmental Mesonet"
    cachedAt: datetime


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
    sources: Optional[Sources] = None
    verdict: str
