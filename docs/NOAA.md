# Barry on NOAA data

Written 2026-09-24. This is the plan for moving Barry's forecast, map and radar
inputs off Open-Meteo's public API and RainViewer and onto NOAA's own model
and radar output, processed on Tower.

Why now:

- Open-Meteo's free API is for non-commercial use, and every map point in a
  multi-point request counts as a call. The radar wind grid is 35 calls a
  view, so the 10,000-a-day cap covers a few dozen active users. Charging
  anything, or showing ads, ends the free tier.
- RainViewer's API is "personal and educational use only".
- The features on the table (height contours at altitude, dense wind at
  every level, a sharper Aloft column) need whole grids, not sampled points.
- The data behind both services is NOAA's anyway. Open-Meteo's automatic
  model pick at KLUK returned HRRR's numbers exactly. RainViewer's US radar
  is the NEXRAD network.

The rule this plan follows is the one lightning already follows: a fixed
cost on Tower that is the same for ten users or ten thousand, from sources
that are public domain. The US is the target. Everything outside the HRRR
grid keeps whatever fallback is cheapest and is not a design goal.

Sections: what was verified, what the papers change, the architecture, the
phases, the budget, the decisions to make, the risks, and the sources.

## 1. What was verified

Everything here was measured against the live buckets on 2026-09-23 and 24.
Byte-range fetches, decoding, contouring, tile rendering and optical flow
were run on a Mac with the packages the container would use.

| Feed | Bucket | Cadence and length | Arrives after cycle time | File and field sizes | Grid |
|---|---|---|---|---|---|
| HRRR | noaa-hrrr-bdp-pds | Hourly to 18 h; 48 h at 00, 06, 12, 18 UTC | f00 about 50 min, f18 about 85 min, f48 about 107 min | Surface file 135 to 170 MB (170 fields), pressure file 390 to 455 MB (40 levels x 14 fields), sub-hourly file 170 to 240 MB. One field by byte range: 0.4 to 3 MB, 0.2 to 0.3 s to fetch, 30 ms to decode | Lambert conformal, 1799 x 1059, 3 km |
| NBM v5.0 | noaa-nbm-grib2-pds | Hourly runs; hourly to 48 h, 3-hourly to 192 h, 6-hourly to 264 h | 66 to 70 min, whole run in 5 min | 160 to 200 MB an hour. The 12 fields the home card needs: 18 MB an hour | Lambert conformal, 2345 x 1597, 2.5 km |
| GFS 0.25 | noaa-gfs-bdp-pds | 4 cycles a day; hourly to 120 h, 3-hourly to 384 h | 3.5 to 5 h | 480 to 550 MB a file | 0.25 degree global |
| MRMS | noaa-mrms-pds | Composite reflectivity every 2 min; 243 products | 45 s median for the composite, about 3 min for rain rate | 1.1 to 1.4 MB gzipped, 0.2 s to decode with Pillow | 0.01 degree lat/lon, 7000 x 3500, 20 to 55 N, 130 to 60 W |
| RRFS v1 | noaa-rrfs-ops-pds | Operational 2026-10-14 (SCN 26-48); hourly to 18 h, 84 h at 00, 06, 12, 18 UTC | 75 to 80 min in the parallel feed | Two-dimensional file 320 to 350 MB, pressure file about 590 MB (45 levels) | The HRRR grid, unchanged |
| Open-Meteo open data | openmeteo (us-west-2) | Hourly; HRRR, NBM, GFS and others already decoded | About the same as the source model | About 0.4 MB per field per hour in the per-hour spatial files, 103 MB for all 264 HRRR variables | Native grids |

Points that shape the design:

- **Byte ranges make the big files cheap.** Every NOAA GRIB file has a
  `.idx` sidecar listing each field's byte offset. One HTTP range request
  pulls one field. Match on the field's name and level string, never its
  record number, because numbers shift between f00 and later hours.
- **HRRR carries what Barry uses today, and more.** 10 m wind and gust, 2 m
  temperature and dew point, boundary layer height, CAPE and CIN, sea-level
  pressure (`MSLMA`), composite reflectivity, low, middle, high and total
  cloud, ceiling, visibility, precipitation rate, freezing level. The
  pressure file adds height, temperature, dew point, wind, vertical motion
  and cloud water at 40 levels every 25 hPa. The sub-hourly file has 15
  minute wind, gust, visibility, reflectivity and precipitation.
- **NBM is the right source for the home forecast.** It is NOAA's
  bias-corrected blend of about thirty models, the starting point for
  Weather Service forecasts, with real probabilities: rain in the hour,
  thunder in the hour, ceiling below 500 to 6,600 ft, visibility below 1 to
  5 miles, and precipitation type. It has no sea-level pressure, so the
  pressure forecast stays with HRRR.
- **GFS is not needed.** Barry's horizon is 48 hours, which HRRR and NBM
  cover.
