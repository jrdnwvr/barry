"""Explain the change (C1): what else agrees with the pressure signal.

Pressure leads. Everything here is corroboration, labeled by where it came
from ("metar" = observed at the station, "model" = the forecast), and
disagreement is said out loud: a barometer that admits the model disagrees
is more useful than one that pretends the forecast doesn't exist.
"""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import List, Optional, Sequence

from . import signals as sig
from .interpreter import Reading
from .models import ExplanationOut, ForecastHour, SeriesPoint, SignalOut
from .verdict import CALM_WIND_MAX_KMH, PRECIP_THRESHOLD, _fmt_local_hour, forecast_stays_calm

LOOK_AHEAD_H = 12.0
MODEL_SHIFT_DEG = 60.0
MODEL_GUST_KMH = 28.0       # ~15 kt

FALLING = {"falling", "falling_mod", "falling_fast"}
RISING = {"rising", "rising_fast"}
FALL_FEATURES = {"approaching_trough", "trough_passing", "front_knee", "rapid_fall"}


def _kt(kmh: float) -> int:
    return int(round(kmh / 1.852))


def _phrase_observed(s: sig.Signal, fmt) -> str:
    d = s.detail
    when = fmt(s.at)
    if s.kind == "wind_shift":
        return (f"wind {'veered' if d['veer'] else 'backed'} from "
                f"{int(d['fromDeg']):03d}° to {int(d['toDeg']):03d}° at {when}")
    if s.kind == "gust_onset":
        return f"gusts to {_kt(d['gustKmh'])} kt started around {when}"
    if s.kind == "temp_drop":
        return f"temperature fell {d['dropC']:.0f}° in the last couple of hours"
    if s.kind == "category_change":
        verb = "dropped" if d["worse"] else "improved"
        return f"conditions {verb} to {d['toCat']} at {when}"
    return s.kind


def build(reading: Optional[Reading], forecast: Optional[Sequence[ForecastHour]],
          series: Sequence[SeriesPoint], now: datetime,
          local_hour_offset: float = 0.0) -> Optional[ExplanationOut]:
    if reading is None:
        return None
    fmt = lambda t: _fmt_local_hour(t, local_hour_offset)
    falling = reading.trend in FALLING or reading.feature in FALL_FEATURES
    rising = reading.trend in RISING or reading.feature == "ridge_peak"

    supporting: List[SignalOut] = []
    conflicting: List[SignalOut] = []

    # Observed at the station: always worth saying; a wind shift or a
    # temperature drop is a front announcing itself.
    for s in sig.detect(series, now):
        item = SignalOut(kind=s.kind, at=s.at, text=_phrase_observed(s, fmt), source="metar")
        worse = s.kind == "category_change" and not s.detail.get("worse")
        (conflicting if (worse and falling) else supporting).append(item)

    # The model's view of the coming hours.
    window = [h for h in (forecast or []) if now <= h.t <= now + timedelta(hours=LOOK_AHEAD_H)]
    if window:
        rain = next((h for h in window if (h.precip_prob or 0) >= PRECIP_THRESHOLD), None)
        if rain is not None:
            item = SignalOut(kind="rain", at=rain.t, source="model",
                             text=f"the model puts rain in from {fmt(rain.t)}")
            (conflicting if rising else supporting).append(item)

        first = next((h for h in window if h.winddir is not None and (h.windspeed or 0) >= sig.WIND_MIN_KMH), None)
        if first is not None:
            for h in window:
                if h.winddir is None or (h.windspeed or 0) < sig.WIND_MIN_KMH or h.t <= first.t:
                    continue
                if abs(sig._angle_delta(first.winddir, h.winddir)) >= MODEL_SHIFT_DEG:
                    supporting.append(SignalOut(
                        kind="model_wind_shift", at=h.t, source="model",
                        text=f"the model swings the wind to {int(h.winddir):03d}° around {fmt(h.t)}"))
                    break

        gusty = max(window, key=lambda h: h.windgust or 0)
        if (gusty.windgust or 0) >= MODEL_GUST_KMH:
            supporting.append(SignalOut(
                kind="model_gusts", at=gusty.t, source="model",
                text=f"the model has gusts to {_kt(gusty.windgust)} kt around {fmt(gusty.t)}"))

        has_model_gusts = any(i.kind == "model_gusts" for i in supporting)
        if falling and rain is None and not has_model_gusts and forecast_stays_calm(window):
            conflicting.append(SignalOut(
                kind="model_calm", at=window[0].t, source="model",
                text="the model keeps the next hours dry and calm"))

    if not supporting and not conflicting:
        return None

    def sentence(items: List[SignalOut], lead: str = "") -> str:
        texts = [i.text for i in items[:2]]
        # "the model X and the model Y" reads badly; say it once.
        if len(texts) == 2 and all(t.startswith("the model ") for t in texts):
            texts[1] = texts[1][len("the model "):]
        joined = " and ".join(texts)
        joined = lead + joined
        return joined[0].upper() + joined[1:] + "."

    parts = []
    if supporting:
        parts.append(sentence(supporting))
    if conflicting:
        parts.append(sentence(conflicting, lead="but " if supporting else ""))
    return ExplanationOut(summary=" ".join(parts), supporting=supporting, conflicting=conflicting)


# ---- Confidence from agreement (C3) ----------------------------------------

STRONG_SUPPORT = {"rain", "model_wind_shift", "model_gusts", "wind_shift", "gust_onset", "temp_drop"}


def adjust_confidence(confidence: float, ex: Optional[ExplanationOut]) -> tuple[float, List[str]]:
    """Agreement between the pressure signal, observed signals, and the model
    nudges confidence up (toward, never past, 1.0); the model flatly
    disagreeing pulls it down and adds a caveat the app can name."""
    if ex is None:
        return confidence, []
    caveats: List[str] = []
    strong = sum(1 for i in ex.supporting if i.kind in STRONG_SUPPORT)
    conf = min(1.0, confidence + 0.1 * strong)
    if any(i.kind == "model_calm" for i in ex.conflicting):
        conf *= 0.8
        caveats.append("model_disagrees")
    elif ex.conflicting:
        conf *= 0.9
        caveats.append("model_disagrees")
    return round(max(0.0, min(1.0, conf)), 2), caveats
