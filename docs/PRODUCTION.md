# Barry as a production app

Written 2026-09-21 after an independent review of everything unshipped since
TestFlight build 86 (iOS) and of the whole backend. This is the plan for
getting from "works on the developer's phone and one home server" to
something that holds up with strangers using it and strangers poking at it.

Three sections: what the review found and what was done about it, then the
plan itself in three tracks (security, robustness, production build-out),
then the order to do it in.

## 1. Review of the unshipped work

Two reviewers, each given the code and nothing else, one for the iOS diff
since build 86 and one for the backend. Findings below with what happened.

### Fixed on the day (commits 3646c49 and the iOS commit that follows it)

Backend

- Continental pressure grids ran the contour build inline on the single
  worker: 4 to 9 seconds during which nothing else was served, and the
  zoom-out fix earlier in the day made that reachable by any user. The build
  now runs in a thread with one build per cache key at a time. Measured:
  health check answers in 60 ms while a grid builds; two identical concurrent
  requests share one build.
- Station and lightning box sizes are snapped to half a degree. The client
  derives them from the map span, so every pan minted a fresh megabyte cache
  entry with no bound on how many.

iOS

- Radar tile parking during a pan was undone by the playback ticker within
  one frame step, so it only ever worked while paused. It now holds.
- The prefetch ring past the native zoom fired up to 48 requests for the
  same one to four ancestor tiles. The ring is now computed at the native
  zoom, and the tile fetch dedupes requests in flight, which also fixes a
  pre-existing case where MapKit asked for four children of one ancestor at
  once and got four downloads.
- Prefetch could repaint a tile on the main thread on a cache hit. It no
  longer does, and skips tiles already painted.
- One Metal vertex buffer was rewritten while the GPU could still be reading
  it, which tears a frame when the GPU falls behind a tick. Now three buffers
  in rotation behind a semaphore.
- Scrolling the dashboard card off screen and back overrode the user's own
  pause or play. Visibility now gates the frame ticker directly and never
  touches the user's choice.
- Turning a pressure layer off, panning far, and turning it back on drew the
  stale field. The toggles now refetch through the locality guard.
- Non-finite map geometry could reach an integer conversion in the prefetch
  math and trap. Guarded.
- An emptied wind grid left the last streaks frozen on the map. It clears.

### Found, not fixed, ranked (these are the plan's first jobs)

Backend, critical

- Upstream fan-out scales with client input, which is the one rule the
  project has. Station ids are unvalidated strings and each unique one costs
  an aviationweather.gov call plus a retry plus a TAF call. `hours` is in the
  cache key, so `hours=1` through `360` is 360 upstream calls for one
  station. Forecast keys quantize at 0.01 degrees, so a sweep of coordinates
  burns the Open-Meteo quota for everyone. AWC's limit is 100 requests a
  minute per IP and the scheduler shares that IP: about 35 hostile requests
  a minute takes observed pressure away from every user.
- Registry poisoning. Any string touches the registry before validation,
  the scheduler then refreshes it every ten minutes for a day, and it is
  persisted across restarts. One long or comma-bearing id also fails the
  whole batch of 49 real stations it lands in.

Backend, high

- Caches have no size cap and no sweep. No memory limit on the container.
- No rate limiting on any layer, and port 8077 is published on the LAN
  beside the tunnel, which bypasses Cloudflare entirely.

Backend, medium

- Outages cascade: no single-flight and no negative caching on the bulk
  METAR table, fronts, HRRR probes or radar frames, so a down upstream is
  re-hit on every request, with 15 to 30 second timeouts each.
- The verdict track log grows one key per unique station string and is
  pickled to disk on every `/combined` call.
- Error bodies embed the upstream URL with its query. `/docs` and
  `/openapi.json` are public. The server header names the framework.
- Full-precision coordinates land in the access log, which the privacy page
  says does not happen.
- The container runs as root and unpickles a bind-mounted directory at
  startup. Dependencies are floors with no lockfile. The tunnel image is
  `:latest`.
- One malformed AWC record fails its whole batch of 50 stations.
- `/healthz` says ok no matter what.
- `test_poll_feeds_the_slice_and_combined` is intermittent: fixed-date sample
  files against a real clock.

iOS, low, left as is

- The dashboard visibility check compares against screen height, which is
  wrong under Stage Manager in a way that fails safe (keeps animating).
- The iPad dashboard column never passes `active`, which is correct because
  it does not scroll.

### Kept on purpose

