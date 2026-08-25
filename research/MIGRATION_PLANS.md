# Migration plans — major upgrades held back from the 2026-08-24 backlog drain

**Status:** PLANS, not executed. Everything else in the fleet is current as of
2026-08-24 (WUD: 19 watched, 3 outstanding = these two + apt-cacher-ng's
floating digest). Each plan follows the pinned-fleet discipline: one tag edit in
`hosts.yml`, one full `site.yml`, verify, revert the tag to roll back.

---

## 0. Prerequisite for both: fix the gluetun-namespace name resolution

**Finding (2026-08-24, verified live):** inside gluetun's network namespace
`/etc/resolv.conf` is `nameserver 127.0.0.1` — gluetun's own resolver — so Docker
service names do **not** resolve (`nslookup radarr` → NXDOMAIN) while
`localhost:<port>` works. Two apps were configured with service names and have
been silently failing:

| app | config | symptom | evidence |
|---|---|---|---|
| **bazarr** | `/opt/containers/bazarr/config/config.yaml` → `sonarr.ip: sonarr`, `radarr.ip: radarr` | 176 "Name does not resolve" errors per day, **zero successful syncs** in every log back to 2026-08-17 | `bazarr.log*` |
| **recyclarr** | `/opt/containers/recyclarr/recyclarr.yml` → `base_url: http://radarr:7878`, `http://sonarr:8989` | every 6-hourly sync: "Connection failed – check your base_url" (both instances) | `logs/cli/*.debug.log` |

Neither file is inventory-managed (they live in each app's config volume), so
this is a hand edit on media, followed by a restart of that container only:

```bash
# bazarr: Settings → Sonarr / Radarr → address = localhost (or edit config.yaml
#   ip: localhost for both), then:
docker --context media restart compose-bazarr-1
# recyclarr:
#   base_url: http://localhost:7878   (radarr)
#   base_url: http://localhost:8989   (sonarr)
docker --context media exec compose-recyclarr-1 recyclarr sync --preview   # must reach both
```

Verify: bazarr log shows "Series/Movies … updated" and the missing-subtitle counts
on the homepage move; recyclarr preview lists both instances without errors.

**Why not fix it in gluetun instead?** Gluetun's DOT resolver is what keeps DNS
inside the tunnel; pointing the namespace at Docker's embedded DNS would leak
lookups. `localhost` is the correct address for anything sharing the namespace.

---

## 1. Homepage `v1.10.1 → v2.1.2` (util)

**What the major actually is.** The only item under "⚠️ Breaking Changes" from
v1.10.1 to v2.1.2 is **v2.0.0: "homepage auth" (#6769)** — an *opt-in* password/
OIDC gate (`HOMEPAGE_AUTH_ENABLED=true` + `HOMEPAGE_AUTH_SECRET` +
`HOMEPAGE_EXTERNAL_URL` + `HOMEPAGE_AUTH_PASSWORD`). With it off, nothing about
config files, widgets or `HOMEPAGE_ALLOWED_HOSTS` changes. Config format for
`services/bookmarks/settings/widgets/docker.yaml` is unchanged (verified against
current docs for the widgets in use: whatsupdocker, radarr/sonarr/prowlarr/
bazarr/plex/qbittorrent, traefik removed already).

**Decision to make before running:** enable the auth gate or not. The dashboard
is LAN-only behind traefik + step-ca; it holds ARR/Plex/qBt credentials in its
config and proxies their APIs, so a password gate is cheap insurance against a
guest device. Recommendation: **enable**, password-only, and store
`HOMEPAGE_AUTH_SECRET`/`HOMEPAGE_AUTH_PASSWORD` in `hosts.yml` like the other
secrets. Note the docs' warning: no rate limiting on the login POST.

**Steps**
1. (Optional) inventory: add to `util.services.homepage.environment`:
   `HOMEPAGE_AUTH_ENABLED: "true"`, `HOMEPAGE_AUTH_SECRET: "<openssl rand -base64 32>"`,
   `HOMEPAGE_EXTERNAL_URL: "https://home.util.michaelpmcd.com"`,
   `HOMEPAGE_AUTH_PASSWORD: "<strong>"`.
2. Tag: `ghcr.io/gethomepage/homepage:v1.10.1` → `v2.1.2`.
3. `site.yml` (homepage container only recreates).
4. Verify: container healthy; `https://home.util…` loads (login page if auth on);
   every widget populates (Plex counts, ARR queues, WUD pending count, docker
   status pills); `docker logs compose-homepage-1` has no `host validation` or
   config-parse warnings.
5. Rollback: revert the tag (and the env block) → `site.yml`.

**Blast radius:** one container on util; nothing else references homepage.

---

## 2. Recyclarr `7.5.2 → 8.7.1` (media, gluetun namespace)

**What the major actually is** (v8.0 upgrade guide, verified 2026-08-24):
1. Relative `include:` paths now root at `${appdatadir}/includes` (was `configs/`).
2. `custom_formats[].quality_profiles` renamed to `assign_scores_to`.
3. `settings.yml` legacy `repositories:` block replaced by `resource_providers:`.
4. CLI: list commands print tables (`--raw` for TSV); global `--raw` removed;
   `replace_existing_custom_formats` removed (use `recyclarr state repair --adopt`).

**Current config audit** (`/opt/containers/recyclarr/`, read live):
- `recyclarr.yml`: uses top-level `quality_profiles` with `trash_id` and
  `custom_format_groups.add` — i.e. already the v8 shape; **no**
  `custom_formats[].quality_profiles` to rename. ✔
- `includes/` exists and is empty; no `include:` directives. ✔
- `settings.yml` is the commented default — no `repositories:` block. ✔
- Only the `base_url`s are wrong (§0).

So the config migration is effectively **already done**; the risk is confined
to behaviour changes in sync (cached-ID trust, CF-group defaults).

**Steps**
1. §0 first — a sync that cannot reach Radarr/Sonarr proves nothing.
2. Back up: `cp -a /opt/containers/recyclarr /opt/containers/recyclarr.bak-<date>`
   (the `state/` cache is what v8 reinterprets).
3. Tag: `ghcr.io/recyclarr/recyclarr:7.5.2` → `8.7.1`; `site.yml` (one container).
4. Dry run before the cron fires:
   `docker --context media exec compose-recyclarr-1 recyclarr sync --preview`
   — read the diagnostics panel; expect CF/score changes only if the guide moved.
5. Let the 6-hourly cron run (or `recyclarr sync` by hand); confirm Radarr/Sonarr
   custom formats and profiles look as intended in their UIs.
6. Rollback: revert tag → `site.yml`; restore the backup dir if `state/` was
   rewritten in a way v7 rejects.

**Blast radius:** recyclarr container only (tunneled; its recreate does not
touch gluetun). Radarr/Sonarr *settings* are what a bad sync would change —
hence the preview step.

---

## 3. Not a migration, for completeness: apt-cacher-ng

`modem7/apt-cacher-ng` publishes only `:latest`; WUD digest-watches it and
currently reports a newer digest. Applying it is
`site.yml -e service_pull_policy=always` (the only case where `always` is
needed) — and that flag re-pulls *every* image, so run it when nothing else is
pending. Low value; the cache is a convenience.