- **RRFS is three weeks out and uses the HRRR grid.** Its files are named
  differently, its sea-level pressure field is `MSLET`, and it has 45
  levels. HRRR is not retired by this release and the retirement has no
  date. Build the ingest so a feed is a table of names, not code.
- **MRMS needs no GRIB library.** Its files are single GRIB2 messages with
  PNG packing, so Pillow and numpy decode them. Reflectivity has a 0.1 dBZ
  step; missing is -99 and no coverage is -999. The bucket also holds
  precipitation type, rain rate, lightning density from the NLDN ground
  network, and NOAA's own lightning probability for the next 30 and 60
  minutes.
- **Open-Meteo publishes its decoded data too.** Their AWS Open Data bucket
  holds HRRR, NBM and GFS already decoded and compressed, under CC BY 4.0,
  and their server runs as a container that reads it on demand with the
  same URL syntax as the public API. This is the bridge in phase 1.
- **Contouring is fast.** A 500 hPa height field or a sea-level pressure
  field, box-averaged to 12 km and smoothed, contours in 10 ms with
  contourpy. Tile rendering from the radar grid is 1 to 2 ms a tile.
  Optical flow over the whole radar grid is well under a second.
- **Tower can take it.** 12 cores, 31 GB, 289 GB free on the NVMe cache,
  45 TB on the array. The backend container uses 210 MB of a 768 MB limit
  and idles at 0.04% CPU. Lightning already pulls about 2.5 GB a day from
  NOAA on S3.

### NOMADS (measured 2026-09-24)

NOMADS (nomads.ncep.noaa.gov) is NCEP's own real-time server, the place
the files are written first. The AWS buckets are copies of it.

- **It is not meaningfully faster for the big models.** Last-Modified on
  the same files, 38 HRRR surface files from seven cycles: AWS was 0.3 to
  1.2 minutes behind NOMADS for 36 of them and 10 minutes behind for two.
  NBM, 9 files: 1.4 to 3.8 minutes behind. RTMA rapid update: about a
  minute. So AWS stays the primary for HRRR, NBM, MRMS and RTMA, and
  NOMADS is the fallback mirror when an AWS file is late.
- **It carries aviation products that are not on AWS.** No bucket found
  for any of these:
  - **LAMP** (`lmp/prod`), MDL's station guidance for 2,313 sites,
    including fields with no TAF (KI69, KMWO, KI68 and KHAO all have it).
    The full bulletin runs hourly at :30 and covers 25 hours: temperature,
    dew point, wind, gust, precipitation and thunder probability, lightning
    probability (`LP1`), ceiling and visibility categories, cloud cover.
    4.4 MB of fixed-column text for every site. An extended bulletin
    carries hours 26 to 38. Every 15 minutes a smaller run updates
    ceiling, visibility and flight category (with probabilities for each
    category) in 15 minute steps to 6 hours. Hourly lightning and
    convection probability grids at 2.5 km come with it (6 to 8 MB each).
  - **GTG nowcast** (`gtgn/prod`), turbulence as eddy dissipation rate
    (EDR) every 1,000 ft from 100 to 50,000 ft MSL, on the HRRR grid,
    every 15 minutes, 29 MB, about a minute after its valid time. In
    production since NOMADS 2.3.19. Analysis only; no forecast hours.
    Sampled on the day: 0.04 to 0.14 over KLUK (smooth), 0.12 to 0.24
    over KDEN (light).
  - **CIP v2.0** (`cip/para`), current icing: probability, severity
    category and supercooled large drop potential every 500 ft from 500
    to 30,000 ft MSL, on the HRRR grid, hourly, 40 MB, about 11 minutes
    after the hour. Still "para", out for public evaluation, so it can
    change or stop. Sampled on the day: nothing over KLUK, icing from
    14,000 to 25,000 ft over KDEN.
- **Rules of the road.** No per-minute cap is published. The grib filter
  page asks scripts to wait 10 seconds between looped fetches and says
  the server may block a client it mistakes for a denial of service. Use
  a named User-Agent, build file names from the cycle time rather than
  listing directories, and space requests. Directory listings come back
  as an empty 200 over HTTP/2; ask for HTTP/1.1 when listing. NWS data is
  public domain (weather.gov/disclaimer).
- **Tower pulls it quickly.** 4.6 MB of LAMP in 0.3 s and a 30 MB GTG
  file in 0.8 s over the fibre.
- **Decoding** uses the same eccodes path as HRRR (GTG: 51 messages in
  0.5 s; CIP: 180 in 0.1 s). LAMP needs no library at all.

## 2. What the papers change

The published evaluations matter for how Barry words things, not just where
the numbers come from.

**HRRR** (Dowell et al. 2022 and James et al. 2022; Fovell and Gallagher
2020; Fovell and Capps 2024; Bianco et al. 2021)

- HRRR is designed for 0 to 18 hours. Ceiling skill drops fast: the hit
  rate for a 1,000 ft ceiling goes from about 0.9 at the analysis to 0.4 to
  0.6 by 3 to 6 hours out. Convective skill drops the same way. Barry
  should use HRRR for the map, the near term and the column, and NBM for
  the day ahead.
