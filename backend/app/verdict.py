"""Plain-language verdict (brief §4.2).

The base sentence is driven by the tendency class. When the interpreter's
`Reading` is available we sharpen the wording with feature-specific phrasing
(approaching trough at 6pm, ridge top easing, rapid fall, …). When forecast
data is available we enrich falling situations with a precip call-out. Features
whose `featureTime` lies in the forecast half get hedged language so we don't
over-promise on a smoothed model output.
"""

from __future__ import annotations

from datetime import datetime
from typing import Optional, Sequence

from .interpreter import Reading
from .models import ForecastHour

BASE_VERDICTS = {
    "falling_fast": "Sharp drop — storm system likely approaching. Secure loose items.",
    "falling_mod": "Pressure falling steadily — unsettled weather likely in coming hours.",
    "falling": "Slight fall — keep an eye out, nothing imminent.",
    "steady": "Holding steady — conditions stable.",
    "rising": "Rising and steady — clearing, fair conditions holding.",
    "rising_fast": "Rising sharply — clearing, but gusty winds likely.",
}

# precip probability (%) above which we call out likely rain
PRECIP_THRESHOLD = 40


def _fmt_local_hour(t: datetime, local_hour_offset: float = 0.0) -> str:
    """Render an hour label like '3 PM' from a (UTC) datetime + local offset."""
    h_raw = (t.hour + t.minute / 60.0 + local_hour_offset) % 24.0
    h = int(round(h_raw)) % 24
    hr = h % 12 or 12
    ampm = "AM" if h < 12 else "PM"
    return f"{hr} {ampm}"


def find_precip_peak(
    forecast: Sequence[ForecastHour],
    *,
    threshold: int = PRECIP_THRESHOLD,
) -> Optional[ForecastHour]:
    """First forecast hour whose precip probability climbs above the threshold."""
    for hour in forecast:
        if hour.precip_prob is not None and hour.precip_prob > threshold:
            return hour
    return None


def _feature_sentence(reading: Reading, *, local_hour_offset: float) -> Optional[str]:
    """Feature-specific phrasing. Returns None for features that should defer to
    the trend-only base sentence (`none`, `diurnal_only`)."""
    f = reading.feature
    t = reading.featureTime
    forecast_derived = "forecast_derived" in reading.caveats

    if f == "approaching_trough":
        if t is not None:
            time_str = _fmt_local_hour(t, local_hour_offset)
            lead = "forecast to bottom out" if forecast_derived else "dropping toward a trough"
            return f"Pressure {lead} around {time_str} — a front looks likely, improving after."
        return "Pressure dropping toward a low — a front looks likely."

    if f == "trough_passing":
        return "Pressure at/near bottom — front passing now. Conditions worst right now."

    if f == "post_trough_recovery":
        return "Pressure rising off a low — conditions improving."

    if f == "ridge_peak":
        if forecast_derived:
            return "Pressure forecast to peak soon — fair conditions easing later."
        return "Pressure at a ridge top — fair conditions starting to ease."

    if f == "front_knee":
        return "Sharp turn down in pressure — a front edge just arrived."

    if f == "rapid_fall":
        return "Pressure falling fast — storm system likely approaching. Secure loose items."

    if f == "rapid_rise":
        return "Pressure rising fast — gusty winds likely (gust front or strong clearing behind a front)."

    return None


def build_verdict(
    tendency_class: Optional[str],
    forecast: Optional[Sequence[ForecastHour]] = None,
    reading: Optional[Reading] = None,
    *,
    local_hour_offset: float = 0.0,
) -> str:
    """Compose the one-line verdict. When `reading` is supplied, prefer its
    feature-specific phrasing; otherwise fall back to the trend class."""
    effective_class = reading.trend if reading is not None else tendency_class
    if effective_class is None:
        return "Not enough recent data to read the trend yet."

    sentence: Optional[str] = None
    if reading is not None:
        sentence = _feature_sentence(reading, local_hour_offset=local_hour_offset)
    if sentence is None:
        sentence = BASE_VERDICTS.get(effective_class, BASE_VERDICTS["steady"])

    # Only enrich falling situations — a rain call-out on a rising trend is noise.
    if effective_class.startswith("falling") and forecast:
        peak = find_precip_peak(forecast)
        if peak is not None:
            sentence += f" — rain likely around {_fmt_local_hour(peak.t, local_hour_offset)}."

    return sentence
