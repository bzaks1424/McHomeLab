# Research Brief: FlareSolverr for Cloudflare-Challenged Prowlarr Indexers

## Ground Rules

Scratch scripts and test configs are fine in `/tmp/` or a new scratch directory.
Compose and container changes land on the `media.michaelpmcd.com` VM at `/opt/docker/compose/docker-compose.yml`, with persistent state under `/opt/containers/flaresolverr/` following the existing convention.
No changes to unrelated hosts/services.

---

## Current State (2026-04-22)

**Prowlarr** at `prowlarr.media.michaelpmcd.com` proxies torznab queries for `seedpool (API)`, `The Pirate Bay`, `LimeTorrents`, `AnimeTosho`, `EZTV`, `Internet Archive`, and `DrunkenSlug`.

**Problem:** `kickasstorrents.ws` was removed from Prowlarr after auto-disabling on 2026-04-02. Attempting to re-add it via `POST /api/v1/indexer?forceSave=true` returns:

```
"Unable to access kickass.ws, blocked by CloudFlare Protection."
```

Prowlarr's indexer validator makes a live connectivity check at add-time and that check cannot be skipped via API flags. Root cause is a Cloudflare IUAM ("checking your browser") JS challenge page returned to Prowlarr's raw HTTP client instead of the expected torznab feed.

`BitRu`, `kickasstorrents.to`, and `EZTV` are in similar or worse states; the same workaround applies to any of them if they're worth re-adding later.

**Target:** evaluate FlareSolverr as the recommended proxy sidecar for Cloudflare-gated torznab sources, with enough detail to decide whether to adopt it for `kickasstorrents.ws` specifically (a site historically useful but currently unreachable).

---

## What It Is

FlareSolverr is a self-hosted HTTP proxy that fronts Cloudflare- and DDoS-GUARD-protected sites. Callers send a JSON request to `POST /v1`; FlareSolverr spawns a real Chromium browser (Python Selenium driving `undetected-chromedriver`, a patched ChromeDriver fork designed to evade basic bot detection), loads the target URL, waits for the Cloudflare challenge page's JavaScript to resolve, and returns the rendered HTML plus the `cf_clearance` cookies. Callers reuse the returned cookies + User-Agent with a normal HTTP client against the origin directly until the clearance expires.

It is **not** a transparent HTTP proxy. Clients must speak its JSON API.

---

## Current Release

- **Latest:** `v3.4.6`, published **2025-11-29**, tagged by maintainer `ngosang`.
- **Cadence:** ~2–4 weeks between releases through late 2025. Prior: v3.4.5 (2025-11-11), v3.4.4 (2025-11-04), v3.4.3 (2025-10-28), v3.4.2 (2025-10-09), v3.4.1 (2025-09-15), v3.4.0 (2025-08-25).
- **License:** MIT.
- **Repo health:** 13,588 stars. Last `master` push 2026-03-26, last commit on tip 2026-01-12. 46 open issues / 24 open PRs as of April 2026. Actively maintained, but bus factor is effectively one — `ngosang` is the sole reviewer.

---

## How It Works

```
Prowlarr --POST /v1 JSON--> FlareSolverr
                                |
                     spawns headless Chromium
                     (undetected-chromedriver)
                                |
                  loads URL -> hits CF challenge page
                                |
                   JS challenge auto-solves in-browser
                                |
                  cf_clearance cookie issued by Cloudflare
                                |
Prowlarr <--{html, cookies, userAgent}-- FlareSolverr
```

Prowlarr caches the clearance cookie and re-uses it against the origin directly on subsequent requests until it expires, re-calling FlareSolverr only on expiry/failure.

### What it can solve

- Cloudflare **IUAM** ("checking your browser") JS challenges — the primary use case.
- **DDoS-GUARD** challenge pages.
- Cloudflare **Turnstile** — **partially, new in v3.4.x**. PR #1634 merged 2025-12-03, requires caller to pass `tabs_till_verify`. Issue #1678 (2026-02-04) shows it's flaky on retry. Prowlarr does not currently wire `tabs_till_verify` through, so Turnstile coverage is effectively absent from the arr-apps path.

