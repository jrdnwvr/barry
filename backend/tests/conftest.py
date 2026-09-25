"""Shared fixtures: a mocked httpx client that fakes AWC + Open-Meteo upstreams."""

from __future__ import annotations

import json
import os
from datetime import datetime, timedelta, timezone

import httpx
import pytest


def _metar_record(sid, obs_time, slp, *, altim=None, pres_tend=None, name="Test Field",
                  wspd=10, wdir=230, wgst=None, temp=27.0, dewp=18.0):
    return {
        "icaoId": sid,
        "obsTime": obs_time,
        "slp": slp,
        "altim": altim,
        "presTend": pres_tend,
        "name": name,
        "lat": 39.103,
        "lon": -84.419,
        "elev": 147.0,
        "temp": temp,
        "dewp": dewp,
        "wspd": wspd,
        "wdir": wdir,
        "wgst": wgst,
        "visib": "10+",
        "clouds": [{"cover": "SCT", "base": 2500}, {"cover": "BKN", "base": 4500}],
        "fltCat": "VFR",
        "rawOb": f"{sid} 121853Z {wdir:03d}{wspd:02d}KT 10SM SCT025 BKN045 27/18 A3006",
    }


def sample_metars(sid="KLUK", *, with_pres_tend=True):
    """A 4-point series, 1h apart, falling 1012 -> 1009.6 over 3h (delta -2.4).

    Anchored to wall-clock time so the interpreter's trailing-window logic sees
    "recent" data regardless of when the test suite runs."""
    end = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    base = int((end - timedelta(hours=3)).timestamp())
    pts = [
        (base + 0 * 3600, 1012.0),
        (base + 1 * 3600, 1011.2),
        (base + 2 * 3600, 1010.4),
        (base + 3 * 3600, 1009.6),
    ]
    recs = []
    for i, (t, slp) in enumerate(pts):
        pt = -2.4 if (with_pres_tend and i == len(pts) - 1) else None
        # Newest record carries a gust so the METAR-wind extraction is exercised.
        gust = 18 if i == len(pts) - 1 else None
        recs.append(_metar_record(sid, t, slp, altim=slp + 0.7, pres_tend=pt, wgst=gust))
    return recs


def sample_bbox_metars(pattern):
    """A ring of 8 stations ~100 km around KLUK with a MOVING tendency field.

    Each station reports altimeter only (exercises the SLP-fallback path), three
    obs so the front watch can evaluate the ring at two epochs (now and -4h) and
    see the fall pattern's motion. Patterns:
      west_falls  d(x) = -1.5 + 0.02x now (deep falls west), the whole pattern
                  80 km further west 4 h ago -> centroid tracks EASTWARD, so the
                  change is coming from the west
      east_falls  mirrored, drifting away east (the "it moved through" field)
      flat        incoherent +/-0.1 wobble -> no call
    """
    end = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    t0 = int((end - timedelta(hours=7.5)).timestamp())  # spans: 3.5 h + 4.0 h,
    t1 = int((end - timedelta(hours=4)).timestamp())    # both within the 2-4 h
    t2 = int(end.timestamp())                           # delta-pair window
    origin_lat, origin_lon = 39.103, -84.419
    recs = []
    import math

    def field(x, shift):
        if pattern == "west_falls":
            return -1.5 + 0.02 * (x + shift)
        if pattern == "east_falls":
            return -1.5 - 0.02 * (x - shift)
        return None

    for i, bearing in enumerate(range(0, 360, 45)):
        dist = 100.0
        x = dist * math.sin(math.radians(bearing))  # km east
        y = dist * math.cos(math.radians(bearing))  # km north
        lat = origin_lat + y / 111.32
        lon = origin_lon + x / (111.32 * math.cos(math.radians(origin_lat)))
        if pattern == "flat":
            d_prev = d_now = 0.1 if i % 2 == 0 else -0.1
        else:
            d_prev = field(x, 80.0)  # pattern was 80 km upstream 4 h ago
            d_now = field(x, 0.0)
        v0 = 1015.0
        v1 = v0 + d_prev * 3.5 / 3.0  # per-3h rate over the 3.5 h span
        v2 = v1 + d_now * 4.0 / 3.0   # ...and the 4.0 h span
        sid = f"KR{i}A"
        for t, altim in ((t0, v0), (t1, round(v1, 2)), (t2, round(v2, 2))):
            rec = _metar_record(sid, t, None, altim=altim, name=f"Ring {i}")
            rec["lat"] = round(lat, 4)
            rec["lon"] = round(lon, 4)
            recs.append(rec)
    return recs