- 10 m wind runs a little strong, especially in the eastern US and at
  night: about 0.5 to 1 m/s (1 to 2 kts). Version 4 added two drag schemes
  to cut this. It is worst at sheltered sites and grows with lead time.
  Airport forecasts are good but under-predict the strongest speeds.
  Barry's wind copy already rounds; keep it that way and don't promise
  gust tops.
- Boundary layer height: the model grows the layer better than it collapses
  it in the evening. Cloudy days are worse than clear ones. The boundary
  layer row should stay confident about the morning rise and hedge the
  afternoon fall, which is the opposite of what a reader would assume.
- Morning profiles erode the nocturnal stable layer too quickly. The Aloft
  column's early-morning inversions will be weaker than reality.
- 2 m temperature has a warm bias at elevation and in the western US;
  daytime dew point runs dry in the West. Neither matters much for the
  Ohio Valley. Both matter for the mountain states.

**NBM** (Hamill et al. 2017; Craven et al. 2020)

- Each input model is bias-corrected against the URMA analysis with a
  decaying average, then weighted by its recent error, per element, per
  grid point, per hour. Rain probability is built by quantile mapping
  ensemble members against 60 days of history. This is why NBM beats any
  single model for a point forecast, and why its rain percentage is a real
  probability. The hourly rain chance on the forecast cards becomes honest
  for the first time.
- Version 5.0 (May 2026) extended hourly output to 48 hours and blends
  climatology into wind and gust to cut the medium-range bias.

**MRMS** (Zhang et al. 2016; Smith et al. 2016)

- Composite reflectivity is the maximum in the column above each point.
  It shows storms well but keeps bright-band contamination from the melting
  layer, so a winter stratiform band can look heavier than it is.
  Reflectivity at the lowest altitude and the seamless hybrid scan are
  what reaches the ground; the rain rate product is built from the hybrid
  scan and already applies the right reflectivity-to-rain relation per
  precipitation type. Barry's loop can stay on the composite, which is
  what RainViewer shows, and the "rain starts at" logic should read the
  rain rate grid instead of guessing from dBZ.
- Quality control removes birds, insects, ground clutter and sun strobes
  with dual-polarization and a neural network. Beam blockage and range are
  scored in a quality index grid.
- Precipitation type has seven classes on the bucket: warm and cool
  stratiform rain, convective rain, rain with hail, snow, and two tropical
  mixes. Snow is surface temperature below 2 C with a wet-bulb below 0.
  There is no freezing rain class; that has to come from NBM or HRRR.
- Rough rates from the paper's stratiform relation: 20 dBZ is 0.6 mm/h,
  30 is 2.7, 40 is 11.5, 50 is the 48.6 cap. Convective rates run higher.

**Nowcasting** (Pulkkinen et al. 2019, pySTEPS; Ayzel et al. 2019,
rainymotion; Hwang et al. 2015)

- Simple extrapolation of the last radar frames beats HRRR for the first
  two hours. Blends beat HRRR out to five. NOAA's own radar extrapolation
  product was discontinued in 2023, so this is ours to build if we want it.
- Extrapolation is reliable and sharp for light rain to about two hours,
  and for heavy rain to about 45 minutes. Cell growth and decay are the
  part it cannot see.
- The motion field between frames two minutes apart is under two pixels,
  which is noisy. Use frames six to ten minutes apart for the motion and
  step the advection every two minutes.
- NOAA does publish a lightning nowcast: probability of a strike in the
  next 30 and 60 minutes, every two minutes, from radar and environment.

**What this means for the join.** Use HRRR for hours 0 to 6 and NBM from 6
to 48, joined at a fixed hour so a card never shows a seam moving around.
Sea-level pressure, the boundary layer, CAPE and the column come from HRRR
at every hour, because NBM does not carry them.

## 3. Architecture

The pattern is the one lightning uses: a scheduler loop per feed, files
listed from the bucket, pulled, decoded, kept in a store, and served by the
same routes and models the app already reads.

**Ingest, one module per feed** (`app/sources/hrrr.py`, `nbm.py`, `mrms.py`)

- `latest_cycles(now)` lists the bucket for the newest cycle whose needed
  hours are all present, and the previous one as the fallback. MRMS has no
  "latest" pointer; list the current hour's prefix (about 30 keys).
- `inventory(url)` reads the `.idx` and returns byte ranges by name and
  level.
- `fetch(url, fields)` issues one range request per field with the retry
  and timeout rules from `guards.py`, and counts bytes in `metrics`.
- `decode(bytes)` returns a float32 array plus the grid parameters.
- Field names live in one table per feed: Barry's name, the GRIB name, the
  level string, and the unit conversion. RRFS becomes a second table on the
  same grid.

**Decoding**

- GRIB: the `eccodes` Python package with Debian's `libeccodes0` (about
  3 MB to download, 60 to 70 MB installed) and `ECCODES_PYTHON_USE_FINDLIBS=1`.
  The pure-pip route pulls a 172 MB library stack, and pygrib is 132 MB, so
  the apt route wins. Decoding one byte-range message is
  `codes_new_from_message`, `codes_get_values`, release.
