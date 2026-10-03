# Barry to the App Store

Written 2026-10-03 at Jordan's ask: what it takes to go from TestFlight
(build 94, the Pilots group) to the App Store, where to host the server,
Tower kept as the fallback and for development, a support address, and a
small site on turpentine.cc. Builds on `PRODUCTION.md` (the hardening,
done) and `APPSTORE.md` (the privacy labels).

## 1. Hosting

What the server needs, measured on Tower today: 1.3 GB of memory steady
(the container is capped at 3 GB; the continental pressure grids are the
bursts), next to no CPU between pulls (0.04 % idle, a few tenths of a
second to find rain motion or render a tile), about 9 GB of state on disk
(MRMS frames, HRRR cycles with the new six-hour history, the model stores,
diagnostics) and 7 to 9 GB a day pulled from NOAA's buckets on AWS
us-east-1. Traffic to phones goes through Cloudflare's cache (tiles,
stacks, the series), so the origin sees little of it.

| | Hetzner CPX31, Ashburn | Fly.io, shared-cpu-2x 4 GB + 40 GB volume |
|---|---|---|
| Month | about €16 ($17) | about $30 (machine, volume, egress) |
| Fit | 4 vCPU, 8 GB, 160 GB NVMe, 20 TB traffic; next door to NOAA's buckets, so the pulls are fast | enough, with a dedicated-CPU step up if the grids ever contend |
| Deploy | the same Docker Compose and `deploy.sh` as Tower, over SSH | `fly deploy`, as Tando |
| Watch for | a VPS is yours to patch and back up | a volume is one host; the always-on numpy worker fits a VPS better |

**Recommendation: Hetzner CPX31 in Ashburn.** Half the price, the same
deploy as Tower, and the NOAA pulls stay on the US east coast. Fly is the
fallback choice if the convenience is worth the difference.

Tower stays as it is: the fallback origin and the place to develop.

What changes to make that real:

