# Barry runbook

One page for the things that go wrong, what the user sees, and what to do.
Written 2026-09-22. The backend is one container on Tower (Unraid,
192.168.1.140) behind a Cloudflare tunnel at barry.wide-stack.com. State
lives in `backend/state/` next to the compose file.

## How to tell what is wrong

- `curl -s https://barry.wide-stack.com/healthz` answers with a `status`
  of `ok`, `degraded` or `unhealthy` and a `problems` list. Degraded means
  an upstream has gone quiet; the process is fine. Unhealthy means a loop
  inside the process died or stalled, and the autoheal container will
  restart it within about two minutes on its own.
- `?strict=1` turns degraded into a 503 too. That is the form for an
  outside monitor (healthchecks.io or similar pinging once a minute).
- On the box: `curl -s localhost:8077/metrics` for counters: requests by
  route and status, upstream calls by host and the answers that came back,
  cache hit ratio, scheduler cycle time, registry size, memory. It answers
  only on the box; through the tunnel it is a 404.
- `docker logs --since 30m barry-backend` for the app's own warnings, one
  JSON line each with a request id. There is no per-request log.
- Phone diagnostics land in `backend/state/diagnostics/` as gzipped JSON,
  newest 300 kept. `zcat <file> | python3 -m json.tool | less`.

## Deploy and roll back

```bash
cd /mnt/user/appdata/barry/backend && sh deploy.sh
```

builds the image tagged by commit, brings it up, waits for the health
check, and keeps the last three tags. If it comes up unhealthy:

```bash
docker images barry-backend          # the tags kept
sh rollback.sh <previous tag>
```

`state/DEPLOYED` says what is running.

## Scenarios

**aviationweather.gov is down or blocking.** Users see their last reading
with "saved" on the hero line, then a model-derived fallback line if the
outage lasts. The map's stations and pressure layers go stale. Health says
`degraded: bulk metar table missing` after twenty minutes. Nothing to do
but wait; the service probes once a minute, not per request. If it lasts
days, check that the box's IP is not the problem: `curl -sI
https://aviationweather.gov/data/cache/metars.cache.csv.gz` from Tower.

**Open-Meteo quota hit.** Forecast, wind grid and the verdict's forecast
half go missing; observed pressure keeps working. The app's own budget
is 100 calls a minute and forecast keys are a tenth of a degree, so this
means either a bug or a scraper. Read `/metrics` for
`barry_upstream_requests_total{host="api.open-meteo.com"}` and the
request counts by route; the per-address budget (60 a minute) and the
Cloudflare rule are the levers.

**RainViewer changed its palette.** The radar shows the wrong colours or
nothing painted. `RadarPalette.swift` holds the Universal Blue lookup;
compare a fresh tile against it. This needs an app update; the server is
not involved.

**The tunnel token expired or the tunnel is down.** The hostname stops
answering but `curl localhost:8077/healthz` on the box works. Cloudflare
Zero Trust → Networks → Tunnels shows the tunnel state; a new token goes
in `CLOUDFLARE_TUNNEL_TOKEN` in the compose environment, then `docker
compose up -d cloudflared`.

**The box rebooted.** Everything restarts on its own (restart:
unless-stopped, autoheal always). The registry, the bulk history and the
verdict log come back from `state/`; the caches are cold, so the first
minute is slower. Check `/healthz` shows `scheduler_cycles` climbing.

**The box is off.** The app opens on the last saved reading and says
"saved, can't refresh" on the hero line; widgets go grey past two hours.
This is the accepted single point of failure.

**Someone is hammering the API.** `/metrics` shows it by route. The
per-address budget answers 429 after 60 a minute; upstream budgets fail
fast with 503 before any call goes out; the grid builds two at a time.
The Cloudflare rate rule on the hostname is the outer wall (user-owned,
suggested 20 requests per 10 seconds). It must not count `/radar/`: the
radar tiles come from this hostname now, a zoomed-out map asks for a
hundred in a second, and a rule that counts them blanks the radar for ten
seconds at a time (the app's tile counter on `/metrics` stays flat while
it happens, because the 429s never reach the box).

## Backups

`backend/state/` holds the registry, bulk history, verdict log and
diagnostics. It is small and rebuilds itself within a day; back it up
with the rest of appdata on the box's schedule. Nothing else is stateful.
