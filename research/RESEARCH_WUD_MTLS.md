# RESEARCH: WUD single instance + remote Docker watchers over mTLS

**Date:** 2026-08-24
**Status:** McHomeLab side COMPLETE 2026-08-24 — steps 1–3, 5, 6 executed; step 4 skipped by decision; LSCR closed with a PAT (§6.4). Step 7 (HA Admin card) belongs to the claude workspace. Steps below are small,
each independently verifiable, each its own commit. Check in before every
playbook run and every commit.
**Supersedes:** the per-host WUD topology in
`~/workspace/claude/workspace/container-updates/STRATEGY.md` §6.1 (user
decision 2026-08-24: one instance on util, remote watchers, dockerd on
TCP+mTLS — "option 3"). The tool choice (WUD over Diun) is unchanged.

---

## 0. Facts this plan stands on (all verified live 2026-08-24)

| fact | evidence |
|---|---|
| Docker 29.7.2 on media (12 containers) and unifi (10, of which 9 are Ubiquiti's `unms` compose project); no `daemon.json`, no systemd drop-in, **`live-restore=false`** | `docker info`, `systemctl cat docker` |
| dockerd unit uses `ExecStart=… -H fd://` | same |
| `dockerd --tlsverify --tlscacert --tlscert --tlskey -H tcp://…` are real flags | `dockerd --help` |
| WUD watcher supports `HOST/PORT/CAFILE/CERTFILE/KEYFILE` per named watcher; `SOCKET` is the local alternative; `WATCHBYDEFAULT` is per watcher | upstream `docs/configuration/watchers/README.md` |
| `step` CLI 0.28.2 on the controller; step-ca provisioners: `ansible` (JWK, max cert 43800h = 5y, renewal enabled), `acme` (90-day) | `step version`, util `ca.json` |
| Existing `roles/step-ca-cert` issues via the `ansible` JWK provisioner with `needs-renewal` gating (threshold 168h); outputs to `{{ export_root }}/<host>/cert.pem|key.pem` | role source |
| `community.crypto` 3.0.5 is installed (dedicated-CA option viable) | `ansible-galaxy collection list` |
| util → `ha:1883` open; util → `media:2376` closed (nothing listens yet) | `/dev/tcp` probes |
| media = 192.168.255.34, unifi = 192.168.255.35 (DMZ /29); util = 192.168.254.3 (MGMT) | inventory + `hostname -I` |

**ACME is not usable for this** and the plan does not pretend otherwise:
dockerd cannot speak ACME; an external ACME client would need port 80/443 or
DNS-01 on media/unifi — traefik owns 80/443 and there is no DNS-01 provider.
Rotation is therefore Ansible-driven (§5).

---

## 1. Target topology

```
controller (ansible)                      util                      media / unifi
  issues + renews certs ───────────▶  wud (one instance)  ──TLS──▶  dockerd :2376 (mTLS)
  ships them by copy                 ├ watcher "local"  → /var/run/docker.sock
                                     ├ watcher "media"  → media:2376  (client cert)
                                     └ watcher "unifi"  → unifi:2376  (client cert, opt-in only)
                                      └── MQTT → HA (one device "WUD", per-watcher sensors)
```

- One WUD UI at `https://wud.util.michaelpmcd.com` showing all three watchers.
- Notify-only is unchanged: no `WUD_TRIGGER_DOCKER_*` anywhere.
- Side benefit: the controller gets `docker context` entries for media/unifi
  with the same client cert — remote `docker ps`/`logs` without SSH.

## 2. Decisions (taken 2026-08-24, stepped through one by one)

**D1 — Trust anchor for dockerd: A, step-ca root (user decision; B was recommended).**
Accepted risk, recorded here so it is never rediscovered as a surprise: with
`--tlsverify` against the lab root, *every* certificate step-ca has issued or will
issue (the 5-year appliance leaves on Synology, the printer, iDRAC; future ones)
is a valid root-equivalent credential for dockerd on media and unifi, and dockerd
performs no revocation checking. Mitigations that do apply: the listener binds
to the host IP only, and the firewall (step 4) admits util alone — so an appliance
key is only useful to an attacker who is also on util or can spoof its address.
Options as they were weighed:
- *A. step-ca root CA.* Reuses `roles/step-ca-cert` unchanged. **Cost:**
  `--tlsverify` trusts *every* certificate the lab CA has ever issued. The
  5-year leaf certs sitting on Synology, the printer and iDRAC would each
  authenticate to dockerd on media/unifi as root-equivalent. A compromised
  appliance becomes a compromised media server. Revocation does not help:
  dockerd checks no CRL/OCSP.
- *B. Dedicated "docker-mtls" CA, generated and held on the controller*
  (`community.crypto`: 10-year CA key+cert under `{{ export_root }}/docker-ca/`,
  file mode 0600, never leaves the controller). Only three leaves ever exist
  under it: `media` server, `unifi` server, `wud` client. Least privilege,
  no step-ca dependency at API-auth time, rotation entirely in Ansible with
  no provisioner password in play. **Cost:** a second tiny PKI to document
  (this file) and back up (`export_root` is already the thing to back up).
- *C. step-ca with a dedicated intermediate.* Not available without
  re-initialising the CA; dockerd cannot pin to an intermediate anyway. Rejected.

**D2 — Certificate lifetimes: 5-year leaves, 30-day renewal window (user decision).**
Matches the appliance certs; rotation lands mid-2031. Original reasoning kept below.
5-year leaves (the appliance choice) push rotation past the point anyone
remembers how; 90-day leaves without an ACME daemon are a pager. One year
with a 30-day window and the HA tripwire (§5.3) is the balance.

**D3 — `live-restore: true` first, as its own step, run immediately (decided).**
Turning on the TCP listener requires a dockerd restart. Today a dockerd
restart restarts every container on the host — on media that is the whole
gluetun namespace and Plex. Enabling `live-restore` *first* costs **one**
such bounce, after which every later restart (TLS rollout, cert rotation,
Docker upgrades) leaves containers running. Doing both in one restart saves
nothing and mixes two changes.

**D4 — HA device shape: one device, id `wud` (decided).** *Correction 2026-08-24:* `HASS_DEVICEID`/`HASS_DEVICENAME` are post-8.3.1 additions; setting them makes 8.3.1 reject the MQTT trigger outright (it never registered on the first deploy either — nothing reached HA before this was fixed). The 8.3.1 default device id is `wud`; the display name is whatever WUD 8.3.1 defaults to, not "WUD". One WUD instance means one MQTT device (`wud` /
"WUD") with per-watcher `local|media|unifi` count + connectivity sensors,
not the three devices STRATEGY §6.2 expects. Note for the HA workspace.

**D5 — Diun orphan: `remove_orphans: true` in the role (decided).** Removing `services.diun` from hosts.yml leaves the
container running unless the role passes `remove_orphans: true` to
`docker_compose_v2`. Recommend adding it (inventory becomes declaratively
authoritative; verified today that util/media containers match inventory
exactly and unifi's `unms` project is out of scope). Alternative: one-off
`docker compose rm -sf diun` on util.

## 3. Steps (each: change → verify → rollback → commit)

Numbering is deliberate: 1–2 change nothing about the API surface; 3 is the
only step that opens a port; 4 closes it to everyone but util; 5 is the
consumer.

### Step 1 — `live-restore` on every docker host (D3)
- **Change:** `roles/docker` gains `templates/daemon.json.j2` rendered from
  `docker_daemon_config` (defaults: `{"live-restore": true}`), a
  "restart docker" handler, and the systemd drop-in scaffold
  (`/etc/systemd/system/docker.service.d/override.conf` with an empty
  `ExecStart=` reset followed by `ExecStart=/usr/bin/dockerd --containerd=…`
  **without** `-H fd://`, so that `hosts` can live in `daemon.json` later
  without the well-known "specified both as a flag and in the configuration
  file" refusal). `hosts` in this step is `["fd://"]` only.
- **Impact:** one dockerd restart per host → every container restarts once
  (media: gluetun stack ~2–5 min to healthy; util: homepage/traefik blip;
  unifi: traefik blip; the `unms` containers restart too — they are on the
  same daemon). Run in a window you choose. `serial: 1` already means one
  host at a time.
- **Verify:** `docker info --format '{{.LiveRestoreEnabled}}'` = true on all
  three; every inventory container back to healthy; qBittorrent still bound
  to `tun0` (memory: `project_qbt_tun0_bind`) — check the API after gluetun
  is healthy.
- **Rollback:** remove daemon.json + drop-in, `systemctl daemon-reload`,
  restart docker.
- **Commit:** "docker role: manage daemon.json and unit override; enable live-restore".
- **EXECUTED 2026-08-24** (commit c1e4284, one full site.yml, exit 0). Verified
  live: `live-restore=true` on util/media/unifi; every container back within
  ~30 s per host (media's 12 incl. the gluetun namespace, unifi's traefik +
  9 `unms`); qBittorrent still `current_network_interface=tun0`, port 60914;
  UISP answering. Same run also brought WUD up on util (local watcher, MQTT)
  and removed the diun container via `remove_orphans` (D5).

### Step 2 — Issue the three leaves from step-ca, controller-only (D1-A/D2)
- **Change:** `roles/step-ca-cert` is reused as-is via `include_role` with
  explicit vars (they override the role's `vars/main.yml`, which otherwise
  reads `hostvars[...].cert`): `step_ca_cert_cn`, `step_ca_cert_sans`,
  `step_ca_cert_path/key_path/dir`, `step_ca_cert_duration: "43800h"`,
  `step_ca_cert_renewal_threshold: "720h"` (30 days). Three issuances, all
  `delegate_to: localhost` like the appliance flow:
  - `media.michaelpmcd.com` server leaf, SANs DNS + IP 192.168.255.34 →
    `{{ export_root }}/media/docker-tls/{cert,key}.pem`
  - `unifi.michaelpmcd.com` server leaf, SANs DNS + IP 192.168.255.35 →
    `{{ export_root }}/unifi/docker-tls/…`
  - `wud.util.michaelpmcd.com` client leaf → `{{ export_root }}/util/docker-tls/…`
  step-ca's default leaf template carries both `serverAuth` and `clientAuth`
  EKUs, so one issuance path serves both roles (verified: both present).
  step-ca writes `cert.pem` as leaf + intermediate, so it already *is* the chain
  Go's TLS presents; the trust file on every side is the registry's
  `root_ca_cert` (no hardcoded host).
  Where this lives in the play: a new `docker_tls` task file in `roles/docker`,
  run for hosts with `docker.remote_api: true` (server leaves) and for the host
  running WUD (client leaf) — issuance happens on the controller inside that
  host's configure step, then the copy tasks in step 3 deliver.
- **Impact:** none on any host. Controller-side files only.
- **Verify:** `step certificate inspect …/cert.pem` shows the SANs, EKUs, and a
  2031 `not_after`; `step certificate verify --roots root_ca_cert` passes;
  a second run changes nothing (`needs-renewal` gate).
- **Rollback:** delete the `docker-tls/` directories.
- **Commit:** "docker role: issue dockerd/WUD mTLS leaves from step-ca".
- **EXECUTED 2026-08-24.** Three leaves issued (`changed=3` on media/unifi/util,
  all `-> localhost`, no docker restart, no compose change). Verified with
  `step certificate inspect/verify`: SANs DNS+IP on the server leaves, both
  EKUs, issuer = McHomeLab Intermediate, chain to root OK, keys 0600. Second
  run: no-op (see §5.5 for dates).

### Step 3 — dockerd listens on TCP 2376 with mTLS (media, then unifi)
- **Change:** `roles/docker` copies the root CA, the chain (leaf+intermediate) and the key to
  `/etc/docker/tls/` (0600, root) on hosts whose inventory sets
  `docker.remote_api: true`; `daemon.json` gains
  `"hosts": ["fd://", "tcp://<host ip>:2376"], "tlsverify": true,
  "tlscacert"/"tlscert"/"tlskey"`. Bound to the host's own IP, **never
  0.0.0.0**. Handler restarts dockerd — containers survive (step 1).
- **Stage:** set `remote_api: true` on media only → full site.yml → verify →
  then unifi → run → verify. (No `--limit`: play 0 initialises the registry.)
- **Verify** from the controller with the client leaf:
  `docker --tlsverify --tlscacert … --tlscert … --tlskey … -H tcp://media.michaelpmcd.com:2376 info`
  succeeds; the same without a client cert **fails**; `docker ps` locally
  on media still works over `fd://`; `ss -ltnp | grep 2376` shows the
  bind on the host IP only. Then `docker context create media …` on the
  controller for day-to-day use.
- **Rollback:** set `remote_api: false` → next run rewrites daemon.json
  without the TCP host and restarts (containers survive).
- **Commit:** "docker role: optional mTLS TCP API (remote_api)".
- **EXECUTED 2026-08-24**, media then unifi, one full site.yml each
  (`changed=4` on the target, 0 elsewhere). Verified on both: `docker
  --tlsverify … info` with the WUD client leaf succeeds; without a client
  cert → `tls: certificate required`; plain HTTP rejected; `ss` shows 2376
  bound to the host IP only (.34 / .35); local `docker ps` works over
  `fd://`; container creation times identical before/after (dockerd
  restarted, nothing bounced); UISP still answering. Controller `docker
  context` entries `media` and `unifi` created with the same client leaf.
  **Until step 4 lands, 2376 answers to any lab-CA cert holder who can
  reach the DMZ IPs.**

### Step 4 — Firewall: 2376 reachable from util only — **SKIPPED (user decision 2026-08-24)**
> mTLS is accepted as the sole boundary. Recon done via unifly before the
> decision, recorded so nobody re-derives it: Internal → Dmz and Vpn → Dmz are
> *Allow All* by default, so every Internal host (MGMT-V/MGMT-P/GENNET/EDGERISK,
> incl. the Synology at 192.168.255.2) and every VPN client can reach 2376 and
> is gated only by the lab-CA client-cert check; Dmz → Dmz, External/IoT/Hotspot
> → Dmz are already blocked. If this is ever revisited, the rules are: Internal→Dmz
> allow `192.168.254.3 → tcp/2376` above a block `tcp/2376`; Vpn→Dmz block
> `tcp/2376`. unifly's `create -F` filter spec is single-kind per endpoint
> (ip_address / port / network) with no protocol field — doable, or use the UI.

- **Change:** UniFi rule(s) via `unifly`: allow `192.168.254.3 → DMZ:2376`;
  deny any other source to `DMZ:2376` (including DMZ-internal — media and
  unifi must not reach each other's daemon). Record rule ids in this file.
- **Verify:** from util `</dev/tcp/media…/2376` opens; from unifi to media
  it does **not**; from a laptop on the LAN it does not.
- **Rollback:** delete the rules.
- **Commit:** none in this repo (network change) — record here and in memory.

### Step 5 — WUD on util grows remote watchers
- **Change:** `wud.yml.j2` renders, from `services.wud.config.remote_watchers`
  (list of `{name, host, port, watch_by_default}`), one
  `WUD_WATCHER_<NAME>_HOST/PORT/CAFILE/CERTFILE/KEYFILE` block each, plus
  bind mounts of the client leaf + CA into the container (read-only). The
  local watcher stays on the socket. `unifi` watcher gets
  `WATCHBYDEFAULT=false`; traefik on unifi keeps its `wud.watch=true` label
  (already conditional in `traefik.yml.j2`). The client leaf reaches util
  through the registry: controller `export` (file) → util `import` to
  `/opt/containers/wud/tls/`. `services.wud` is **removed from media and
  unifi** (they no longer run WUD).
- **Verify:** `docker logs compose-wud-1` shows three watchers connected;
  the UI lists 6 + 13 + 2 containers; MQTT connected; no `unms` container
  anywhere in the UI.
- **Rollback:** drop `remote_watchers` from inventory → WUD is local-only again.
- **Commit:** "service role: WUD remote watchers over mTLS".
- **EXECUTED 2026-08-24** (two runs: the second dropped the unsupported
  `HASS_DEVICEID/DEVICENAME`, see D4). Verified: three watchers registered
  (`local` socket, `media` and `unifi` over `tcp://…:2376` with the client leaf);
  media untouched, unifi's traefik recreated once for its `wud.watch=true`
  label; `unifi` watcher sees exactly `compose-traefik-1` (no `unms`/`ucrm`);
  MQTT trigger registered and HA discovery populated **30 entities on one
  device `wud`**: per-watcher `*_running` connectivity + `*_update_status`
  binary_sensors, `*_total_count`/`*_update_count` sensors, and one
  `update.wud_<watcher>_<container>` entity per container (STRATEGY §5 was
  right about `update` entities). Snapshot: 14 containers, 6 updates available.
  Client leaf lives at util:`/opt/containers/wud/tls/` (0600 root), mounted
  read-only; a changed leaf restarts only `wud` (handler).

### Step 6 — Retire Diun (D5), homepage, docs
- `remove_orphans: true` in the deploy task (or the one-off), `services.diun`
  gone from util, homepage WUD tile already in place, this file's status →
  IMPLEMENTED with the rule ids and dates, memory updated.

### Step 7 — HA side (claude workspace)
- Confirm one `WUD` device, per-watcher count + connectivity sensors, one
  entity per watched container; wire the connectivity sensors into the
  Admin alert card **before** relying on them as the rotation tripwire.

---

## 4. Rollout order and blast radius, in one table

| step | hosts touched | containers restart? | new exposure |
|---|---|---|---|
| 1 | util, media, unifi | **yes, once, all** (planned window) | none |
| 2 | controller only | no | none |
| 3 | media, then unifi | no (live-restore) | 2376 on host IP, mTLS-gated |
| 4 | UniFi controller | no | closes 2376 to all but util |
| 5 | util | wud only | none |
| 6 | util | diun removed | none |

## 5. Certificate rotation — the documented plan (because ACME can't do this)

### 5.1 What expires, and what happens when it does
| cert | lives on | lifetime | on expiry |
|---|---|---|---|
| step-ca root / intermediate | util (`/opt/containers/step-ca`) | root 10y, intermediate 10y (verify dates, record here) | everything TLS in the lab, not just this — out of scope, but it is the ceiling on every leaf below |
| `media` / `unifi` server leaf | `/etc/docker/tls/` on the host | 5y (43800h) | WUD's watcher for that host fails TLS → HA connectivity sensor `off`; local `docker` on the host is **unaffected** (`fd://`) |
| `wud` client leaf | `/opt/containers/wud/tls/` on util | 5y | **all** remote watchers fail at once; local watcher unaffected |

Nothing about container *operation* depends on these certs. Expiry degrades
monitoring, never the services being monitored.

### 5.2 How renewal works (automatic, gated)
Every `site.yml` run executes the issuance tasks on the controller. If a leaf
is within **30 days** (`720h`) of `not_after`, `step ca certificate --force`
re-issues it in place (new key and cert). The `docker` role then sees changed
files on media/unifi and its handler restarts dockerd — **no container
restart** thanks to live-restore (step 1). The `wud` leaf is delivered to util
and the service role recreates only the `wud` container. So: **rotation = run
site.yml at least once in the last 30 days of validity** (mid-2031). A run at
any other time is a no-op. The provisioner password (`ansible` JWK) is the
same inventory secret the appliance certs use.

### 5.3 The tripwire
If nobody runs site.yml in that window, the server leaf expires and WUD's
watcher for that host disconnects. WUD publishes a **per-watcher connectivity
binary_sensor** to HA (STRATEGY §5). Step 7 puts it on the Admin alert card.
Until step 7 is done, the tripwire is the WUD UI's watcher error only — say so
honestly in memory.

### 5.4 Forced rotation (suspected key compromise)
1. Delete the affected `docker-tls/` directory under `export_root/<host>/`.
2. Run site.yml → new key+cert issued, delivered, dockerd/wud restarted.
3. The old leaf is **not** effectively revocable — dockerd checks no CRL — and
   under D1-A any *other* lab-issued key is an equally valid credential. The
   controls that actually bound a compromise are the host-IP bind and the
   step-4 firewall rule; rotating the leaf alone closes nothing. If the lab CA
   itself is suspect, that is a step-ca root rotation, which is a separate,
   fleet-wide project.

### 5.5 Calendar
| cert | not_before | not_after | renewal window opens |
|---|---|---|---|
| media server leaf | 2026-08-24 | **2031-08-23** | 2031-07-24 |
| unifi server leaf | 2026-08-24 | **2031-08-23** | 2031-07-24 |
| wud client leaf | 2026-08-24 | **2031-08-23** | 2031-07-24 |
| step-ca root / intermediate | — | (record from util `ca.json`/certs when convenient) | — |

All three renew in the same window: one site.yml run in July 2031 rotates the
lot; the docker-role handler restarts dockerd (container-safe) and the service
role recreates wud.
Optional: a controller cron running `site.yml` monthly would make 5.2
unattended — **not** planned here; the user runs site.yml often enough today
and the tripwire covers the gap.

## 6. Findings from WUD's first scan (2026-08-24) — decide during §6.3 pinning

1. **`:latest` is mostly unwatched.** WUD logged for netbootxyz, apt-cacher-ng
   and step-ca: *"not a semver and digest watching is disabled so wud won't
   report any update"*. It did enable digest watching for homepage:latest.
   STRATEGY §5's "digest watching is on by default for non-semver tags" is
   **not** what the running instance does; the per-container `wud.watch.digest`
   label (default `false` per the docs) governs it. Until the fleet is pinned,
   most `:latest` containers will never trigger.
2. **False positive on traefik:** `v3.6 → v3.7-windowsservercore-ltsc2025`.
   WUD's tag matcher needs `wud.tag.include` (e.g. `^v\d+\.\d+$`) on traefik.
3. Both need per-container labels. Infra templates (traefik/gluetun/wud) can
   carry them directly; regular services need the generic `labels:` passthrough
   in `docker-compose.yml.j2` that RESEARCH_DIUN.md §3.2 already called for.

### 6.4 LSCR (linuxserver.io) images are invisible to WUD until a token exists
WUD 8.3.1 (and `main`) ship public registries for Hub/GHCR/Quay/GCR/ECR/Codeberg/
Forgejo but **not LSCR** — `WUD_REGISTRY_LSCR_<NAME>_USERNAME` + `_TOKEN` (a
GitHub PAT) are required. Effect today: the media watcher reports **7 of 12**
containers; bazarr, plex, prowlarr, radarr and sonarr (`lscr.io/linuxserver/*`)
are silently absent. Options: (a) add a GitHub PAT (`read:packages` is enough)
to inventory as `wud_lscr_username`/`wud_lscr_token` and template
`WUD_REGISTRY_LSCR_LINUXSERVER_*`; (b) switch those five images to their
`ghcr.io/linuxserver/*` mirrors (same images, GHCR public — no token) as part
of the §6.3 pinning pass.

**RESOLVED 2026-08-24 with (a):** a 1-year GitHub PAT (expires ~2027-08-24 —
**calendar it**; when it lapses the five linuxserver containers silently drop
out of WUD again) lives in inventory `all.vars` as `wud_lscr_username`/
`wud_lscr_token`; `wud.yml.j2` templates the registry when the token is
defined. Verified: registry `lscr.linuxserver` loaded, media watcher **12/12**.

### 6.5 Pinning pass — EXECUTED 2026-08-24 (STRATEGY §6.3 B/C, §7 items 3–4)
- `service_pull_policy` wired (default `policy` = the module default, verified
  via `ansible-doc`; STRATEGY assumed `missing` — same effect). Apply switch:
  `-e service_pull_policy=always`.
- Generic `labels:` passthrough in `docker-compose.yml.j2` (regular *and*
  gluetun-tunneled services); infra templates carry built-in `wud.tag.include`
  regexes (`traefik_/gluetun_/wud_wud_tag_include` defaults). `$` in label
  values is compose-escaped (`$$`) by the templates.
- Every image pinned to the exact running build (digest/label verified, tag
  existence verified per registry) except: **qbitrr** upgraded to `v5.14.4-1`
  (its March build's tag no longer resolvable — user chose "newer + pin");
  **traefik** `v3.6.12` fleet-wide (util/unifi took 3.6.10→3.6.12);
  **apt-cacher-ng** stays `:latest` + `wud.watch.digest=true` (only tag upstream).
- Run: one full site.yml, every container recreated once (images identical
  bar the three above), qBittorrent still on `tun0`, all healthy. WUD now reports
  `semver=true` for 18/19 with real targets (traefik v3.7.11, homepage v2.1.2,
  step-ca 0.30.2, gluetun v3.41.3, radarr 6.3.0.10514-ls314, …) — that list IS
  the §7 item 5 backlog.
- Gotcha found: semver compares alphanumeric prerelease ids lexically, so WUD
  mis-ranked sonarr (`4.0.9…` over `4.0.17…`) and netbootxyz (`nbxyz9` over
  `nbxyz24`). Fix per WUD docs: `wud.tag.transform` normalising to
  `major.minor.patch-<build>` on the five linuxserver images and netbootxyz.

## 7. What this plan does not do
- Pin the fleet's `:latest` tags, add `service_pull_policy`, or update any
  container (STRATEGY §6.3/§7 — later).
- Expose the Docker API to anything but util's WUD (and the controller's
  `docker context`, which uses the same client leaf — decide in step 3
  whether the controller should hold that leaf at all; it already does, it
  issued it).
- Watch Ubiquiti's `unms` stack.