- MRMS: gunzip, then Pillow on the PNG payload inside the message. No
  GRIB library involved.
- Herbie, the usual Python tool for this, does the same idx and byte-range
  work but drags pandas, xarray, cfgrib and pyproj. Its source is a good
  reference for the idx parsing and the "latest run" search, and that is
  all we need from it.

**Grids** (`app/grids.py`)

- A `LambertGrid` built from the GRIB parameters (HRRR: standard parallels
  38.5, central meridian 262.5, first point 21.138 N 237.280 E, 3,000 m
  spacing, sphere of 6,371,229 m). Forward and inverse projection in numpy;
  no pyproj.
- `locate(lat, lon)` returns the four surrounding points and bilinear
  weights. `window(bbox, stride)` returns the sub-array and the lat/lon of
  its points for a map region. `LatLonGrid` does the same for MRMS, where
  a Web Mercator tile is one latitude lookup per row and one longitude
  lookup per column.
- The grid's lat/lon arrays are computed once per grid and cached on disk.

**Store** (`backend/state/model/<feed>/<cycle>/<fhr>/<field>.npy`)

- Float16 memmaps, 3.8 MB per HRRR field per hour, so the page cache does
  the memory management and a restart costs nothing. A manifest JSON per
  cycle records what is complete. Keep two cycles, purge the rest.
- MRMS frames are uint8 dBZ at 0.5 dBZ steps, 24.5 MB each. Keep two hours
  at 10 minute spacing plus the latest, and the last three rain rate and
  type grids for the nowcast and the rain-start logic.

**Serving**

- The existing routes keep their response models. `/radar/field`,
  `/radar/field/levels`, `/aloft` and `/forecast` get a second
  implementation behind `BARRY_HRRR`, `BARRY_NBM` and `BARRY_MRMS` flags,
  with the phase 1 bridge as the fallback until phase 7 removes it.
- New routes: `/radar/heights` (contours at a level for a window),
  `/radar/tiles/{frame}/{z}/{x}/{y}.png` (radar), `/radar/nowcast`, and
  `/radar/lightning/next` (the NOAA probability grid).
- Contours: box-average to 12 km, smooth once, contourpy, clip to the
  window, emit the same `ContourLine` model the isobars use, so the map
  draws them with the code it has.
- Point extraction is bilinear on the native grid. A forecast for a
  location is one column read across the hours of the newest complete
  cycle.

**Health and metrics**

- Each feed reports its newest cycle age. `Scheduler.problems()` marks the
  feed degraded when the age passes three hours (ten minutes for radar),
  and the route serves the previous cycle. `/healthz?strict=1` fails only
  when nothing usable is held.
- Counters: bytes pulled per feed, fields decoded, cycle age, tile renders,
  tiles served from the in-memory cache.

**Container**

- Memory limit from 768 MB to 3 GB. State on the NVMe cache. The image
  grows by about 75 MB for the GRIB stack, contourpy and Pillow, and 61 MB
  more if the nowcast uses OpenCV.

**Tests**

- eccodes can write GRIB messages from its samples, so unit tests build a
  20 x 20 Lambert grid in memory and run the whole chain on it. One real
  HRRR field (0.6 MB) checked in exercises the decoder, and one real MRMS
  file (1.1 MB) the PNG path. The contract and property tests carry over
  unchanged because the response models don't change.

## 4. Phases

Each phase ships on its own, replaces one dependency, and leaves the app
working if the next phase never happens. Bandwidth figures are what Tower
would pull from S3 per day, from the field sizes measured above.

### Phase 0. Guard the free tier

Done 2026-09-24. `OMBudget` in `guards.py` counts Open-Meteo calls the way
Open-Meteo does (`call_weight` in `sources/openmeteo.py`), 500 a minute and
9,000 a UTC day; the grids are held until five past the next hour and
serve their last good copy for up to six hours past the budget; the day's
count is `barry_openmeteo_calls_today` on /metrics. The half-degree lattice
for map regions was left out: the hourly hold removed most of the repeat
cost, and the lattice changes what a pan shows. Revisit if the day count
climbs.

Small. A day's protection for the app that exists today, in case phase 1
slips.

- The Open-Meteo limiter counts weighted calls (35 for a grid, 7.2 for a
  column, 1.9 for a forecast) against a daily budget of 9,000. Past the
  budget, grids and columns serve their last good copy.
- The radar wind grid is held until the next model hour, not 10 minutes.

Done when: a simulated afternoon of panning stays under budget in the
metrics, and the radar test passes.

### Phase 1. The bridge: Open-Meteo's server on Tower

Small. This removes the licensing problem and the call cap in one move,
with no change to Barry's code beyond a URL.