Every upstream call has a timeout. No SSRF or path surface anywhere: hosts
are constants and client input only ever reaches query parameters. Both
scheduler loops catch everything and never die. Secrets handling is clean.
On iOS, particles anchored to map points, one draw call with correct
premultiplied blending, and every Metal setup failure degrades to no streaks
rather than a crash.

## 2. The plan

### Track A: security

The threat model is simple and worth stating. There is no login and nothing
private to steal. The assets are the upstream quotas, the home server's CPU
and memory, and the home IP's standing with aviationweather.gov. The attacker
is anyone who finds the hostname, and the API is documented at `/docs`. The
iOS client is not trusted either: it ships whatever it is told to send.

A1. Close the fan-out (do first, small)

- Validate station ids with `^[A-Z0-9]{3,4}$` before anything, including
  the registry touch. Reject with 422.
- Drop `hours` from the pressure cache key: always fetch 24 hours, slice.
- Quantize forecast keys to 0.1 degrees at least.
- Cap the registry as an LRU of about 2,000 and touch it only after a
  successful parse.
- A per-upstream token bucket in the service (AWC around 30 a minute,
  Open-Meteo around 100) that fails fast with a 503 rather than calling.
  This is the real guarantee: even a bug cannot exceed it.

A2. Rate limit at the edge and in the app (small)

- One Cloudflare rate-limiting rule on the hostname, around 60 requests a
  minute per IP. This is free and catches the crude case.
- In the app, a token bucket keyed on `CF-Connecting-IP`, honoured only when
  the request arrives from the cloudflared container.
- Bind port 8077 to 127.0.0.1 or remove it. The tunnel does not use it.

A3. Stop leaking (small)

- Constant `detail` strings on 503. Log the exception, do not return it.
- `docs_url=None, redoc_url=None, openapi_url=None` in production.
- `--no-server-header`.
- `--no-access-log`, or a filter that drops the query string. Then make the
  privacy page true again. Add `json-file` rotation limits in compose.

A4. Harden the container (small)

- `USER nobody`. JSON instead of pickle for the registry and track log.
- A lockfile and `pip install --require-hashes`. Pin `cloudflared` to a
  version. `mem_limit` on the backend service.
- `pip-audit` and `trivy` on the image in CI, failing the build on high.

A5. Security testing that stays in the repo

- Property tests over every endpoint with Hypothesis and Schemathesis,
  driven from the OpenAPI schema while it still exists in test builds.
  Asserts: never a 500, never more than N upstream calls per request
  (measured through the existing mock transport), bounded response size.
- Abuse regression tests turned from the findings above: junk station ids,
  the `hours` sweep, the coordinate sweep, unquantized box sizes, a
  comma-bearing id in a batch. Each asserts upstream call count and cache
  entry count, not just status.
- A load test with k6 or locust against a local container at the expensive
  endpoints, asserting p95 latency of `/healthz` stays under 200 ms while
  `/radar/pressure` is hammered at maximum span. Run before each deploy.
- On iOS, nothing to fuzz. Keep App Transport Security at its default, no
  arbitrary loads. Add the privacy manifest. If casual scraping of the API
  becomes a nuisance, a static app token in a header is a cheap deterrent,
  with the honest caveat that it ships in the binary and is not
  authentication.

### Track B: robustness

B1. Backend (medium)

- Single-flight on every cache miss, not only the pressure grid: an
  in-flight future per key in `TTLCache` so a hundred users at the moment a
  TTL expires cause one upstream call.
- Negative caching: a failed upstream is remembered for 30 to 60 seconds so
  an outage is one probe a minute, not one per request.
- Move CSV, JSON and bulletin parsing off the event loop like GLM already is.
- Per-record try/except in the METAR parser so one bad record drops one
  record.
- Bulk table TTL at least the scheduler interval, so the scheduler is the
  only thing that refreshes it.
- A health check that means something: 503 when the bulk table is missing
  for two cycles or the lightning feed is stale beyond ten minutes, plus an
  autoheal container that restarts on unhealthy, since compose does not.
- Cap and sweep every cache. Record the track log only from real station
  readings, prune, and persist from the scheduler once a cycle.
- Inject the clock into the flash store and the poll so that test stops
  flaking, then make the CI treat the suite as required.
- Contract tests through the ASGI app, not only the service: parameter
  bounds, 422s, the `inf` and denormal cases, error body shape.

B2. iOS (medium)

- Cold start from the last saved payload. The widgets already do this; the
  app itself shows an error with no network. Load `CombinedStore` first,
  mark it stale, refresh behind it.
- Request timeouts of 10 to 15 seconds on the API session instead of the
  60 second default, and `waitsForConnectivity` for the silent refreshes.
