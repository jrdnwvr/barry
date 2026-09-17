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
from .conditions import THUNDER_CODES
from .models import CurrentObs, ExplanationOut, ForecastHour, SeriesPoint, SignalOut, TafOut
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


CAT_ORDER = {"VFR": 0, "MVFR": 1, "IFR": 2, "LIFR": 3}

_CARDINAL = {"N": "north", "NE": "northeast", "E": "east", "SE": "southeast",
             "S": "south", "SW": "southwest", "W": "west", "NW": "northwest"}


def _lightning_signal(cur: Optional[CurrentObs], at: datetime) -> Optional[SignalOut]:
    """The station's own lightning report as evidence: a thunderstorm at the
    field, lightning nearby, or distant lightning with its direction."""
    if cur is None or cur.lightning is None:
        return None
    lt = cur.lightning
    where = ""
    singles: List[str] = []
    ranges: List[str] = []
    for d in lt.directions:
        if d in _CARDINAL:
            singles.append(_CARDINAL[d])
        elif "-" in d and all(p in _CARDINAL for p in d.split("-")):
            a, b = d.split("-", 1)
            ranges.append(f"{_CARDINAL[a]} through {_CARDINAL[b]}")   # "W-N": west through north
    if ranges:
        where = ", " + ranges[0]
    elif singles:
        where = " to the " + " and ".join(singles[:2])
    elif "ALQDS" in lt.directions:
        where = " all around"
    if lt.status == "thunderstorm":
        text = "a thunderstorm is at the field right now"
    elif lt.status == "vicinity":
        text = f"lightning is close by{where}"
    else:
        text = f"there is distant lightning{where}"
    return SignalOut(kind="lightning", at=lt.since or at, text=text, source="metar")


def _taf_signals(taf: Optional[TafOut], now: datetime, fmt, reading: Reading) -> List[SignalOut]:
    """What the forecaster's TAF says about the coming hours, as evidence.
    Base period = the current conditions; FM/BECMG periods are changes,
    TEMPO/PROB periods are intermittent. Only the first of each kind, within
    LOOK_AHEAD_H, and timed against the barometer's feature when there is one."""
    if taf is None or not taf.periods:
        return []
    horizon = now + timedelta(hours=LOOK_AHEAD_H)
    base = next((p for p in taf.periods if p.change is None), taf.periods[0])
    out: List[SignalOut] = []
    shift_done = cat_done = wx_done = False
    for p in taf.periods:
        if p.change is None or p.timeFrom < now - timedelta(hours=1) or p.timeFrom > horizon:
            continue
        when = fmt(p.timeFrom)
        lag = ""
        if reading.featureTime is not None:
            dh = (p.timeFrom - reading.featureTime).total_seconds() / 3600.0
            if abs(dh) >= 1.5:
                lag = f", {abs(dh):.0f} h {'after' if dh > 0 else 'before'} the barometer's turn"
        if not shift_done and p.change in ("FM", "BECMG") and p.windDir is not None \
           and base.windDir is not None and (p.windKt or 0) >= 5 \
           and abs(sig._angle_delta(base.windDir, p.windDir)) >= MODEL_SHIFT_DEG:
            gust = f" gusting {int(p.gustKt)}" if p.gustKt else ""
            out.append(SignalOut(kind="taf_wind_shift", at=p.timeFrom, source="taf",
                                 text=f"the TAF shifts the wind to {int(p.windDir):03d}° at {int(p.windKt)} kt{gust} at {when}{lag}"))
            shift_done = True
        if not wx_done and p.wx and any(w in p.wx for w in ("RA", "SN", "TS", "DZ", "SH")):
            kind = "thunderstorms" if "TS" in p.wx else "precipitation"
            how = "" if p.change in ("FM", "BECMG") else " at times"
            out.append(SignalOut(kind="taf_wx", at=p.timeFrom, source="taf",
                                 text=f"the TAF has {kind}{how} from {when}{lag}"))
            wx_done = True
        if not cat_done and p.fltCat in CAT_ORDER and base.fltCat in CAT_ORDER \
           and CAT_ORDER[p.fltCat] > CAT_ORDER[base.fltCat]:
            out.append(SignalOut(kind="taf_category", at=p.timeFrom, source="taf",
                                 text=f"the TAF drops to {p.fltCat} at {when}"))
            cat_done = True
    return out


def build(reading: Optional[Reading], forecast: Optional[Sequence[ForecastHour]],
          series: Sequence[SeriesPoint], now: datetime,
          local_hour_offset: float = 0.0, taf: Optional[TafOut] = None,
          current: Optional[CurrentObs] = None) -> Optional[ExplanationOut]:
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
    # Lightning is the loudest observed signal there is; it leads the list.
    if (lt := _lightning_signal(current, now)) is not None:
        supporting.insert(0, lt)

    # The model's view of the coming hours.
    window = [h for h in (forecast or []) if now <= h.t <= now + timedelta(hours=LOOK_AHEAD_H)]
    if window:
        rain = next((h for h in window if (h.precip_prob or 0) >= PRECIP_THRESHOLD), None)
        thunder = next((h for h in window if h.weather_code in THUNDER_CODES), None)
        if thunder is not None:
            # Thunder says more than rain; one item, not both.
            item = SignalOut(kind="model_thunder", at=thunder.t, source="model",
                             text=f"the model has thunderstorms around {fmt(thunder.t)}")
            (conflicting if rising else supporting).append(item)
        elif rain is not None:
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
        if falling and rain is None and thunder is None and not has_model_gusts and forecast_stays_calm(window):
            conflicting.append(SignalOut(
                kind="model_calm", at=window[0].t, source="model",
                text="the model keeps the next hours dry and calm"))

    # The forecaster's TAF: a wind shift or weather backs a fall; a category
    # drop or rain against a rise is worth saying too.
    for item in _taf_signals(taf, now, fmt, reading):
        (conflicting if (rising and item.kind in ("taf_wx", "taf_category")) else supporting).append(item)

    if not supporting and not conflicting:
        return None

    def sentence(items: List[SignalOut], lead: str = "") -> str:
        texts = [i.text for i in items[:2]]
        # "the model X and the model Y" reads badly; say the subject once.
        for subject in ("the model ", "the TAF "):
            if len(texts) == 2 and all(t.startswith(subject) for t in texts):
                texts[1] = texts[1][len(subject):]
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

STRONG_SUPPORT = {"rain", "model_thunder", "model_wind_shift", "model_gusts", "wind_shift", "gust_onset",
                  "temp_drop", "lightning", "taf_wind_shift", "taf_wx"}


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