- Run `ghcr.io/open-meteo/open-meteo` on Tower in on-demand mode, pointed
  at their AWS Open Data bucket. It fetches the chunks a query needs and
  keeps them in a local cache. Their docs ask for 8 GB of memory and 100 GB
  of disk for a general deployment; Barry touches three models over the
  US, so start with a 4 GB cache and measure.
- Point the backend's Open-Meteo base URL at it. Same paths, same
  parameters, same JSON. Multi-point grid calls become free, so the
  35-point grid can grow to a few hundred points at once.
- Add the required credit, "Weather data by Open-Meteo.com", to the
  privacy page and the radar key.
- What it doesn't fix: radar (still RainViewer), and the dependency on
  Open-Meteo continuing to publish. The bucket is in AWS's sponsored Open
  Data program on two-year terms. That is why the phases after this one
  still build the NOAA path.

Data: a few hundred MB a day; the format pulls only the chunks a query
touches. Storage: the cache size you set.

Done when: the whole test suite passes against the local server, the app
works with the public API blocked at the firewall, and a day of the storm
alerter's decisions matches the public API's.

### Phase 1a. Aviation guidance from NOMADS

Small, and independent of the bridge decision. The first piece needs no
GRIB library.

GTG and CIP done 2026-09-25: `sources/hazards.py`, read at the point
and sent with every Aloft response as `turbulence` and `icing`; the
Aloft screen draws them on its first stop, and CIP replaces the
column's icing guess there. LAMP done 2026-09-24: `sources/lamp.py`, `sources/nomads.py`, a LAMP loop
in the scheduler, `/combined.lamp`, the TAF card's stand-in at fields
with no TAF, and the route's arrival. The 15 minute runs, the extended
hours and the lightning probability wording are not used yet.

- **LAMP first.** Pull the hourly bulletin at :35 (and the extended one
  for hours 26 to 38), parse the fixed columns into a table keyed by
  station, hold the newest two runs. Serve it inside the payloads that
  already exist rather than as a new screen: the route's arrival at a
  field with no TAF (today "MVFR now"), the TAF card for a field with no
  TAF, and the Fields card's line. LAMP's lightning probability can back
  the thunder wording where the model's CAPE is all there is today.
  About 110 MB a day; 390 MB with the 15 minute runs.
- **Then GTG and CIP, once phase 2 has put eccodes in the image.** Read
  one column at a location from each new file. Aloft gets a turbulence
  layer (EDR by altitude, now only) and CIP replaces the column's own
  icing guess for the current hour; later hours keep the guess, because
  neither product has forecast hours on NOMADS. CIP ships behind a flag
  until it leaves "para". About 2.8 GB a day for GTG at every 15 minutes
  (1.1 GB hourly), 1 GB for CIP.
- `app/sources/nomads.py` holds the mirror: file names from the cycle
  time, a 10 second spacing between its own requests, the same retry and
  failure memory as AWC. The HRRR and NBM fetchers try AWS first and
  NOMADS when a file they expect is more than five minutes late.

Done when: a route to KI69 shows an arrival category from LAMP, the
Aloft screen at KDEN shows today's turbulence and icing, and a day of
fetches in the logs shows no NOMADS error beyond a timeout.

### Phase 2. HRRR grids: map fields and height contours

Medium. The foundation of the NOAA path and the first new feature.

