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
    precip_prob: Optional[int] = None


class ForecastResponse(BaseModel):
    hourly: List[ForecastHour] = Field(default_factory=list)
    source: str
    cachedAt: datetime


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