### What it cannot solve

- Cloudflare **Managed Challenge** / interactive CAPTCHAs (hCaptcha, reCAPTCHA). README states explicitly: *"At this time none of the captcha solvers work."*
- **TLS/JA3 fingerprinting** on the origin request. The clearance cookie works for Chromium's fingerprint — not your downstream torrent client's.
- Turnstile embedded in **login forms** (#1598, closed without working fix).

---

## Deployment

**Image:** `ghcr.io/flaresolverr/flaresolverr:latest` (Docker Hub mirror: `flaresolverr/flaresolverr:latest`). Multi-arch: `amd64`, `386`, `arm64`, `arm/v7`.

**Port:** `8191/tcp` (API). `8192/tcp` optional for Prometheus metrics.

**Env vars** (all optional; none required):

| Var | Default | Note |
|---|---|---|
| `LOG_LEVEL` | `info` | `debug` is very chatty |
| `LOG_FILE` | unset | if set, writes to file instead of stdout |
| `LOG_HTML` | `false` | dump fetched HTML to logs (debug) |
| `TZ` | `UTC` | |
| `TEST_URL` | `https://www.google.com` | startup smoke test |
| `CAPTCHA_SOLVER` | `none` | none of them work today |
| `PROXY_URL` / `_USERNAME` / `_PASSWORD` | unset | upstream HTTP proxy, e.g. route FS through a VPN |
| `HEADLESS` | `true` | |
| `DISABLE_MEDIA` | `false` | set `true` to skip images/fonts — faster challenge solves |
| `PROMETHEUS_ENABLED` | `false` | |
| `PROMETHEUS_PORT` | `8192` | |

**Volumes:** upstream's compose mounts `/var/lib/flaresolver:/config` but nothing is actually persisted there by default. Volume is optional. No state needs to survive restarts.

**Resource footprint:**

| State | RAM | CPU |
|---|---|---|
| Idle (no in-flight request) | 70–150 MB RSS | ~0% |
| Solving a challenge (per browser) | +300–500 MB RSS spike | 1 core for 3–10 s wall |

Minimum 512 MB reserved; 1 GB safer if multiple indexer searches fire in parallel. A fresh Chromium is launched per request unless the caller uses the `sessions.create` API — Prowlarr does **not** use sessions.

Historic memory-leak reports exist (#42, #390, "CPU and memory usage of Chromium") — all closed. No open leaks today, but scheduling a nightly container restart is a common preventative. Docker Compose `init: true` is recommended to reap zombie Chromium processes on crash.

**Platform notes:**
- `libseccomp2 ≥ 2.5` required on Debian hosts (old Buster fails to start).
- ARM support is Docker-only (no precompiled native binaries).

---

## Prowlarr Integration

Prowlarr models FlareSolverr as an **Indexer Proxy**, bound to specific indexers via tags. It is **not** a global proxy — Prowlarr only re-issues a request through FlareSolverr after detecting a Cloudflare challenge response on the direct attempt, AND only when the proxy's tags match the indexer's tags.

### Setup (one-time, ~2 min)

1. Prowlarr → **Settings** → **Indexers** → **Indexer Proxies** → **+** → pick **FlareSolverr**.
2. Fields:
   - **Name:** free-text (e.g. `flaresolverr`)
   - **Host:** `http://flaresolverr:8191` (using compose DNS) — **do not** append `/v1`, Prowlarr appends it.
   - **Request Timeout:** `60` (range 1–180 s). Bump to 120 for slow challenges.
   - **Tags:** e.g. `cloudflare` — arbitrary string, used as the binding key.
3. Edit the indexer (e.g. `kickasstorrents.ws`) → add the **same tag** in its Tags field.

### Binding rules (from the Prowlarr FAQ, verbatim)

> *A FlareSolverr Proxy will only be used for requests if and only if Cloudflare is detected by Prowlarr.*
>
> *A FlareSolverr Proxy will only be used for requests if and only if the Proxy and the Indexer have matching tags.*
>
> *A FlareSolverr Proxy configured without any tags or has no indexers with matching tags it will be disabled.*

Tagging is how you scope FlareSolverr to kickass.ws without dragging every other indexer through headless Chromium.

---

## Security & Privacy

- **No phone-home.** On startup FlareSolverr hits `TEST_URL` (default `https://www.google.com`) as a smoke test. Override to any reachable URL. No telemetry beyond that.
- **Fingerprint exposure.** The Chromium instance sends a normal Chrome User-Agent to the target. Cloudflare sees a real browser originating from the FlareSolverr container's network egress. That egress is your WAN IP — your residential IP is now associated with scraping behavior against whatever sites you route. (For this homelab's use case — kickass.ws over a few requests per day — irrelevant.)
- **Cloudflare's position.** Cloudflare publishes no named policy on FlareSolverr. `undetected-chromedriver` is explicitly an anti-bot-evasion library. Cloudflare ships detection updates continuously; FS's patch cadence is the response. Historically every few months a Cloudflare-side update has broken FS entirely for days to weeks before a fix ships.
- **Sidecar exposure.** Default bind is `0.0.0.0:8191` with **no authentication**. Any host that can reach the port can make FS browse arbitrary URLs — an SSRF pivot into internal services and an open scraping proxy using your IP.
  - **Keep it on an internal Docker network.** Do **not** publish `-p 8191:8191` to the VM. Let Prowlarr reach it via compose DNS (`http://flaresolverr:8191`).
  - **Do not** add a Traefik label for external access.
  - If a host-external reach is ever needed (testing, other hosts on the lab network), firewall the port to Prowlarr's IP only.

---

## Known Limitations

- **Captcha solvers don't work.** If Cloudflare escalates kickass.ws to a Managed Challenge with hCaptcha/Turnstile, FS returns `Captcha detected but no automatic solver is configured.` and the indexer fails. There is no workaround inside FS for this class of challenge.
- **Turnstile support is experimental.** PR #1634 merged 2025-12-03 but #1678 (2026-02-04) shows retries don't retrigger the captcha, and Prowlarr doesn't expose the `tabs_till_verify` knob. Treat Turnstile as unsupported in practice.
- **Per-request browser launch is expensive.** Sessions API would amortize this but Prowlarr doesn't use it. This only matters if you're blasting dozens of searches per minute through FS — not this use case.
- **Cloudflare update cycle.** Budget for 2–4 CF-induced outages per year where FS needs a patch; `watchtower`-style auto-pull of `:latest` is reasonable for this container specifically.
- **Bus factor = 1.** `ngosang` is the sole maintainer. If they step away, pinning to the last known-good tag is viable for months but not indefinitely. Byparr exists as a drop-in replacement (same port, same API surface — see alternatives).

---

## Alternatives

| Option | Status | Verdict |
|---|---|---|
| **Byparr** (ThePhaseless) | 1,424 ★, GPL-3.0, last push 2026-04-21. Same `:8191` API — Prowlarr configures it identically. Python + SeleniumBase/nodriver + FastAPI. | Worth keeping as a standby — if FS breaks on a specific site or Cloudflare update, swap the Indexer Proxy Host to Byparr's. Image: `ghcr.io/thephaseless/byparr:latest`. |
| **FlareSolverrSharp** | C# client library used *by* Prowlarr/Jackett internally. | Not a replacement — ignore. |
| **Paid scraping APIs** (ScrapingBee, Scrape.do, ZenRows, Bright Data, ScraperAPI) | Residential proxy pools, continuously updated bypass logic. $0.001–$0.01/request. | Overkill for homelab Prowlarr; documented here for completeness. |
| **VPN + direct requests** | CF's challenge is JS-based, not IP-based. | Does not help; often hurts (flagged exit IPs). |
| **`cloudscraper` / `cfscrape`** | Python libraries, last working against pre-2020 CF. | Do not use. |

---

## Integration Plan

### Stage 1 — add the container

Append to `/opt/docker/compose/docker-compose.yml`, top-level `services:`:

```yaml
  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    restart: unless-stopped
    init: true
    environment:
      LOG_LEVEL: "info"
      TZ: "America/Chicago"
      DISABLE_MEDIA: "true"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8191/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    # No ports: published — internal Docker network only.
    # No volumes — FS is stateless.
    # No Traefik labels — must NOT be reachable from outside the host.
    labels:
      - "traefik.enable=false"
```

Apply:

```bash
cd /opt/docker/compose
docker compose up -d flaresolverr
docker compose logs -f flaresolverr   # watch for "Serving on http://0.0.0.0:8191"
```

### Stage 2 — wire Prowlarr

Prowlarr web UI:
1. Settings → Indexers → Indexer Proxies → **+** → **FlareSolverr**
2. Name: `flaresolverr` · Host: `http://flaresolverr:8191` · Tags: `cloudflare`
3. Test → Save

Add the `cloudflare` tag to the `kickasstorrents.ws` indexer (re-add the indexer first; the add will still fail at connectivity-test time, but `forceSave=true` should now pass since Prowlarr will route the re-test through FS once tagged — verify).

### Stage 3 — verify

Run a manual search in Prowlarr scoped to kickass.ws. Watch the FS logs:
```bash
docker logs -f compose-flaresolverr-1
```
A successful solve shows a `Challenge solved` line with the cf_clearance cookie length and wall-time. A failure (Managed Challenge, Turnstile) shows a specific error — if that's the state kickass.ws is in, FS cannot rescue it and the indexer should stay deleted.

### Stage 4 — ongoing

- Add a cron/systemd-timer restart of the container weekly as a hedge against slow memory leaks:
  ```bash
  docker restart compose-flaresolverr-1
  ```
- Pin the image tag (move off `:latest`) once you hit a known-good version; bump manually after reading release notes. The "always auto-update" behavior is what bites on Cloudflare-update weeks.

### Rollback

```bash
cd /opt/docker/compose
docker compose rm -sf flaresolverr
# Remove the service block from docker-compose.yml, plus the Indexer Proxy in Prowlarr UI.
```

Prowlarr's behavior without the proxy reverts to direct HTTP against kickass.ws — which will 503 again, i.e. same state as today.

---

## Open Questions

1. Does kickass.ws currently sit behind a plain IUAM challenge (FlareSolverr can handle) or has it escalated to Managed Challenge / Turnstile (FlareSolverr cannot)? Verify before committing — a 30-second test against `https://kickass.ws/` using the FS API directly will tell us:
   ```bash
   curl -X POST http://localhost:8191/v1 \
     -H "Content-Type: application/json" \
     -d '{"cmd":"request.get","url":"https://kickass.ws/","maxTimeout":60000}' | jq .status
   ```
   If `ok`, proceed with the integration. If `error`, kickass.ws is escalated and not worth re-adding.

2. Is there value in pre-tagging other potentially-CF-protected indexers (EZTV, BitRu) with `cloudflare`, or are their failure modes something else? EZTV's 100% query-fail rate pattern suggests upstream-dead, not CF — FlareSolverr won't help there. BitRu's 18-month outage likewise.

3. Should FlareSolverr traffic route through the VPN (via Gluetun network namespace, matching qBittorrent) to keep scraping IPs isolated from the homelab WAN? Default answer: **no** — FlareSolverr is low-volume, keeping it on the direct path avoids complicating the CF-update failure mode. Revisit if the scraping-IP association becomes a concern.