def sample_forecast(trough=False):
    # Forecast hours follow the latest observed sample (sample_metars ends at
    # `now` rounded to the hour). Open-Meteo's "time" field is ISO without TZ
    # in the local timezone of the request — the parser treats it as UTC, which
    # is fine for the test (we just need a contiguous hourly sequence).
    start = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    times = [
        (start + timedelta(hours=i)).strftime("%Y-%m-%dT%H:%M")
        for i in range(12)
    ]
    n = len(times)
    if trough:
        # A genuine pressure trough at hour 5 (fall gentle enough not to trip the
        # interpreter's rapid_fall shortcut, which would preempt approaching_trough).
        pressures = [1009.4 - 0.5 * i if i <= 5 else 1006.9 + 0.8 * (i - 5)
                     for i in range(n)]
    else:
        # Continue the observed fall (ends ~1009.6) so the merged series the
        # interpreter sees has no boundary kink; -0.3 hPa/h matches the curve.
        pressures = [1009.4 - 0.3 * i for i in range(n)]
    return {
        "hourly": {
            "time": times,
            "pressure_msl": pressures,
            "surface_pressure": [1008.0 - 0.3 * i for i in range(n)],
            "windspeed_10m": [8.0 + 1.5 * i for i in range(n)],
            "winddirection_10m": [210 for _ in range(n)],
            "wind_gusts_10m": [14.0 + 2.5 * i for i in range(n)],
            # precip crosses 40% partway through
            "precipitation_probability": [10, 15, 20, 30, 45, 60, 70, 65, 50, 40, 30, 20],
            # Field-conditions inputs: a warm, moderately humid stretch.
            "temperature_2m": [26.0 - 0.5 * i for i in range(n)],
            "dew_point_2m": [17.0 for _ in range(n)],
            "cloud_cover": [55.0 for _ in range(n)],
        },
        "daily": {
            # One sunrise/sunset pair bracketing tonight (UTC, IEM-style local
            # fixtures don't matter here — the scan only needs the ordering).
            "sunrise": [(start + timedelta(hours=14)).strftime("%Y-%m-%dT%H:%M")],
            "sunset": [(start + timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M")],
        },
    }


CODSUS_SAMPLE = """
657
ASUS01 KWBC 141622
CODSUS

CODED SURFACE FRONTAL POSITIONS
NWS WEATHER PREDICTION CENTER COLLEGE PARK MD
1221 PM EDT MON SEP 14 2026

VALID 091415Z
HIGHS 1018 38107 1014 36112 1028 4385
LOWS 1000 48104 1006 40109 993 6889
OCFNT 48104 47103 44103
WARM 44103 43102 40100 3997 3895 3694
STNRY 3491 3492 3593 3593 3694
COLD 4865 4467 4169 3972 3676 3580 3583 3586 3589
COLD 44103 42105 41106
TROF 41115 39115 37115
"""

CODSRP_SAMPLE = """
743
FSUS02 KWBC 141729
CODSRP

CODED SURFACE FRONTAL POSITIONS FORECAST
NWS WEATHER PREDICTION CENTER COLLEGE PARK MD
128 PM EDT MON SEP 14 2026

12HR PROG VALID 150600Z
HIGHS 1018 2989 1021 38107 1020 34109 1020 56118 1021 46113 1022 44110 1026
3979 1027 4474 1018 28108
LOWS 1009 39122 1006 33115
STNRY WK 41105 41107 41108 40109 40109 39110
COLD WK 4792 4593 4394 4296 4099 40101 40104 41105
TROF 47125 45125 43124 41123 40122 39122 37121 35120 35119 35118

24HR PROG VALID 151800Z
HIGHS 1030 4271 1022 43100
LOWS 993 5486 1008 33115
COLD WK 4884 4587 4389 4191 3994 3897
WARM WK 4984 4384 3980
"""


METAR_CACHE_HEADER = ("raw_text,station_id,observation_time,latitude,longitude,temp_c,dewpoint_c,"
    "wind_dir_degrees,wind_speed_kt,wind_gust_kt,visibility_statute_mi,altim_in_hg,"
    "sea_level_pressure_mb,corrected,auto,auto_station,maintenance_indicator_on,no_signal,"
    "lightning_sensor_off,freezing_rain_sensor_off,present_weather_sensor_off,wx_string,"
    "sky_cover,cloud_base_ft_agl,sky_cover,cloud_base_ft_agl,sky_cover,cloud_base_ft_agl,"
    "sky_cover,cloud_base_ft_agl,flight_category,three_hr_pressure_tendency_mb,maxT_c,minT_c,"
    "maxT24hr_c,minT24hr_c,precip_in,pcp3hr_in,pcp6hr_in,pcp24hr_in,snow_in,vert_vis_ft,"
    "metar_type,elevation_m")


def sample_metar_cache(extra_rows=()):
    """A slice of AWC's metars.cache.csv in its real column layout: a few
    stations around Cincinnati, one across the country, one with a bogus
    -99.99 position (real military ids do this), one variable wind."""
    rows = [
        # raw, id, time, lat, lon, T, Td, dir, spd, gust, vis, altim, slp, ..., sky pairs, cat
        '"METAR KLUK 151653Z 00000KT 10SM CLR 28/19 A3019 RMK AO2 SLP219",KLUK,2026-09-15T16:53:00.000Z,39.1060,-84.4161,28.3,18.9,0,0,,10+,30.19,1021.9,,,TRUE,,,,,,,CLR,,,,,,,,VFR,,,,,,,,,,,,METAR,144',
        '"METAR KCVG 151652Z 12008G15KT 6SM BR SCT025 BKN040 27/20 A3018",KCVG,2026-09-15T16:52:00.000Z,39.0440,-84.6720,27,20,120,8,15,6,30.18,1021.2,,,TRUE,,,,,,BR,SCT,2500,BKN,4000,,,,,MVFR,,,,,,,,,,,,METAR,269',
        '"METAR KILN 151653Z VRB03KT 10SM OVC008 24/22 A3017",KILN,2026-09-15T16:53:00.000Z,39.4280,-83.7920,24,22,VRB,3,,10+,30.17,,,,TRUE,,,,,,,OVC,800,,,,,,,IFR,,,,,,,,,,,,METAR,329',
        '"METAR KSFO 151656Z 24004KT 10SM FEW015 18/12 A2998",KSFO,2026-09-15T16:56:00.000Z,37.6190,-122.3750,18,12,240,4,,10+,29.98,1015.3,,,TRUE,,,,,,,FEW,1500,,,,,,,null,,,,,,,,,,,,METAR,3',
        '"METAR KQFV 151710Z AUTO 11001KT 9999 CLR 08/07 A3016",KQFV,2026-09-15T17:10:00.000Z,-99.9900,-99.9900,8,7,110,1,,6+,30.16,,,TRUE,TRUE,,,TRUE,,,,,,,,,,,,VFR,,,,,,,,,,,,METAR,9999',
    ]
    return METAR_CACHE_HEADER + "\n" + "\n".join(list(rows) + list(extra_rows)) + "\n"


def metar_cache_row(sid, lat, lon, *, spd=7, d="270", cat="VFR"):
    return (f'"METAR {sid} 151650Z {d}{spd:02d}KT 10SM CLR 20/10 A3000",{sid},'
            f'2026-09-15T16:50:00.000Z,{lat:.4f},{lon:.4f},20,10,{d},{spd},,10+,30.00,,,,TRUE,'
            f',,,,,,CLR,,,,,,,,{cat},,,,,,,,,,,,METAR,100')


def sample_aloft(request, now=None):
    """Open-Meteo's pressure-level shape for two hours from the current UTC
    hour: a cloud deck at 925-850 hPa (80 %), thin cloud at 600 hPa (40 %)
    below freezing, winds veering and strengthening with height."""
    start = (now or datetime.now(timezone.utc)).replace(minute=0, second=0, microsecond=0)
    times = [(start + timedelta(hours=i)).strftime("%Y-%m-%dT%H:%M") for i in range(3)]
    levels = {1000: 110, 975: 330, 950: 560, 925: 790, 900: 1000, 850: 1470, 800: 1960, 700: 3040, 600: 4300, 500: 5700, 400: 7300}
    hourly = {"time": times}
    for p, h in levels.items():
        temp = 16 - h / 1000 * 6.5
        cloud = 80 if p in (925, 900, 850) else (40 if p == 600 else 5)
        hourly[f"geopotential_height_{p}hPa"] = [h] * 3
        hourly[f"temperature_{p}hPa"] = [round(temp, 1)] * 3
        hourly[f"dew_point_{p}hPa"] = [round(temp - (0.5 if cloud >= 50 else 6), 1)] * 3
        hourly[f"cloud_cover_{p}hPa"] = [cloud] * 3
        hourly[f"wind_speed_{p}hPa"] = [10 + h / 200] * 3
        hourly[f"wind_direction_{p}hPa"] = [(30 + h / 40) % 360] * 3
    hourly["freezing_level_height"] = [2700] * 3
    hourly["boundary_layer_height"] = [900] * 3
    hourly["temperature_2m"] = [16] * 3
    hourly["dew_point_2m"] = [12] * 3
    hourly["wind_speed_10m"] = [10] * 3
    hourly["wind_direction_10m"] = [30] * 3
    return {"latitude": float(request.url.params["latitude"]), "longitude": float(request.url.params["longitude"]),
            "hourly_units": {"wind_speed_1000hPa": "kn"}, "hourly": hourly}


def sample_field_levels(request):
    """Winds at each level for every grid point: stronger and veering with
    height, 10 km/h more per level, from 200 degrees plus 15 per level."""
    lats = [float(v) for v in request.url.params["latitude"].split(",")]
    lons = [float(v) for v in request.url.params["longitude"].split(",")]
    start = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    times = [(start + timedelta(hours=i)).strftime("%Y-%m-%dT%H:%M") for i in range(3)]
    out = []
    for la, lo in zip(lats, lons):
        hourly = {"time": times}
        for k, p in enumerate([925, 850, 700, 600, 500]):
            hourly[f"wind_speed_{p}hPa"] = [20.0 + 10 * k] * 3
            hourly[f"wind_direction_{p}hPa"] = [200.0 + 15 * k] * 3
        out.append({"latitude": la, "longitude": lo, "hourly": hourly})
    return out


def sample_field_grid(request):
    """Open-Meteo's multi-location shape: a list, one dict per point, with
    `current` wind and a day of hourly boundary-layer heights. Wind speed
    encodes the point index so tests can check ordering; BL is 900 m at the
    current UTC hour and 300 m elsewhere."""
    lats = [float(v) for v in request.url.params["latitude"].split(",")]
    lons = [float(v) for v in request.url.params["longitude"].split(",")]
    now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    day0 = now.replace(hour=0)
    times = [(day0 + timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M") for h in range(24)]
    out = []
    for i, (la, lo) in enumerate(zip(lats, lons)):
        out.append({
            "latitude": la, "longitude": lo,
            "current": {"wind_speed_10m": 10.0 + i, "wind_direction_10m": 240.0},
            "hourly": {"time": times,
                       "boundary_layer_height": [900.0 if h == now.hour else 300.0 for h in range(24)]},
        })
    return out


def sample_rainviewer_maps(past=13, nowcast=2):
    """RainViewer weather-maps.json: 10-minute frames, hashed paths."""
    base = 1789495800
    return {
        "version": "2.0", "generated": base, "host": "https://tilecache.rainviewer.com",
        "radar": {
            "past": [{"time": base - 600 * (past - 1 - i), "path": f"/v2/radar/p{i:02d}"} for i in range(past)],
            "nowcast": [{"time": base + 600 * (i + 1), "path": f"/v2/radar/n{i:02d}"} for i in range(nowcast)],
        },
        "satellite": {"infrared": []},
    }


def sample_station_info():
    return [
        {"id": "KLUK", "icaoId": "KLUK", "site": "Cincinnati/Lunken Fld", "lat": 39.106, "lon": -84.416,
         "elev": 144, "state": "OH", "country": "US", "priority": 6, "siteType": ["METAR", "TAF"]},
        {"id": "KCVG", "icaoId": "KCVG", "site": "Cincinnati/N Kentucky Intl", "lat": 39.044, "lon": -84.672,
         "elev": 269, "state": "KY", "country": "US", "priority": 5, "siteType": ["METAR", "TAF"]},
        {"id": "KILN", "icaoId": "KILN", "site": "Wilmington Airborne Airpark", "lat": 39.428, "lon": -83.792,
         "elev": 329, "state": "OH", "country": "US", "priority": 6, "siteType": ["METAR"]},
        {"id": "32012", "icaoId": None, "site": "Woods Hole Stratus Wave Station", "lat": 19.7, "lon": -85.6,
         "elev": 0, "state": "", "country": None, "priority": 4, "siteType": []},
        {"id": "KTAF", "icaoId": "KTAF", "site": "Taf Only Field", "lat": 40.0, "lon": -80.0,
         "elev": 100, "state": "PA", "country": "US", "priority": 7, "siteType": ["TAF"]},
        {"id": "KI67", "icaoId": "KI67", "site": "Harrison/West Arpt", "lat": 39.2565, "lon": -84.7753,
         "elev": 177, "state": "OH", "country": "US", "priority": 7, "siteType": ["METAR"]},
    ]


def sample_taf(sid="KLUK"):
    """AWC decoded TAF JSON, trimmed from a real 2026-09-15 product."""
    base = int(datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0).timestamp())
    return [{
        # Real AWC mixes types: issueTime is an ISO string, period times are epochs.
        "icaoId": sid, "issueTime": "2026-09-15T17:20:00.000Z", "validTimeFrom": base, "validTimeTo": base + 24 * 3600,
        "rawTAF": f"TAF {sid} 151720Z 1518/1618 19008KT P6SM SCT250 FM152300 31015G25KT P6SM BKN040 "
                  f"TEMPO 1523/1602 4SM -RA BR OVC020 FM160600 32008KT P6SM SCT050",
        "fcsts": [
            {"timeFrom": base, "timeTo": base + 6 * 3600, "fcstChange": None, "wdir": 190, "wspd": 8, "wgst": None,
             "visib": "6+", "wxString": None, "clouds": [{"cover": "SCT", "base": 25000}]},
            {"timeFrom": base + 6 * 3600, "timeTo": base + 13 * 3600, "fcstChange": "FM", "wdir": 310, "wspd": 15,
             "wgst": 25, "visib": "6+", "wxString": None, "clouds": [{"cover": "BKN", "base": 4000}]},
            {"timeFrom": base + 6 * 3600, "timeTo": base + 9 * 3600, "fcstChange": "TEMPO", "wdir": None, "wspd": None,
             "wgst": None, "visib": 4, "wxString": "-RA BR", "clouds": [{"cover": "OVC", "base": 2000}]},
            {"timeFrom": base + 13 * 3600, "timeTo": base + 24 * 3600, "fcstChange": "FM", "wdir": 320, "wspd": 8,
             "wgst": None, "visib": "6+", "wxString": None, "clouds": [{"cover": "SCT", "base": 5000}]},
        ],
    }]


def sample_glm_file(start, flashes, quality=None):
    """A minimal GLM L2 LCFA file in memory, with the real variable names,
    dtypes and scaling: float32 lat/lon, unsigned int16 time offsets with
    scale/offset against a 'seconds since' base, int16 energy."""
    import io
    import h5py
    import numpy as np
    buf = io.BytesIO()
    with h5py.File(buf, "w") as f:
        f.create_dataset("product_time", data=np.float64((start - datetime(2000, 1, 1, 12, tzinfo=timezone.utc)).total_seconds()))
        f.create_dataset("flash_lat", data=np.array([x[0] for x in flashes], dtype="float32"))
        f.create_dataset("flash_lon", data=np.array([x[1] for x in flashes], dtype="float32"))
        scale, offset = 0.00038148, -5.0
        raw = np.array([round((x[2] - offset) / scale) for x in flashes], dtype="uint16").view("int16")
        t = f.create_dataset("flash_time_offset_of_first_event", data=raw)
        t.attrs["scale_factor"] = np.array([scale], dtype="float32")
        t.attrs["add_offset"] = np.array([offset], dtype="float32")
        t.attrs["_Unsigned"] = np.bytes_(b"true")
        t.attrs["units"] = np.bytes_(start.strftime("seconds since %Y-%m-%d %H:%M:%S.000").encode())
        e = f.create_dataset("flash_energy", data=np.array([100] * len(flashes), dtype="int16"))
        e.attrs["scale_factor"] = np.array([9.99996e-16], dtype="float32")
        e.attrs["add_offset"] = np.array([2.8515e-16], dtype="float32")
        f.create_dataset("flash_quality_flag", data=np.array(quality or [0] * len(flashes), dtype="int16"))
    return buf.getvalue()


def _glm_key(sat, start):
    doy = start.strftime("%Y%j%H%M%S")
    end = (start + timedelta(seconds=20)).strftime("%Y%j%H%M%S")
    return (f"GLM-L2-LCFA/{start:%Y/%j/%H}/OR_GLM-L2-LCFA_{sat}_s{doy}0_e{end}0_c{end}6.nc")


def sample_s3_listing(now, sat="G19"):
    """ListObjectsV2 XML with two 20 s files ending two minutes before now."""
    keys = [_glm_key(sat, now - timedelta(minutes=2)), _glm_key(sat, now - timedelta(minutes=2) + timedelta(seconds=20))]
    items = "".join(f"<Contents><Key>{k}</Key><LastModified>2026-09-17T00:00:31.000Z</LastModified>"
                    f"<Size>361915</Size></Contents>" for k in keys)
    return ('<?xml version="1.0" encoding="UTF-8"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
            f'<Name>noaa-goes19</Name><KeyCount>2</KeyCount>{items}</ListBucketResult>')


def sample_ndbc_latest(now):
    """Three buoys near Cincinnati's box and one far away, the way NDBC's
    latest_obs.txt lays them out; one is too old to count."""
    t = now.replace(minute=0, second=0, microsecond=0)
    old = t.replace(hour=(t.hour - 5) % 24) if t.hour >= 5 else t.replace(day=max(1, t.day - 1))
    def row(stn, lat, lon, when, rest):
        return f"{stn:<7} {lat:>7.3f} {lon:>8.3f} {when:%Y %m %d %H %M} {rest}"
    lines = [
        "#STN       LAT      LON  YYYY MM DD hh mm WDIR WSPD   GST WVHT  DPD APD MWD   PRES  PTDY  ATMP  WTMP  DEWP  VIS   TIDE",
        "#text      deg      deg   yr mo day hr mn degT  m/s   m/s   m   sec sec degT   hPa   hPa  degC  degC  degC  nmi     ft",
        row("45007", 38.9, -84.0, t, "240   6.0   8.5  1.2   6  MM 250 1012.4  -1.6  18.2  19.5  12.0   MM     MM"),
        row("OHCM1", 39.3, -84.9, t, " MM    MM    MM   MM  MM  MM  MM 1013.0    MM  17.0    MM    MM   MM     MM"),
        row("STALE", 39.0, -84.5, old, "180   3.0   4.0   MM  MM  MM  MM 1010.0    MM    MM    MM    MM   MM     MM"),
        row("46026", 37.75, -122.838, t, "320   5.0   6.0  2.0  11  MM 300 1012.4    MM  14.0  14.7    MM   MM     MM"),
    ]
    return "\n".join(lines) + "\n"


def sample_lamp(run):
    """The real 2130 UTC 2026-09-24 LAMP bulletin for four stations, with
    its run time and hour row moved to `run` so the hours lie ahead."""
    import re
    path = os.path.join(os.path.dirname(__file__), "fixtures", "lamp_lav.txt")
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    text = re.sub(r"\d{1,2}/\d{1,2}/\d{4}  \d{4} UTC", f"{run.month}/{run.day}/{run.year}  {run:%H%M} UTC", text)
    hours = "".join(f" {(run.hour + 1 + i) % 24:02d}" for i in range(25))
    return re.sub(r"(?m)^ UTC .*$", " UTC " + hours, text)


@pytest.fixture(autouse=True)
def _nomads_unspaced(monkeypatch):
    """NOMADS spacing is ten seconds in production; tests fetch at once.
    HRRR is off unless a test turns it on, so the map layers the older
    tests check still come from Open-Meteo."""
    monkeypatch.setenv("BARRY_NOMADS_SPACING", "0")
    monkeypatch.setenv("BARRY_HRRR", "0")
    monkeypatch.setenv("BARRY_MRMS", "0")
    # The day-long column feed takes 31 hours of each 48-hour cycle; tests
    # that don't read the column need only a few, and it is most of the time.
    monkeypatch.setattr("app.sources.hrrr.EXTENDED_LAST", 3)
    monkeypatch.setattr("app.sources.hrrr.FC_LAST", 3)
    monkeypatch.setattr("app.sources.hrrr.EXTENDED_FC_LAST", 3)
    monkeypatch.setattr("app.sources.nbm.FHRS", (1, 2, 3))
    yield


def _hrrr_fixture(kind):
    path = os.path.join(os.path.dirname(__file__), "fixtures", f"hrrr_{kind}.grib2")
    with open(path, "rb") as fh:
        return fh.read()


def sample_mrms(lightning=False):
    """A small MRMS-shaped file: 0.05 degree from 45 N, 95 W to 35 N, 75 W
    (north to south, as MRMS scans), no echo (-99) everywhere but a 45 dBZ
    cell over Cincinnati and a 60 dBZ single pixel near Dayton; no coverage
    (-999) along the south edge. GRIB2, simple packing, gzipped."""
    import gzip as _gz
    import eccodes
    import numpy as np
    ni, nj, d = 400, 200, 0.05
    lat = 45.0 - np.arange(nj) * d
    lon = -95.0 + np.arange(ni) * d
    v = np.full((nj, ni), -99.0)
    la, lo = np.meshgrid(lat, lon, indexing="ij")
    v[(np.abs(la - 39.1) < 0.2) & (np.abs(lo + 84.5) < 0.2)] = 45.0
    v[np.argmin(np.abs(lat - 39.9)), np.argmin(np.abs(lon + 84.2))] = 60.0
    v[-3:, :] = -999.0
    if lightning:
        # Chance of lightning: 60 percent over the Cincinnati cell, none elsewhere.
        v = np.where(v == 45.0, 60.0, 0.0)
    h = eccodes.codes_grib_new_from_samples("GRIB2")
    for k, val in [("Ni", ni), ("Nj", nj), ("latitudeOfFirstGridPointInDegrees", 45.0),
                   ("longitudeOfFirstGridPointInDegrees", 265.0),
                   ("latitudeOfLastGridPointInDegrees", 45.0 - (nj - 1) * d),
                   ("longitudeOfLastGridPointInDegrees", 265.0 + (ni - 1) * d),
                   ("iDirectionIncrementInDegrees", d), ("jDirectionIncrementInDegrees", d),
                   ("jScansPositively", 0), ("packingType", "grid_simple"), ("bitsPerValue", 16)]:
        eccodes.codes_set(h, k, val)
    eccodes.codes_set_values(h, v.ravel())
    msg = eccodes.codes_get_message(h)
    eccodes.codes_release(h)
    return _gz.compress(msg)


def sample_mrms_listing(now, prefix):
    """ListObjectsV2 for the MRMS composite: a file 40 s past every even
    minute over the last three hours, as far as the day in `prefix`."""
    day = prefix.rstrip("/").rsplit("/", 1)[-1]
    items = []
    t = now.replace(second=0, microsecond=0) - timedelta(hours=3)
    while t <= now - timedelta(seconds=45):
        if t.minute % 2 == 0 and t.strftime("%Y%m%d") == day:
            ft = t + timedelta(seconds=40)
            items.append(f"<Contents><Key>{prefix}MRMS_MergedReflectivityQCComposite_00.50_{ft:%Y%m%d-%H%M%S}.grib2.gz</Key>"
                         f"<Size>1200000</Size></Contents>")
        t += timedelta(minutes=1)
    return ('<?xml version="1.0" encoding="UTF-8"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
            + "".join(items) + "</ListBucketResult>")


class FakeUpstream:
    """Records calls and serves canned AWC / Open-Meteo responses."""

    def __init__(self):
        self.awc_calls = []
        self.om_calls = []
        self.awc_fail = False
        # GLM keys are minted from this clock; a test that freezes it (and
        # app.service._now) gets the same listing on every poll.
        self.clock = lambda: datetime.now(timezone.utc)
        # Drop the next METAR call at the socket, the way AWC drops an idle
        # keep-alive connection; the call after that works.
        self.awc_drop_once = False
        self.om_fail = False
        # Front-watch knobs: what a bbox query returns ("west_falls" /
        # "east_falls" / "flat" / None = empty body) and whether the forecast
        # curve contains a real trough (drives the interpreter's ETA).
        self.bbox_pattern = None
        self.om_trough = False
        # IEM HRRR tiles: the run stamp (YYYYMMDDHHMI) tiles exist for, or
        # None. Unknown layers get the same fixed bytes real tile.py returns
        # for anything invalid — the probe logic keys on that.
        self.hrrr_run = None
        self.iem_fail = False
        self.iem_calls = []
        self.wpc_fail = False
        # Bulk METAR cache: served gzip'd like AWC; extra_rows lets a test
        # pile on stations to exercise thinning.
        self.bulk_fail = False
        self.rv_fail = False
        self.rv_calls = 0
        self.bulk_extra_rows = ()
        self.bulk_calls = 0

    def handler(self, request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if "noaa-mrms-pds" in url:
            self.mrms_calls = getattr(self, "mrms_calls", 0) + 1
            if getattr(self, "mrms_fail", False):
                return httpx.Response(503, text="down")
            if "list-type=2" in url:
                prefix = request.url.params.get("prefix", "")
                after = request.url.params.get("start-after", "")
                xml = sample_mrms_listing(self.clock(), prefix)
                if "LightningProbability" in prefix:
                    xml = xml.replace("MergedReflectivityQCComposite_00.50", "LightningProbabilityNext60minGrid_scale_1")
                if after:
                    import re
                    keep = [c for c in re.findall(r"<Contents>.*?</Contents>", xml)
                            if re.search(r"<Key>(.*?)</Key>", c).group(1) > after]
                    xml = xml.split("<Contents>")[0] + "".join(keep) + "</ListBucketResult>"
                return httpx.Response(200, text=xml)
            if "LightningProbability" in url:
                if not hasattr(self, "_ltg_file"):
                    self._ltg_file = sample_mrms(lightning=True)
                return httpx.Response(200, content=self._ltg_file)
            if not hasattr(self, "_mrms_file"):
                self._mrms_file = sample_mrms()
            self.mrms_files = getattr(self, "mrms_files", 0) + 1
            return httpx.Response(200, content=self._mrms_file)
        if "noaa-nbm-grib2-pds" in url:
            # NBM: the small fixture for any run and hour, the index filled
            # in with the hour asked for; nbm_runs, when set, are the runs
            # the bucket has.
            import re
            self.nbm_calls = getattr(self, "nbm_calls", [])
            self.nbm_calls.append((request.method, url.rsplit("/", 1)[-1], request.headers.get("range")))
            m = re.search(r"blend\.(\d{8})/(\d{2})/core/blend\.t\d{2}z\.core\.f(\d{3})\.co\.grib2(\.idx)?$", url)
            if not m:
                return httpx.Response(404)
            run = datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H").replace(tzinfo=timezone.utc)
            have = getattr(self, "nbm_runs", None)
            if have is not None and run not in have:
                return httpx.Response(404, text="NoSuchKey")
            fx = os.path.join(os.path.dirname(__file__), "fixtures")
            if m.group(4):
                f = int(m.group(3))
                with open(os.path.join(fx, "nbm.idx.tmpl")) as fh:
                    return httpx.Response(200, text=fh.read().replace("{f}", str(f)).replace("{p}", str(f - 1)))
            with open(os.path.join(fx, "nbm.grib2"), "rb") as fh:
                data = fh.read()
            rng = request.headers.get("range")
            if rng and request.method == "GET":
                a, b = rng.split("=", 1)[1].split("-")
                return httpx.Response(206, content=data[int(a): (int(b) + 1) if b else len(data)])
            return httpx.Response(200, content=data)
        if "noaa-hrrr-bdp-pds" in url or "/hrrr/prod/" in url:
            # HRRR on the AWS bucket or NOMADS: the small fixture grid for
            # any cycle and hour, byte ranges honoured. hrrr_aws and
            # hrrr_nomads, when set, are the cycles each one has.
            import re
            self.hrrr_calls = getattr(self, "hrrr_calls", [])
            where = "nomads" if "nomads" in url else "aws"
            self.hrrr_calls.append((where, request.method, url.rsplit("/", 1)[-1], request.headers.get("range")))
            if getattr(self, "hrrr_fail", False):
                return httpx.Response(503, text="down")
            m = re.search(r"hrrr\.(\d{8})/conus/hrrr\.t(\d{2})z\.wrf(sfc|prs)f(\d{2})\.grib2(\.idx)?$", url)
            if not m:
                return httpx.Response(404)
            cycle = datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H").replace(tzinfo=timezone.utc)
            have = getattr(self, "hrrr_nomads" if where == "nomads" else "hrrr_aws", None)
            if have is not None and cycle not in have:
                return httpx.Response(404, text="NoSuchKey")
            kind = m.group(3)
            if m.group(5):
                with open(os.path.join(os.path.dirname(__file__), "fixtures", f"hrrr_{kind}.grib2.idx")) as fh:
                    return httpx.Response(200, text=fh.read())
            data = _hrrr_fixture(kind)
            rng = request.headers.get("range")
            if rng and request.method == "GET":
                a, b = rng.split("=", 1)[1].split("-")
                start, end = int(a), (int(b) if b else len(data) - 1)
                return httpx.Response(206, content=data[start:end + 1])
            return httpx.Response(200, content=data)
        if "s3.amazonaws.com" in url:
            # NOAA's public GOES buckets: a listing per hour, then the files.
            if getattr(self, "s3_fail", False):
                return httpx.Response(503, text="down")
            now = self.clock()
            sat = "G18" if "goes18" in url else "G19"
            if "list-type=2" in url:
                self.s3_lists = getattr(self, "s3_lists", 0) + 1
                prefix = request.url.params.get("prefix", "")
                if prefix != f"GLM-L2-LCFA/{now:%Y/%j/%H}/":
                    return httpx.Response(200, text=sample_s3_listing(now, sat).split("<Contents>")[0] + "</ListBucketResult>")
                return httpx.Response(200, text=sample_s3_listing(now, sat))
            self.s3_files = getattr(self, "s3_files", 0) + 1
            start = now - timedelta(minutes=2)
            pts = ([(39.30, -84.65, 1.0), (39.31, -84.66, 2.0), (39.60, -84.90, 3.0)] if sat == "G19"
                   else [(39.30, -84.65, 1.0), (44.0, -120.0, 2.0)])   # East also sees the West's side; split drops dupes
            return httpx.Response(200, content=sample_glm_file(start, pts),
                                  headers={"content-type": "application/x-netcdf"})
        if "nomads.ncep.noaa.gov" in url:
            # NOMADS: the LAMP bulletin for whatever run is asked for,
            # unless that run is listed as not landed yet.
            import re
            self.nomads_calls = getattr(self, "nomads_calls", [])
            self.nomads_calls.append(url)
            if getattr(self, "nomads_fail", False):
                return httpx.Response(503, text="down")
            if "gtgn/prod/" in url or "cip/para/" in url:
                kind = "gtg" if "gtgn" in url else "cip"
                if kind in getattr(self, "hazards_missing", ()):
                    return httpx.Response(404, text="not found")
                with open(os.path.join(os.path.dirname(__file__), "fixtures", f"{kind}.grib2"), "rb") as fh:
                    return httpx.Response(200, content=fh.read())
            m = re.search(r"lmp\.(\d{8})/lmp\.t(\d{4})z\.lavtxt\.ascii$", url)
            if not m:
                return httpx.Response(404, text="not found")
            run = datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M").replace(tzinfo=timezone.utc)
            if run in getattr(self, "lamp_missing", ()):
                return httpx.Response(404, text="not found")
            return httpx.Response(200, text=sample_lamp(run))
        if "afos/retrieve.py" in url:
            # WPC coded front bulletins (text). Trimmed from real 2026-09-14
            # products so the parser is tested against the genuine format.
            pil = request.url.params.get("pil", "")
            if self.wpc_fail:
                return httpx.Response(503, text="down")
            if pil == "CODSUS":
                return httpx.Response(200, text=CODSUS_SAMPLE)
            if pil == "CODSRP":
                return httpx.Response(200, text=CODSRP_SAMPLE)
            return httpx.Response(200, text="")
        if "mesonet.agron.iastate.edu" in url:
            self.iem_calls.append(request)
            # Faithful to real tile.py: runs it has -> 200 image/png; runs it
            # doesn't (or a dead service) -> 503 text/plain.
            if self.iem_fail:
                return httpx.Response(503, text="down")
            if self.hrrr_run and f"-{self.hrrr_run}/" in url:
                return httpx.Response(200, content=b"REAL-HRRR-TILE",
                                      headers={"content-type": "image/png"})
            return httpx.Response(503, text="no such layer")
        if "data/cache/stations.cache.json.gz" in url:
            import gzip, json
            self.info_calls = getattr(self, "info_calls", 0) + 1
            if getattr(self, "info_fail", False):
                return httpx.Response(503, text="down")
            return httpx.Response(200, content=gzip.compress(json.dumps(sample_station_info()).encode()),
                                  headers={"content-type": "application/x-gzip"})
        if "data/cache/metars.cache.csv.gz" in url:
            import gzip
            self.bulk_calls += 1
            if self.bulk_fail:
                return httpx.Response(503, text="down")
            body = gzip.compress(sample_metar_cache(self.bulk_extra_rows).encode("utf-8"))
            return httpx.Response(200, content=body,
                                  headers={"content-type": "application/x-gzip"})
        if "aviationweather.gov/api/data/airsigmet" in url or "aviationweather.gov/api/data/gairmet" in url \
                or "aviationweather.gov/api/data/pirep" in url:
            self.adv_calls = getattr(self, "adv_calls", 0) + 1
            if getattr(self, "adv_fail", False):
                return httpx.Response(503, text="down")
            name = "awc_airsigmet" if "airsigmet" in url else ("awc_gairmet" if "gairmet" in url else "awc_pirep")
            path = os.path.join(os.path.dirname(__file__), "fixtures", name + ".json")
            with open(path, encoding="utf-8") as fh:
                return httpx.Response(200, content=fh.read().encode("utf-8"),
                                      headers={"content-type": "application/json"})
        if "ndbc.noaa.gov" in url:
            self.ndbc_calls = getattr(self, "ndbc_calls", 0) + 1
            if getattr(self, "ndbc_fail", False):
                return httpx.Response(503, text="down")
            return httpx.Response(200, text=sample_ndbc_latest(self.clock()))
        if "rainviewer.com" in url:
            self.rv_calls += 1
            if self.rv_fail:
                return httpx.Response(503, text="down")
            return httpx.Response(200, json=sample_rainviewer_maps())
        if "aviationweather.gov" in url and "/api/data/taf" in url:
            self.taf_calls = getattr(self, "taf_calls", 0) + 1
            sid = request.url.params.get("ids", "")
            if getattr(self, "taf_fail", False):
                return httpx.Response(503, text="down")
            if sid == "KLUK":
                return httpx.Response(200, json=sample_taf(sid))
            return httpx.Response(200, text="")          # no TAF issued
        if "aviationweather.gov" in url:
            self.awc_calls.append(request)
            if self.awc_fail:
                return httpx.Response(503, text="blocked")
            if self.awc_drop_once:
                self.awc_drop_once = False
                raise httpx.ReadError("Server disconnected", request=request)
            if request.url.params.get("bbox"):
                if self.bbox_pattern is None:
                    return httpx.Response(200, text="")
                return httpx.Response(200, json=sample_bbox_metars(self.bbox_pattern))
            ids = request.url.params.get("ids", "").split(",")
            recs = []
            for sid in ids:
                # Like real AWC: only K-prefixed identifiers report (typing
                # "LUK" or "I67" returns nothing; "KLUK"/"KI67" work).
                if sid and sid.startswith("K"):
                    recs.extend(sample_metars(sid))
            if not recs:
                # Faithful to real AWC: unknown identifiers get an EMPTY BODY,
                # not an empty JSON array — this exact quirk broke normalization
                # in production while the tests passed.
                return httpx.Response(200, text="")
            return httpx.Response(200, json=recs)
        if "open-meteo.com" in url:
            self.om_calls.append(request)
            if self.om_fail:
                return httpx.Response(503, text="down")
            if "hPa" in request.url.params.get("hourly", "") and "," in request.url.params.get("latitude", ""):
                self.field_level_calls = getattr(self, "field_level_calls", 0) + 1
                return httpx.Response(200, json=sample_field_levels(request))
            if "hPa" in request.url.params.get("hourly", ""):
                self.aloft_calls = getattr(self, "aloft_calls", 0) + 1
                return httpx.Response(200, json=sample_aloft(request, self.clock()))
            if "," in request.url.params.get("latitude", ""):
                return httpx.Response(200, json=sample_field_grid(request))
            return httpx.Response(200, json=sample_forecast(trough=self.om_trough))
        return httpx.Response(404)


@pytest.fixture(autouse=True)
def _no_per_ip_budget():
    """Every test shares one app object, and with it one per-address
    budget; the suite as a whole is well over sixty requests a minute.
    Tests about the budget install their own limiter."""
    from app.guards import IPLimiter
    from app.main import app
    app.state.ip_limiter = IPLimiter(per_minute=0)
    yield


@pytest.fixture
def upstream():
    return FakeUpstream()


@pytest.fixture
def client(upstream):
    transport = httpx.MockTransport(upstream.handler)
    return httpx.AsyncClient(transport=transport, timeout=5.0)
