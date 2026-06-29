# Deploying the Barry backend

The app is a single FastAPI process. The **only** operational rule that matters:
run **one instance / one worker**. The TTL cache, the active-station registry, and
the batched aviationweather.gov scheduler are all in-process — a second instance
means a second scheduler hammering the upstream and an inconsistent cache. To scale
out later, move the cache + registry to Redis first (see `app/cache.py`).

Target: serve it at **https://barry.wide-stack.com**.

---

## Option A — Fly.io (recommended: free-ish, custom domain + auto-TLS, one CLI)

```bash
# 1. Install the CLI and sign in
brew install flyctl
fly auth login

# 2. From the backend dir, create the app using the committed fly.toml
cd backend
fly launch --copy-config --no-deploy
#   - keep the app name "barry-backend" (or pick one; update fly.toml `app =`)
#   - choose a region; decline Postgres/Redis/anything it offers

# 3. Ship it
fly deploy

# 4. Sanity check the public URL Fly assigned
curl https://barry-backend.fly.dev/healthz

# 5. Attach your domain — Fly provisions the TLS cert automatically
fly certs add barry.wide-stack.com
fly ips list          # note the v4 (e.g. 66.x.x.x) and v6 addresses
```

Then add these DNS records in your **wide-stack.com** DNS panel:

| Type  | Name  | Value                         |
|-------|-------|-------------------------------|
| A     | barry | <the IPv4 from `fly ips list`> |
| AAAA  | barry | <the IPv6 from `fly ips list`> |

Watch the cert go green:

```bash
fly certs show barry.wide-stack.com   # waits for DNS + issues Let's Encrypt cert
curl https://barry.wide-stack.com/healthz
```

> Tip: `fly ips allocate-v4 --shared` gives a free shared IPv4 if you don't have one.

---

## Option B — Render (also Dockerfile-based, web UI)

1. Push this repo to GitHub.
2. Render → **New → Web Service** → point at the repo, root dir `backend`,
   environment **Docker** (it'll use the `Dockerfile`).
3. Instance type: the smallest is fine. **Set instance count to 1.**
4. After it's live, Settings → **Custom Domains** → add `barry.wide-stack.com`,
   then add the CNAME record Render shows you to your DNS. TLS is automatic.

---

## Option C — Any VPS (full control)

```bash
# on the box, with Docker installed:
docker build -t barry-backend ./backend
docker run -d --restart unless-stopped -p 8080:8080 --name barry barry-backend
```

Put a TLS-terminating reverse proxy in front. Caddy is the least fuss — this
Caddyfile gets you auto-HTTPS for the domain:

```
barry.wide-stack.com {
    reverse_proxy localhost:8080
}
```

Point an A record for `barry` at the VPS IP and Caddy fetches the cert on first hit.

---

## After it's deployed

1. In `ios/Barry/iOSApp/Info.plist` and `ios/Barry/WatchApp/Info.plist`, set
   `BarryBackendURL` to `https://barry.wide-stack.com`.
2. Remove the `NSAppTransportSecurity` / `NSAllowsLocalNetworking` block from both
   (it's only needed for plaintext-HTTP local dev).
3. Re-run `cd ios && xcodegen generate`, rebuild, and the apps now talk to prod.

## Updating later

```bash
cd backend && fly deploy      # Fly
# or: git push  -> Render auto-deploys
# or: docker build + docker run again on the VPS
```
