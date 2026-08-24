# RESEARCH: Diun — Docker Image Update Notifier for the Media Stack

**Date:** 2026-07-19
**Status:** IMPLEMENTED 2026-08-24 — with deliberate deviations from this doc (see below)
**Target host:** util.michaelpmcd.com (not media — user decision)

> **Implementation note (2026-08-24):** Diun runs on **util** as a fleet-wide
> `type: infrastructure` service rendered by the McHomeLab `service` role
> (templates `diun.yml.j2` + `diun-watch.yml.j2`). It uses the **file provider**,
> not the docker provider: the watch list is derived from every
> `services.*.image` in hosts.yml plus in-use infra images — no docker sockets,
> no per-host agents, inventory stays the single source of truth. Notifier is a
> **webhook** to `http://ha.michaelpmcd.com:8123/api/webhook/claude_diun_updates`
> (user choice over MQTT). `diun notif test` delivered successfully. Remaining
> follow-up: create the HA webhook-trigger automation (claude_ prefix) for that
> ID. §2–§6 below reflect the original media-local docker-provider design; the
> label semantics in §3.2 still apply if/when images get pinned (needs a generic
> `labels:` passthrough in docker-compose.yml.j2, not yet built). The
> qbit-manage drift (QBT_WEB_SERVER) was synced to inventory on 2026-08-24.
**Written for:** a future Claude session implementing this. Follow the user's standing directives: confirm before every destructive/restart step, evidence-driven changes only, no unverified commands.

---

## 1. Why (incident context)

On 2026-07-18 a routine stack restart pulled `ghcr.io/stuffanthings/qbit_manage:latest` → v4.7.0, whose new web UI bound 0.0.0.0:8080 inside the shared gluetun network namespace before qBittorrent could. qBt's API was dead for ~45 hours; cross-seed restart-looped 533 times. Nobody was notified that an image had changed.

Decision from that session:
- **Pin the four gluetun-netns images** (qbittorrent, qbit-manage, cross-seed, gluetun) to explicit version tags.
- **Deploy Diun** so new tags/digests produce a notification instead of a silent behavior change. The user explicitly does not want mandatory manual update checking — Diun watches registries and pings; the user updates on their own schedule.

## 2. What Diun is

