# Efficiency ledger

Before/after for each roadmap item, measured on the day it shipped.
"Upstream" = calls Barry makes to third parties; "client" = what the phone
does. Times are single measurements (curl, Mac on home Wi-Fi; "live" is
through the Cloudflare tunnel), so treat them as order-of-magnitude.

| Item | Path | Before | After | Data / calls |
|------|------|--------|-------|--------------|
| A1 (2026-09-15) | Radar wind + boundary-layer grids | 2 direct Open-Meteo calls from every phone per map pan (multi-point each); nothing shared | `/radar/field`: 1 backend call, 2.8 KB; 0.2 s cold / 1.5 ms warm local; 0.26 s / 0.06 s live | Upstream: 1 Open-Meteo call per region cell (0.05° center, 0.5° span) per 10 min, shared by all users. Client: 1 call for both layers instead of 2. |
| A2 (2026-09-15) | Radar frame list | 1 direct RainViewer call per phone per radar open: 0.39 s, 818 B today (1 to 2 KB when nowcast + satellite are populated); app trimmed 13 frames to 10 | `/radar/frames`: 571 B (already trimmed, no satellite block); 0.39 s cold / 0.8 ms warm local; 0.41 s / 0.07 s live | Upstream: 1 RainViewer call per 2 min total, regardless of users. Client: same 1 call, 30% smaller, no client-side parsing of RainViewer's shape. |
| A3 (2026-09-15) | Nearest reporting station | 1 to 2 AWC bbox queries (3 h of reports, ±1.4° then ±4°) per new 0.2° cell: 0.90 s cold / 0.15 s warm live | In-memory scan of the bulk table (box pre-filter, haversine on survivors): 0.8 ms per search over 5,162 stations; 2 to 7 ms end to end local; 0.14 s live (network-bound) | Upstream: zero per request (rides the 5 min bulk pull). Also fixed the semantics: only pressure-reporting stations, fresh (≤3 h) preferred over a closer stale one; works worldwide (Anchorage, London verified). |
| C1/C2 (2026-09-15) | `/combined` explanation + per-report fields | 12.4 KB (series carried pressure only) | 15.6 KB, 0.10 s live: +3.2 KB for wind/gust/temp/dew/vis/ceiling/category on 23 series points; the explanation block itself is ~0.3 KB | Upstream: none (fields were already in AWC's response and discarded). Enables the category strip, observed signals, and the runway outlook without any new fetch. |
| A4 (2026-09-15) | Front watch ring | 1 AWC bbox query (8 h of reports, ±1.4°) per station per 15 min, ~0.9 s upstream | Ring series assembled from the server's 9.5 h bulk-snapshot history (persisted to ./state, ~6 MB pickled); bbox only during a 7.5 h cold start after a wipe | Upstream: zero per station once warm. The validated delta/ring/track math is unchanged. |
| D3 (2026-09-15) | TAF | not fetched | `/combined.taf`: 1 AWC TAF call per station per 30 min (~1.5 KB decoded) | New upstream, deliberately per active station only (not bulk): TAFs matter for the home field, not the map. |
| C5/D6 (2026-09-15) | Track record | none | `/combined.trackRecord` (~40 B); log persisted in ./state (a few KB per station) | Upstream: none. Scores use the 24 h series already fetched. |
| Pressure map (2026-09-16) | Isobars, isallobars, shaded fields | not available | `/radar/pressure`: ~13 KB per region (lines + two 41×41 grids); 20 ms to contour 65 stations locally; cached per quantized region for the bulk table's lifetime | Upstream: none. Isobars every 4 hPa (2 on flat days); 3 h change from the server's own snapshot history. |

Notes
- A1 quantization: three slightly different regions from one iPad session
  (spans 2.90, 3.20, 3.38) collapsed to one upstream call after snapping
  spans to 0.5°.
- RainViewer's list carried 0 nowcast frames on 2026-09-15 and hashed
  paths (`/v2/radar/573709f67d5b`); the app handles both.