Done 2026-09-25: `grib.py` (index, ranges, eccodes decode, the Lambert
grid, checked against eccodes' own coordinates to 2e-6 degrees),
`modelstore.py`, `sources/hrrr.py` (AWS by range, NOMADS whole files when
the bucket is late), `modelfields.py`, the model loop, `/radar/field` and
`/radar/field/levels` from the store at 88 points, and `/radar/heights`
drawn on the rail. Measured on Tower: 66 fields a cycle in about 5 s,
480 MB a cycle on disk, the container at 516 MB after the pull. Kept
the decode in Python (the heavy parts are eccodes and numpy); the
container's limit went to 3 GB. Not done: HRRR's sea-level pressure as a
second isobar source, and the map fields beyond wind (the fields are
there to add).

- Build the ingest, grid and store described above, pulling from each
  hourly HRRR cycle the analysis and the next two hours (f00 to f02) of:
  10 m wind, gust, boundary layer height, CAPE, CIN, sea-level pressure,
  composite reflectivity, cloud layers, ceiling, visibility, freezing
  level, and height, temperature and wind at 925, 850, 700, 600 and
  500 hPa.
- Serve `/radar/field` and `/radar/field/levels` from the store: a window
  of the grid decimated to the zoom, so the streaks get real density.
- Add `/radar/heights`: contours of geopotential height at the rail's
  level, 30 m apart at 925, 850 and 700 hPa, 60 m at 500 hPa, labelled in
  decameters the way charts do. The map draws them with the isobar
  renderer when the rail is above the surface, and the note says the lines
  are heights at that level.
- Optionally offer HRRR's sea-level pressure analysis as a second isobar
  source. The METAR analysis stays the default; it is observed.

Data: about 34 MB per forecast hour, 100 MB per cycle, 2.4 GB a day.
Storage: under 1 GB.

Done when: the rail at 18,000 ft shows height contours the streaks run
along, the field grid answers in under 50 ms from the store, and the radar
UI test passes with the flag on.

### Phase 3. The Aloft column from HRRR levels

Medium. Sharpens the column and moves it off the bridge.

Done 2026-09-25, differently from the plan below in two ways: 17 levels
(every 25 hPa near the ground, 50 above 800) rather than 15, and stored
at every other point in half precision, which a point's column doesn't
miss and which makes a day-long run 3.5 GB instead of 25. Cloud cover per
level is the larger of a Sundqvist humidity curve (none below 80
percent) and the model's own cloud water and ice. Measured: a day-long
run pulls in about 4 minutes on Tower; a column reads in tens of
milliseconds once its files are open.

- Pull height, temperature, dew point, wind and cloud water at 15 levels
  from 1000 to 400 hPa (every 25 hPa to 900, then every 50) for the hours
  the column shows. Hourly cycles supply f00 to f03; the 6-hourly cycles
  supply f04 to f24.
- `/aloft` reads one column across the hours. Cloud layers come from
  relative humidity and cloud water instead of a cover percentage per
  level, which is closer to what the model knows.
- Freezing level, boundary layer and surface values come from the phase 2
  fields.
- Cheaper variant: read the levels from Open-Meteo's per-hour spatial
  files instead of GRIB, about 0.4 MB per field with a 1 MB reader and all
  39 levels available. It halves the bandwidth at the cost of staying tied
  to their bucket. A reasonable choice if phase 1 has run clean for months.

Data: about 52 MB per forecast hour; about 5 GB a day from the hourly
cycles plus 4 GB from the 6-hourly ones. This was the expensive phase;
with no data cap (2026-09-24) it needs no trimming, and pulling all 40
levels, or the whole pressure file, is fine.

Done when: the Aloft screen renders from the store with the same tests
passing, and the column at KLUK matches the bridge within a degree and a
few knots at the shared levels.

### Phase 4. The home forecast from NBM

Medium. The rain percentage becomes a real probability, and the forecast
moves off the bridge.

Done 2026-09-25, with HRRR as the base for every field and hour (0 to 48
from the four long cycles, 0 to 18 from every cycle) and NBM laid over
temperature, dew point, wind, gust, sky and the hourly rain and thunder
chances for its first 36 hours, rather than HRRR for 0 to 6 and NBM after.
Weather codes are derived only as far as the app reads them (thunder,
showers, rain, cloud). The 180 m temperature for the ride estimate comes
from the column feeds where they reach. Two things the build found: the
forecast pressure needed storing less 1,000 hPa (half precision rounds a
value near 1,024 to the whole hPa), and HRRR's sea-level reduction sits a
hPa or two off a station's, so the curve is shifted to meet the latest
report. Open-Meteo at KLUK had been serving the same HRRR numbers.

- Pull from NBM, every three hours: temperature, dew point, wind, direction,
  gust, sky cover, ceiling, visibility, CAPE, rain probability, thunder
  probability and maximum reflectivity for hours 1 to 24, then every three
  hours to 48.
- Sea-level and surface pressure, boundary layer, CAPE and radiation come
  from HRRR (phase 2 fields, extended to f18 hourly and f48 from the
  6-hourly cycles, at 4 MB an hour).
- Sunrise and sunset are computed locally.
- `/forecast` assembles the hours: HRRR for 0 to 6, NBM after, joined at a
  fixed hour. The short-term forecast logic and the four cards don't
  change; front detection gets a real thunder probability to use.
- Optional: the HRRR sub-hourly file for 15 minute rain and wind in the
  next hour, for the "rain starts at" line.

Data: about 18 MB per NBM hour, 590 MB per pull, 4.7 GB a day at
three-hourly pulls, 2.4 GB at six-hourly. HRRR extension: about 1 GB a
day.

Done when: the forecast cards and alerts pass their tests on NBM data, and
a week of the storm alerter's decisions is logged beside the bridge's with
no new false alarms.

### Phase 5. Radar from MRMS

Medium to large. Replaces RainViewer, which is the one dependency with no
free commercial path at all.

- Pull composite reflectivity every 2 minutes, precipitation type and rain
  rate every 10. Keep two hours at 10 minute spacing plus the latest.
- Render Web Mercator tiles on demand from the uint8 frames. A tile is one
  gather from the grid and a palette lookup, 1 to 2 ms measured; the 1,700
  tiles that cover the country at zoom 8 take about two seconds of one
  core, so pre-render zoom 5 to 8 for each new frame and render deeper
  zooms on request. Native zoom 8; the app's parent-tile scaling covers the
  rest.
- Keep the colours the app has. It requests RainViewer's "Universal Blue"
  scheme at 512 px with the snow variant, and RainViewer publishes the
  dBZ-to-colour table for every scheme as a CSV. The type grid supplies
  snow and hail.
- Tile URLs carry the frame's timestamp and are marked immutable with a
  long max-age, so Cloudflare's edge holds them. The frame index is a
  small uncached JSON. Cloudflare caches PNG by default; the edge TTL
  override minimum on the free plan is two hours, which is why the
  timestamp goes in the URL instead.
- The app's radar overlay switches host and path. The timeline and loop
  code stay.

Data: about 1 GB a day. Storage: 320 MB of frames plus the tile cache.

Done when: the radar loop plays from Barry's tiles on the phone with no
visible difference, and tile requests for a busy region come back from
the Cloudflare cache after the first viewer.

### Phase 6. Nowcast and lightning probability

Small to medium, after phase 5.

- Serve NOAA's lightning probability for the next 30 and 60 minutes under
  the lightning layer as "next hour" shading. It is a 40 KB grid every two
  minutes; no computation.
- Radar nowcast for the next hour: motion from frames ten minutes apart by
  dense optical flow, then advection every two minutes. Measured at about
  a second of CPU for the whole country with OpenCV (a 61 MB wheel). A
  numpy block-matching version on a 4 km grid would avoid the wheel at
  some quality cost. Serve the frames as tiles like the past ones, marked
  as forecast, and feed the rain-start line from the rain rate grid.
- The NLDN ground-strike density grids on the same bucket can back up the
  GOES feed for cloud-to-ground strikes. GOES stays the source for total
  lightning.

Data: negligible.

Done when: the loop's future frames come from Barry, and a month of
"rain starts at" calls is scored against what the radar then showed.

### Phase 7. RRFS, retirement, and aviation products

Small for the swap, larger for the products.

- Add the RRFS field table on the same grid and run it beside HRRR through
  the winter, comparing the two at the METAR sites the app already tracks.
  Switch when it is at least as good; HRRR has no retirement date yet.
- Remove the bridge container, the RainViewer code path, and their
  attribution lines. Update the privacy page to name NOAA.
- The icing and turbulence grids were verified on NOMADS (section 1) and
  moved to phase 1a.

## 5. Budget

Bandwidth from S3 to Tower, per day, if every phase pulls at the cadence
above:

| Source | GB a day |
|---|---|
| Lightning (today) | 2.5 |
| Phase 1, bridge | under 0.5 |
| Phase 1a, LAMP, GTG, CIP from NOMADS | 2.2 to 4.2 |
| Phase 2, HRRR map fields | 2.4 |
| Phase 3, HRRR column | 7 to 9 |
| Phase 4, NBM plus HRRR extension | 3.4 to 5.7 |
| Phase 5 and 6, MRMS | 1 |
| Total, all phases | 19 to 25 |

That is 580 to 760 GB a month, all inbound. Tower is on gigabit fibre
with no data cap (Jordan, 2026-09-24), so none of this needs trimming,
and whole files are fine wherever they are simpler than byte ranges.

Storage: two cycles of everything is under 15 GB on the NVMe cache, plus
the bridge's cache. Memory: the backend needs about 1.5 GB working set,
the bridge whatever cache it is given. CPU: decoding a cycle's fields is
seconds of work an hour; a new radar frame is about three seconds to
pre-render; a nowcast is one.

Money: nothing new. AWS Open Data egress is free, the NOAA buckets need no
account, and the data is public domain. Open-Meteo's bucket is CC BY 4.0
with a credit line. The fixed costs stay the Apple fee and the domain.

## 6. Decisions to make

- **Bridge first, or straight to NOAA.** The bridge is an afternoon and
  buys time. Skipping it means the free-tier exposure lasts until phase 4.
- **The data cap.** Settled 2026-09-24: none. Gigabit fibre, no limit.
- **Radar as pictures.** Cloudflare's free CDN terms allow web content and
  reserve the right to limit an origin serving "a disproportionate
  percentage of pictures". Small map tiles for an app are not what that
  clause was written for, but it is a judgement. The fallback is to send
  radar as vector bands (contours at 5 dBZ steps) instead of images, which
  the map would draw like isobars. Decide before phase 5.
- **Attribution during the bridge.** "Weather data by Open-Meteo.com" on
  the privacy page and the key, for as long as phase 1 runs.

## 7. Risks

- **Late or missing cycles.** NOAA's cloud feed lags NOMADS by minutes and
  occasionally skips hours; the RRFS parallel feed had gaps in September.
  The store always holds the previous cycle, and every route serves it
  with the `stale` flag the app already shows.
- **RRFS transition.** Keep HRRR as the primary until RRFS has run clean
  for a season.
- **Data caps.** None on Tower's line (2026-09-24).
- **NOMADS blocking a client.** It can block an address that fetches too
  fast. Barry's pull is under ten files every 15 minutes, spaced, with a
  named User-Agent; LAMP, GTG and CIP have no other home, so a block would
  leave the last run showing as stale until it lifts.
- **CIP is a parallel product.** It can change format or stop without
  the notice a production product gets.
- **One server.** Same as today; the backend already lives on Tower. Phase
  5 raises the stakes because tiles are traffic, so the Cloudflare cache
  matters. If the tunnel is down the app shows the last frames it holds.
- **Tile bandwidth.** Radar tiles to phones scale with users. The edge
  cache absorbs repeat views; the origin serves each tile once per frame
  per region.
- **Model bias in the copy.** Section 2 lists what the models get wrong.
  The copy rules stay: rounded numbers, calm wording, no promises about
  gust tops or the evening boundary layer collapse.
- **Open-Meteo's bucket.** Only the bridge and the phase 3 variant depend
  on it. The NOAA path does not.

## 8. Sources

Buckets, product pages and tools:

- HRRR on AWS: https://registry.opendata.aws/noaa-hrrr-pds/ and the NCO
  product list https://www.nco.ncep.noaa.gov/pmb/products/hrrr/
- NBM on AWS: https://registry.opendata.aws/noaa-nbm/ ; elements
  https://vlab.noaa.gov/web/mdl/nbm-weather-elements ; v5.0 note
  https://vlab.noaa.gov/web/mdl/-/national-blend-of-models-nbm-upgraded-to-version-5.0-1
- GFS on AWS: https://registry.opendata.aws/noaa-gfs-bdp-pds/
- MRMS on AWS: https://registry.opendata.aws/noaa-mrms-pds/ ; product
  table and precipitation type codes
  https://github.com/NOAA-National-Severe-Storms-Laboratory/mrms-support
- RRFS: https://registry.opendata.aws/noaa-rrfs-ops/ and SCN 26-48
  https://www.weather.gov/media/notification/pdf_2026/scn26-048_Updated_RRFS_and_REFS_Implementation_aad.pdf
- NOMADS: https://nomads.ncep.noaa.gov/ ; grib filter help and fetch
  spacing https://nomads.ncep.noaa.gov/info.php?page=gribfilter ; LAMP
  https://vlab.noaa.gov/web/mdl/lamp ; terms https://www.weather.gov/disclaimer
- Byte-range downloads:
  https://www.cpc.ncep.noaa.gov/products/wesley/fast_downloading_grib.html
- Herbie: https://github.com/blaylockbk/Herbie
- eccodes Python: https://github.com/ecmwf/eccodes-python ; contourpy:
  https://contourpy.readthedocs.io/
- Open-Meteo open data and self-hosting:
  https://github.com/open-meteo/open-data ;
  https://github.com/open-meteo/open-meteo/blob/main/docs/getting-started.md ;
  licence https://open-meteo.com/en/licence
- RainViewer colour tables:
  https://www.rainviewer.com/files/rainviewer_api_colors_table.csv
- Cloudflare CDN terms and cache behaviour:
  https://www.cloudflare.com/service-specific-terms-application-services/ ;
  https://developers.cloudflare.com/cache/concepts/default-cache-behavior/

Papers:

- Dowell et al. 2022, The HRRR, Part I: Motivation and System Description.
  Wea. Forecasting 37, 1371. https://repository.library.noaa.gov/view/noaa/53029
- James et al. 2022, The HRRR, Part II: Forecast Performance. Wea.
  Forecasting 37, 1397. https://repository.library.noaa.gov/view/noaa/53529
- Fovell and Gallagher 2020, Boundary Layer and Surface Verification of the
  HRRR, Version 3. Wea. Forecasting 35, 2255.
- Fovell and Capps 2024, Sustained Wind Forecasts from the HRRR. Atmosphere
  16, 16.
- Bianco et al. 2021, PBL heights in the Columbia River Gorge during WFIP2.
  Bound.-Layer Meteor. 182, 147. https://www.osti.gov/pages/biblio/1840974
- Hamill et al. 2017, The U.S. National Blend of Models for Statistical
  Postprocessing of PoP and QPF. Mon. Wea. Rev. 145, 3441.
- Craven et al. 2020, National Blend of Models: A Statistically
  Post-Processed Multi-Model Ensemble. J. Operational Meteor. 8, 1.
- Zhang et al. 2016, MRMS Quantitative Precipitation Estimation: Initial
  Operating Capabilities. Bull. Amer. Meteor. Soc. 97, 621.
  https://repository.library.noaa.gov/view/noaa/15285
- Smith et al. 2016, MRMS Severe Weather and Aviation Products: Initial
  Operating Capabilities. Bull. Amer. Meteor. Soc. 97, 1617.
  https://repository.library.noaa.gov/view/noaa/32168
- Pulkkinen et al. 2019, Pysteps: an open-source Python library for
  probabilistic precipitation nowcasting. Geosci. Model Dev. 12, 4185.
  https://gmd.copernicus.org/articles/12/4185/2019/
- Ayzel et al. 2019, Optical flow models as an open benchmark for
  radar-based precipitation nowcasting. Geosci. Model Dev. 12, 1387.
  https://gmd.copernicus.org/articles/12/1387/2019/
- Hwang et al. 2015, Improved Nowcasts by Blending Extrapolation and Model
  Forecasts. Wea. Forecasting 30, 1201.
  https://repository.library.noaa.gov/view/noaa/32133
