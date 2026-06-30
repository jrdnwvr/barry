# Self-hosting Barry on Unraid → barry.wide-stack.com

Runs the backend as a Docker container on your Unraid server and publishes it at
**https://barry.wide-stack.com** through a **Cloudflare Tunnel** — no router
port-forwarding, no exposed home IP, and HTTPS handled automatically at
Cloudflare's edge.

```
iPhone / Watch ──HTTPS──▶ Cloudflare edge ──tunnel──▶ cloudflared ──▶ barry-backend:8080
                          (barry.wide-stack.com)        (Unraid container)   (Unraid container)
```

## Prerequisites
- wide-stack.com's **DNS managed by Cloudflare** (free plan is enough). If it's
  registered elsewhere, point the domain's nameservers at Cloudflare first.
- Docker on Unraid (built in) + the **Compose Manager** plugin (Community Apps),
  or run the two containers from Docker templates.
- The repo on the server. Easiest is to push this repo to GitHub and `git clone`
  it onto the server (e.g. under `/mnt/user/appdata/barry`); then updates are a
  `git pull`. (You can also just copy the `backend/` folder over.)

## 1. Create the Cloudflare Tunnel
1. Cloudflare dashboard → **Zero Trust → Networks → Tunnels → Create a tunnel**
   (type: *Cloudflared*). Name it e.g. `barry`.
2. Copy the **tunnel token** it shows (a long string) — used below.
3. Under the tunnel's **Public Hostnames → Add a public hostname**:
   - Subdomain: `barry`  · Domain: `wide-stack.com`
   - Service: **HTTP** → `barry-backend:8080`
   Cloudflare auto-creates the `barry` DNS record pointing at the tunnel.

## 2. Run the stack on Unraid
From the `backend/` directory (Compose Manager → add stack, or shell):
```bash
CLOUDFLARE_TUNNEL_TOKEN="<paste the token>" docker compose up -d --build
```
This builds `barry-backend` and starts it alongside `cloudflared`. They share the
compose network, so the tunnel reaches the API as `http://barry-backend:8080`
(which is why the dashboard service is set to exactly that).

> Keep the token out of git — put it in an `.env` file next to the compose file
> (`CLOUDFLARE_TUNNEL_TOKEN=...`) or Unraid's stack env field. `.env` is gitignored.

## 3. Verify
```bash
curl https://barry.wide-stack.com/healthz        # {"status":"ok",...}
curl "https://barry.wide-stack.com/combined?station=KLUK&lat=39.1&lon=-84.5"
```

## 4. Point the apps at it
Set `BarryBackendURL` to `https://barry.wide-stack.com` in both
`ios/Barry/iOSApp/Info.plist` and `ios/Barry/WatchApp/Info.plist`, and drop the
`NSAppTransportSecurity` / `NSAllowsLocalNetworking` block (real HTTPS no longer
needs the local-network exception). Re-run `xcodegen generate` and rebuild.

## Updating later
```bash
git pull
docker compose up -d --build      # rebuilds + restarts the backend
```

## Notes
- **Single instance only.** The cache, station registry, and scheduler are
  in-process — don't scale `barry-backend` to >1 replica without Redis.
- `restart: unless-stopped` keeps it up across reboots; the in-memory cache simply
  repopulates on start.
- The scheduler makes one batched aviationweather.gov call per ~10 min for the
  watched stations — trivial load for a home server, well under the 100/min limit.

## Alternative (no Cloudflare): reverse proxy + port-forward
If you'd rather not use Cloudflare: run the backend container, put **SWAG** or
**Nginx Proxy Manager** in front for Let's Encrypt TLS, forward 443 on your
router, and use a Dynamic DNS record for `barry.wide-stack.com`. More moving parts
(open port, DDNS, cert renewal) — the tunnel avoids all of that.
