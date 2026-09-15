# Efficiency ledger

Before/after for each roadmap item, measured on the day it shipped.
"Upstream" = calls Barry makes to third parties; "client" = what the phone
does. Times are single measurements (curl, Mac on home Wi-Fi; "live" is
through the Cloudflare tunnel), so treat them as order-of-magnitude.

| Item | Path | Before | After | Data / calls |
|------|------|--------|-------|--------------|
| A1 (2026-09-15) | Radar wind + boundary-layer grids | 2 direct Open-Meteo calls from every phone per map pan (multi-point each); nothing shared | `/radar/field`: 1 backend call, 2.8 KB; 0.2 s cold / 1.5 ms warm local; 0.26 s / 0.06 s live | Upstream: 1 Open-Meteo call per region cell (0.05° center, 0.5° span) per 10 min, shared by all users. Client: 1 call for both layers instead of 2. |
| A2 (2026-09-15) | Radar frame list | 1 direct RainViewer call per phone per radar open: 0.39 s, 818 B today (1 to 2 KB when nowcast + satellite are populated); app trimmed 13 frames to 10 | `/radar/frames`: 571 B (already trimmed, no satellite block); 0.39 s cold / 0.8 ms warm local; 0.41 s / 0.07 s live | Upstream: 1 RainViewer call per 2 min total, regardless of users. Client: same 1 call, 30% smaller, no client-side parsing of RainViewer's shape. |

Notes
- A1 quantization: three slightly different regions from one iPad session
  (spans 2.90, 3.20, 3.38) collapsed to one upstream call after snapping
  spans to 0.5°.
- RainViewer's list carried 0 nowcast frames on 2026-09-15 and hashed
  paths (`/v2/radar/573709f67d5b`); the app handles both.