- MetricKit for hangs, crashes and battery, delivered to the backend at
  `/diagnostics` and stored as files. This is enough at this scale and needs
  no third party. If a third party is wanted later, choose it then.
- Tests where the risk is: a test that the Swift tendency table matches the
  Python one, generated from a shared JSON fixture so they cannot drift; unit
  tests for the TAF timeline, runway math, the radar palette lookup, the
  barometer calibration that already has three; snapshot tests for the
  cards; one XCUITest that opens the radar, toggles every layer, pans and
  zooms, and checks nothing crashed. Xcode Cloud can run these; today it runs
  nothing.
- A privacy manifest, which App Store submission now requires.

B3. The map specifically

- Test on a real phone before the next build. Every number in this
  document is from a debug build in the simulator; the ratios are real, the
  absolutes are not.
- The visibility check should move to `onScrollVisibilityChange` when the
  floor reaches iOS 18, and the deployment floor should follow the
  TestFlight group's devices, not the calendar.

### Track C: production build-out

C1. CI

- GitHub Actions for the backend: pytest, pip-audit, docker build, trivy,
  on every push. Fail the merge on red.
- Xcode Cloud runs the iOS tests on every build, and a failing test fails
  the build. The Metal toolchain must be present in the cloud image; the
  first build after the Metal change is the check.

C2. Observability

- Structured logs with a request id, no query strings, no coordinates.
- Counters worth having: requests by route and status, upstream calls by
  host and outcome, cache hit ratio, scheduler cycle duration, current
  registry size, and memory. Expose them at `/metrics` on the LAN only.
- One external check that the hostname answers, such as healthchecks.io
  pinging `/healthz` every minute, so an outage is noticed before a tester
  says something.

C3. Deployment

- Images tagged by commit. Deploy is pull plus up, rollback is the previous
  tag. Keep the last three.
- The home server is a single point of failure and that is acceptable for
  now. Write down what it means: if the box is off, the app shows its last
  saved reading and says so. Back up `backend/state/` nightly with the rest
  of the box.
- A runbook, one page: AWC is down, Open-Meteo quota is hit, RainViewer
  changes its palette again, the tunnel token expires, the box reboots. Each
  with what the user sees and what to do.

C4. App Store readiness

- Privacy manifest and the privacy nutrition labels, consistent with the
  privacy page after A3.
- Courtesy emails to RainViewer and Iowa Mesonet before public release,
  already drafted.
- Listing copy, screenshots, the support page checked on a phone.
- External TestFlight review has already passed once; keep the Pilots group
  as the release gate.

## 3. Order

Week one, in this order, each small: A1, A2, A3, A4, and the two backend
items from B1 that are one change each (single-flight everywhere, negative
caching). Then a real-phone session on the radar. Then the next TestFlight
build.

Week two: the rest of B1, the iOS cold start and timeouts from B2, the
tendency parity test, MetricKit, the privacy manifest, and CI running tests
on both sides.

After that: the remaining tests, observability, the runbook, and the App
Store items in whatever order the release date dictates.

The thing to hold onto: nothing here is a rewrite. The architecture is
sound and the caching discipline is real. The gaps are the ones a private
tool has when it meets the public internet, and they close one small change
at a time.

## 4. Where it stands (2026-09-22)

Done, deployed and tested, in the order above: A1 to A5, B1, the backend
half of B2 (diagnostics drop box, shared tendency fixture), the iOS half of
B2 (cold start from the saved payload, 12 second interactive timeout and a
patient session for silent refreshes, MetricKit to `/diagnostics`, the
parity test, unit tests for the timeline, runway math, palette and
staleness, card render tests, one radar UI test, privacy manifests in all
four targets), C1 for the backend (GitHub Actions: tests, pip-audit, image
build, trivy), C2 (`/metrics` on the box, JSON logs with a request id), C3
(`deploy.sh` and `rollback.sh` with images tagged by commit, the runbook
in `docs/RUNBOOK.md`), and the manifest half of C4.

Two things the tests found along the way: a remembered upstream failure
answered 500 on the second call in a window, and the TAF timeline began
an hour ahead of the clock. Both fixed.

Left, and all of it needs the owner's hands: the Cloudflare rate rule on
the hostname; an outside check on `/healthz?strict=1`; Xcode Cloud's Test
action turned on for the scheme (the tests are in the scheme already); a
session on a real phone with the radar and a day for MetricKit to send
its first report; the App Store privacy labels (`docs/APPSTORE.md` says
what to enter); the courtesy emails; listing copy and screenshots. Snapshot
images were not adopted for the cards: without a reviewed reference from
a device they would only encode whatever the simulator drew first.