- **DNS and the edge.** `api.turpentine.cc` (or `barry.turpentine.cc`)
  proxied by Cloudflare to the VPS; `barry.wide-stack.com` stays on Tower
  through its tunnel. Both get the same cache behaviour (the tiles' and
  stacks' `immutable` headers do the work; no rule needed) and the same
  rate rule, which is Jordan's to set on the new hostname.
- **The app knows two hosts.** `AppConfig.backendBaseURL` becomes a
  primary and a fallback; `BarryAPI` tries the fallback when the primary
  times out or answers 5xx, for the interactive requests. Tiles, stacks
  and the series follow whichever server answered the frames request (the
  server names its own public URL in `host`), so a frame and its tiles
  never come from two servers. The histories (wind, stations, lightning,
  the snapshots) are each server's own, so a failover shows what the
  fallback has.
- **State.** The state directory on the VPS's disk. The only state worth
  backing up is small and already written as files (the station snapshots,
  the track log, the nowcast scores, the diagnostics drop box); Tower
  pulls them nightly with rsync. Everything else is re-pulled from NOAA
  within a few hours of a fresh start.
- **Deploy.** The GitHub Actions workflow already builds and scans the
  image; add a deploy job that, on a tag or by hand, SSHes to the VPS and
  runs `deploy.sh`, with Tower deployed the same way after. The runbook
  (`RUNBOOK.md`) gets the second host.
- **Outside checks.** `/healthz?strict=1` from an outside monitor
  (Cloudflare's own health checks, or a free uptime service) for both
  hosts, mailing the support address.

## 2. Before money enters: the data licences

Open-Meteo's free tier and RainViewer's API are non-commercial. They are
fallbacks only today (HRRR, NBM, MRMS and the station table serve every
request when Tower has data), but a paid app, an ad, or a subscription
means they go:

- Remove the Open-Meteo fallbacks for the wind grid, the levels, the Aloft
  column and the forecast, and the RainViewer radar fallback. Off the HRRR
  grid the app then says so instead of filling in: Barry is a CONUS app and
  can be honest about it.
- Fix the credit line now regardless: the key sheet still says "Radar by
  RainViewer from NOAA NEXRAD" and names Open-Meteo. Radar is MRMS from
  NOAA, and has been since 2026-09-25.
- Keep the fallback log (`/fallbacks`) so it is plain nothing reaches them.

If the app stays free, none of this is forced, but the cost rule in the
project notes ("free if it runs for under $100 a year") does not hold once
there is a VPS: $17 a month plus the $99 developer fee is about $300 a
year. The pricing decision comes first, then the licence work follows from
it.

## 3. App Store Connect

- **Name.** "Barry" alone is unlikely to be free on the store; a subtitle
  carries the rest ("Pressure, radar and wind for pilots"). Check the name
  at listing time.
- **Category** Weather. **Age** 4+.
- **Screenshots.** iPhone 6.9" is required; iPad 13" since the app has an
  iPad layout; Apple Watch since there is a watch app. Taken from the
  simulators with real weather on a day that shows the radar off. No
  marketing frames, no captions in quotes.
- **Description, keywords, promotional text.** Jordan's voice, as the
  TestFlight notes: short, plain, nothing that reads as written by a
  machine. Data from NOAA named once.
- **Privacy policy URL and support URL.** On the site (section 5): the
  backend's `/privacy` and `/support` pages move there, or redirect.
- **App Privacy.** The three rows in `APPSTORE.md` (precise location,
  crash data, performance data; not linked, not for tracking). The
  manifests already match.
- **Export compliance.** `ITSAppUsesNonExemptEncryption` is in the
  Info.plist; HTTPS only, so exempt.
- **Review notes.** No account. Any CONUS airport works; KLUK is the
  default. Location is optional. A line that it is for situational
  awareness and not an official briefing, in the app's own calm wording,
  belongs in the listing and once in the app.
- **Release gate.** The Pilots group's build is the candidate; the same
  commit goes to review.

Still open from `PRODUCTION.md` and still Jordan's hands: the Cloudflare
rate rule (now on two hostnames), the outside health check, Xcode Cloud's
Test action on the workflows, and a session on a real phone followed by a
day for MetricKit to report.

## 4. Support

`barry@turpentine.cc`. Where it goes:

- App Store Connect, the support contact, and the support URL's page.
- In the app: Settings gets a "Write to Barry" row that opens Mail with
  the address, the app version and build, the station and the OS filled
  into the body, so a report arrives with what is needed.
- The outside health checks mail it too.

## 5. The site on turpentine.cc

Small, static, in the repo under `site/`, published by Cloudflare Pages
from the repository (the domain is already on Cloudflare; GitHub Pages
would do as well). Pages:

- `/` Turpentine, one screen: who makes this, with Barry as the one thing
  on it for now.
- `/barry` what it is, two or three screenshots, the App Store badge once
  there is one and the TestFlight link until then, the support address.
- `/barry/privacy` the policy, moved from the backend's page word for word.
- `/barry/support` the address, what to put in a report, a short FAQ
  (what the numbers are, where the data comes from, why a station is
  missing).

Plain HTML and one stylesheet, the app's own tone, no framework. The API
host is a separate name (`api.turpentine.cc`) so the site and the server
move independently.

## 6. Order

1. Pricing decision (Jordan). Everything in section 2 follows from it.
2. Hosting: the VPS, Docker and the state directory, DNS, the first
   deploy, Tower's nightly pull of the small state. About a day, half of
   it waiting on DNS and the histories filling.
3. The app's two hosts and the credit line. A few hours; ships in the next
   TestFlight build and gets a week with the Pilots.
4. The site, with privacy and support on it. Half a day.
5. The listing: screenshots, copy, URLs, labels, review notes. A day, most
   of it Jordan's words.
6. The open owner items, then submit from the Pilots' build.

Accounts, payment details and sign-ins along the way (Hetzner, Cloudflare,
App Store Connect's agreements) are Jordan's to do; the rest can be done
from here.