[Diun](https://crazymax.dev/diun/) (crazy-max/diun, MIT) watches container image registries and sends a notification when a watched tag gets a new digest or a new tag appears. It does **not** update or restart anything (unlike Watchtower's default mode) — notify-only by design, which is exactly the desired posture.

- Latest release at research time: **v4.33.0 (2026-05-30)**. Image: `crazymax/diun` (Docker Hub) or `ghcr.io/crazy-max/diun`.
- Providers: docker (via socket), kubernetes, swarm, nomad, containerd, file, dockerfile. We use **docker**.
- Notifiers: 15+, including MQTT, webhook, mail, telegram, discord, gotify, ntfy, slack.
- State: small BoltDB in `/data` — persist it or every restart re-notifies everything.

Per the user's dep-adoption policy, do a quick source/repo sanity check before install (single well-known maintainer crazy-max, huge user base; runtime makes registry calls + your configured notif endpoint only). Pin the Diun image itself too — do not run the notifier on `:latest` while preaching pinning.

## 3. Recommended design

### 3.1 Placement
- Add a `diun` service to the existing compose project at `/opt/docker/compose/docker-compose.yml`.
- **Normal bridge network, NOT `network_mode: service:gluetun`.** Diun needs direct registry egress; there is no reason to tunnel it, and keeping it out of the shared netns avoids exactly the port-collision class of failure that motivated this work. (Registry checks from the home IP are anonymous pulls of manifests only — negligible.)
- Mount the docker socket read-only: `/var/run/docker.sock:/var/run/docker.sock:ro`.
- Persist state: `/opt/containers/diun:/data` (matches the stack's `/opt/containers/<svc>` convention).

### 3.2 Watch policy
Set `DIUN_PROVIDERS_DOCKER_WATCHBYDEFAULT=true` so every container on the host is watched without labeling all 12+ services. Default is `false`/label-opt-in; opt-out-by-default fits this stack better because *everything* currently rides `:latest` and coverage gaps are the failure mode. To exclude a container later, label it `diun.enable=false` (with watchByDefault=true, the label works as opt-out — verify behavior on first run by checking `diun image list`).

Key labels available per-container if needed later (documented at crazymax.dev/diun/providers/docker/): `diun.watch_repo`, `diun.include_tags`/`diun.exclude_tags` (regex), `diun.max_tags`, `diun.notify_on` (default `new;update`), `diun.metadata.*`.

Note on semantics: for a container running `foo:latest`, Diun notifies when the `latest` **digest** changes. For a pinned container (`foo:5.1.3`), add `diun.watch_repo=true` + a sane `diun.include_tags` regex (e.g. `^\d+\.\d+\.\d+$`) + `diun.max_tags` (e.g. 10) so you hear about **new version tags**, not just digest churn on the pinned tag. This is the config that makes "pin + get told when to bump" work. Apply it at minimum to the four pinned gluetun-netns services.

### 3.3 Schedule
```
DIUN_WATCH_SCHEDULE=0 */6 * * *   # every 6h, cron format
DIUN_WATCH_JITTER=30s             # default
DIUN_WATCH_WORKERS=10             # default
```
Defaults worth knowing: `runOnStartup=true`, `firstCheckNotif=false` (first scan seeds the DB silently — no flood on day one), `compareDigest=true`.

### 3.4 Notification channel — decide with the user
**Primary recommendation: MQTT → Home Assistant.** The homelab runs a ~57-device Tasmota fleet, so an MQTT broker already exists (verify host/creds — check HA's MQTT integration config or `~/workspace/tasmota_mgr/` on the laptop; do not assume). Diun publishes one JSON message per event:

```yaml
notif:
  mqtt:
    scheme: mqtt
    host: <broker-host>
    port: 1883
    username: <user>       # or DIUN_NOTIF_MQTT_USERNAMEFILE
    password: <pass>       # or DIUN_NOTIF_MQTT_PASSWORDFILE
    client: diun
    topic: docker/diun
    qos: 0
```
Payload fields: `diun_version, hostname, status (new|update), provider, image, hub_link, mime_type, digest, created, platform`.

HA side: an MQTT-trigger automation on `docker/diun` → persistent notification + mobile notify. Per HA directives: automation gets `claude_` prefix and `[claude]` alias suffix, non-destructive.

**Fallbacks if MQTT is unappealing:** `notif.webhook` (POST to an HA webhook trigger URL — simplest, no broker creds in compose), or mail. All env-configurable (`DIUN_NOTIF_WEBHOOK_ENDPOINT`, etc.).

Env vars can replace the YAML file entirely (`DIUN_NOTIF_MQTT_HOST=…`); the stack is env-var-styled, so prefer env-only and skip `diun.yml` unless regex label lists get unwieldy.

## 4. Compose snippet (adapt, then confirm with user before `up -d`)

```yaml
  diun:
    image: crazymax/diun:4.33.0
    restart: unless-stopped
    command: serve
    volumes:
      - "/opt/containers/diun:/data"
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
    environment:
      TZ: "America/Chicago"
      LOG_LEVEL: "info"
      DIUN_WATCH_SCHEDULE: "0 */6 * * *"
      DIUN_PROVIDERS_DOCKER: "true"
      DIUN_PROVIDERS_DOCKER_WATCHBYDEFAULT: "true"
      # + DIUN_NOTIF_* for the chosen channel (see §3.4)
    labels:
      - "traefik.enable=false"
      - "diun.enable=false"        # don't notify about diun itself (it's pinned)
    healthcheck:
      test: ["CMD", "diun", "healthcheck"]
      interval: 60s
      timeout: 10s
      retries: 3
```
`diun healthcheck` is a real subcommand (exit 0 when healthy) — added around v4.33.0; if the healthcheck fails oddly, verify with `docker exec <ctr> diun --help`.

## 5. Implementation checklist

1. Read the user's memory/directives first. Confirm notification channel choice (§3.4) with the user before writing anything.
2. **Companion step — pin the gluetun-netns images** (may already be done; check): read running versions via `docker inspect <ctr> --format '{{.Config.Image}}'` + app-reported versions, edit compose tags for qbittorrent / qbit-manage / cross-seed / gluetun. Back up compose file first (pattern: `docker-compose.yml.bak-YYYY-MM-DD`; a backup from 2026-07-19 already exists). Compose file is root-owned — needs sudo.
3. Create `/opt/containers/diun` (owner consistent with stack conventions, PUID 1028 / GID 100 used elsewhere; diun runs as root by default in-container — fine).
4. Add the service block; add `diun.watch_repo=true` + `include_tags` + `max_tags` labels to the four pinned services (§3.2).
5. `sudo docker compose up -d diun` (confirm with user first — this is the only new-container start; nothing else restarts). Adding labels to other services requires recreating them — batch that with the pinning edit and get explicit confirmation, since it bounces qBt et al.
6. Verify:
   - `docker logs diun` — first scan seeds DB, no notifications (firstCheckNotif=false).
   - `docker exec <diun-ctr> diun image list` — should show all stack images.
   - `docker exec <diun-ctr> diun notif test` — sends a test message through the configured channel; confirm it lands in HA/phone.
7. Wire the HA automation for the MQTT/webhook payload (claude_ naming convention).

## 6. Rollback

```
sudo docker compose rm -sf diun        # stop+remove container
# delete the diun: block from docker-compose.yml (backup exists)
sudo rm -rf /opt/containers/diun       # state DB — confirm with user first
# remove any diun.* labels added to other services (requires their recreation)
# disable/remove the HA automation
```

## 7. Sources

- Diun docs: https://crazymax.dev/diun/ (overview), /providers/docker/ (provider + labels), /notif/mqtt/ (MQTT keys + payload), /config/watch/ (watch defaults), /usage/command-line/ (CLI: serve, healthcheck, image list/inspect, notif test)
- Releases: https://github.com/crazy-max/diun/releases (v4.33.0, 2026-05-30)
- Incident that motivated this: session 2026-07-19, qbit-manage v4.7.0 port-8080 collision on media.michaelpmcd.com (fix: `QBT_WEB_SERVER: "false"`, backup `docker-compose.yml.bak-2026-07-19`)
