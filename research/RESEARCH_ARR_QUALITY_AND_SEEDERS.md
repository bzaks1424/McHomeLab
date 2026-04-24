# Research Brief: Arr Stack Quality Management (TRaSH / Recyclarr) & Minimum Seeders Policy

## Ground Rules

Scratch scripts and test configs are fine in `/tmp/` or a new scratch directory.
Recyclarr config lives at `/opt/containers/recyclarr/recyclarr.yml` on `media.michaelpmcd.com`. Indexer runtime settings live in each arr's SQLite DB (`/opt/containers/<app>/<app>.db`) and should be modified via each app's REST API, not by hand-editing the DB.
No changes to unrelated hosts/services.

---

## Current State (2026-04-22)

### Quality & custom-format management: TRaSH Guides via Recyclarr

`compose-recyclarr-1` runs as a long-lived container on `media.michaelpmcd.com`. Health: `Up 4+ days (healthy)`. It syncs quality profiles, quality definitions, and custom formats from [TRaSH Guides](https://trash-guides.info/) into Radarr and Sonarr on its internal schedule (nightly by default in the LSIO image).

Config file: `/opt/containers/recyclarr/recyclarr.yml` (verbatim, 2026-04-22):

```yaml
radarr:
  radarr-main:
    base_url: http://radarr:7878
    api_key: <redacted>
    quality_definition:
      type: movie
    quality_profiles:
      - trash_id: d1d67249d3890e49bc12e275d989a7e9   # HD Bluray + WEB
        reset_unmatched_scores:
          enabled: true
      - trash_id: 722b624f9af1e492284c4bc842153a38   # [Anime] Remux-1080p
        reset_unmatched_scores:
          enabled: true
    custom_format_groups:
      add:
        - trash_id: f8bf8eab4617f12dfdbd16303d8da245 # [Required] Golden Rule HD
          select:
            - dc98083864ea246d05a42df0d05f81cc       # x265 (HD)

sonarr:
  sonarr-main:
    base_url: http://sonarr:8989
    api_key: <redacted>
    quality_definition:
      type: series
    quality_profiles:
      - trash_id: 72dae194fc92bf828f32cde7744e51a1   # WEB-1080p
        reset_unmatched_scores:
          enabled: true
      - trash_id: 20e0fc959f1f1704bed501f23bdae76f   # [Anime] Remux-1080p
        reset_unmatched_scores:
          enabled: true
    custom_format_groups:
      add:
        - trash_id: 158188097a58d7687dee647e04af0da3 # [Required] Golden Rule HD
          select:
            - 47435ece6b99a0b477caf360e79ba0bb       # x265 (HD)
```

**Key decisions baked in:**

- `reset_unmatched_scores: enabled: true` on every profile — any custom format Recyclarr doesn't explicitly manage gets zeroed out on each sync. This prevents drift from manual tweaks in the arr UIs accumulating undocumented scoring overrides. If you want a local override it must be captured in `recyclarr.yml` or it will be erased on the next run.
- Only two profiles per app. No "Ultra-HD" / "Remux" / "WEB 2160p" profiles — this stack is a 1080p-first library.
- **Golden Rule HD** custom format with `x265 (HD)` selected applies a negative score to x265-encoded HD releases, pushing them down the scoring ladder. Rationale from TRaSH: at 1080p and below, x265 encodes are usually bad transcodes of h264 sources, not first-generation encodes. Blocking them keeps quality consistent.

### Minimum seeders policy (new as of 2026-04-22)

Prior state: every indexer had `minimumSeeders=1`. This blocks dead 0-seeder releases but lets stale "1 seeder" listings (which are often actually dead — trackers advertise cached counts) through, leading to queued torrents that never complete.

New state, tuned by tracker type:

| App | Indexer | minimumSeeders | Rationale |
|---|---|---|---|
| Radarr | seedpool (API) | **3** | Private tracker, small swarm; older content legitimately sits at 2–3 seeders |
| Radarr | The Pirate Bay | **5** | Public, high-traffic; filter aggressively |
| Sonarr | AnimeTosho | **3** | Anime niche; TRaSH's anime guidance is 3 |
| Sonarr | DrunkenSlug | N/A | Usenet — no peer concept |
| Sonarr | Internet Archive | **5** | Public, metadata is generally honest |
| Sonarr | LimeTorrents | **5** | Public, high-traffic |
| Sonarr | seedpool (API) | **3** | Same as Radarr — private, small swarm |
| Sonarr | The Pirate Bay | **5** | Same as Radarr — public, high-traffic |

Applied via PUT to `/api/v3/indexer/{id}` on each arr. These settings live in each arr's SQLite DB, **not** in Prowlarr, so they survive Prowlarr re-sync unchanged. Recyclarr does **not** manage this field.

---

## How the Pieces Fit Together

```
                  ┌─────────────────────┐
                  │  TRaSH Guides       │  (trash-guides.info)
                  │  (community-        │
                  │   maintained)       │
                  └──────────┬──────────┘
                             │ git clones
                             ▼
                  ┌─────────────────────┐
                  │  compose-recyclarr  │  nightly sync
                  │  recyclarr.yml      │
                  └──────────┬──────────┘
                             │ REST (API keys)
                ┌────────────┴────────────┐
                ▼                         ▼
        ┌───────────────┐         ┌───────────────┐
        │    Radarr     │         │    Sonarr     │
        │  quality      │         │  quality      │
        │  profiles +   │         │  profiles +   │
        │  custom       │         │  custom       │
        │  formats      │         │  formats      │
        │  minSeeders   │         │  minSeeders   │  ← set by hand via API,
        │               │         │               │    NOT touched by Recyclarr
        └───────┬───────┘         └───────┬───────┘
                │                         │
                │       Prowlarr syncs    │
                │       indexer DEFs      │
                │       (search endpoints │
                │        + API keys only) │
                │                         │
                └───────────┬─────────────┘
                            ▼
                      ┌──────────┐
                      │ Prowlarr │
                      └─────┬────┘
                            │ torznab
                            ▼
                      [indexers]
```

Clear separation of concerns:

1. **TRaSH** = community scoring logic (what a "good WEB-1080p release" looks like).
2. **Recyclarr** = automation that copies TRaSH's scoring into Radarr/Sonarr's quality system.
3. **Radarr/Sonarr** = apply the scoring + minSeeders filter when picking releases.
4. **Prowlarr** = owns WHICH indexers exist and their API credentials. Pushes sync-only indexer definitions into Radarr/Sonarr.

Each layer has a single source of truth. Editing TRaSH scoring via the arr UI gets overwritten by Recyclarr. Editing indexer definitions in Radarr/Sonarr gets overwritten by Prowlarr. **Only `minimumSeeders` and a few other per-consumer fields are safe to edit directly in Radarr/Sonarr** — Prowlarr's sync leaves them alone.

---

## What Recyclarr Actually Changes on Sync

Recyclarr's docs are explicit:

- **Updates:** quality profiles, quality definitions, custom formats, custom-format scores.
- **Does not touch:** indexer settings, download clients, tags, root folders, import lists, quality-profile assignments on existing movies/series (only the profile definitions themselves).
- **Destructive behavior:** with `reset_unmatched_scores: enabled: true`, any custom format present in the arr but not listed in `recyclarr.yml` gets its score reset to 0 on each sync. The format itself isn't deleted, just neutralized.

**Implication for this stack:** the scoring system is entirely driven by `recyclarr.yml`. To add/change scoring:

1. Add the `trash_id` to `recyclarr.yml`.
2. Restart `compose-recyclarr-1` or wait for the nightly sync.
3. Verify in the Radarr/Sonarr UI that the format appears and is scored.

Common trash_id lookup path: https://github.com/recyclarr/config-templates and https://trash-guides.info/ — click the format and the trash_id is in the URL / frontmatter.

---

## Operational Notes

### When Recyclarr's scores seem wrong

The arr UI will show the score column per release in the search results. If a release is being scored lower than you'd expect (or not at all):

1. Confirm `recyclarr sync` actually ran successfully — logs at `/opt/containers/recyclarr/logs/`.
2. Confirm the custom format in the arr's UI has a non-zero score for your profile.
3. Confirm the release text actually matches the custom format's regex. The [TRaSH custom format page](https://trash-guides.info/Radarr/Radarr-collection-of-custom-formats/) shows each regex.

### When Recyclarr fails silently

The container can be `healthy` without actually syncing — Recyclarr exits 0 on many recoverable errors. Symptoms:
- Quality profiles look stale (last modified in Radarr UI is weeks ago)
- Custom formats missing from the arr after a TRaSH guide update

Check `/opt/containers/recyclarr/logs/recyclarr_log_*.log` for the last successful sync. If it's old, `docker restart compose-recyclarr-1` to force a fresh sync and `docker logs -f compose-recyclarr-1` to watch it. Recyclarr's exit code is useful: non-zero means hard failure, zero-with-warnings means partial (check the log body).

### When minimumSeeders is too aggressive

Symptom: Sonarr/Radarr report "no results" for releases that clearly exist on the tracker.

Diagnosis: in Prowlarr, do a manual search for the same query. Prowlarr shows raw seeder counts per result — if every hit is ≤ your threshold, either:
1. The release genuinely has no seeders (threshold is doing its job), or
2. Your threshold is too high for this tracker's swarm sizes.

Private-tracker content (especially older releases) often sits at 1–2 seeders legitimately. If it's a title you care about, consider lowering just that indexer to 1 or 2, or manually grab the release (Sonarr/Radarr → Manual Search → click the result, which bypasses minSeeders).

### Drift detection

Recyclarr doesn't log "I changed nothing" differently from "I changed a lot." To know if your TRaSH config is drifting from upstream:

```bash
docker exec compose-recyclarr-1 recyclarr sync --preview radarr
docker exec compose-recyclarr-1 recyclarr sync --preview sonarr
```

`--preview` lists proposed changes without applying them. Empty output = in sync.

### When to re-visit the seeders policy

Revisit if:
- Seedpool's swarm size changes meaningfully (e.g., they lose users, bump threshold back down)
- A new indexer is added (pick public/private bucket based on traffic)
- The "grabbed but never completed" rate climbs back up — that means stale counts are sneaking through even at 5; consider raising Prowlarr's indexer-level filter instead (it applies before the arr sees the release)

---

## Known Limitations & Gotchas

- **Recyclarr only knows about `trash_id`-marked configs.** If TRaSH renames or deprecates a guide, the trash_id stays stable, but your profile might silently diverge from the community latest. Check [Recyclarr's changelog](https://recyclarr.dev/wiki/guide-changes/) once a quarter.
- **Profile cutoff scores** (the "upgrade until" threshold) are NOT managed by Recyclarr — only the scoring of individual formats. You set the cutoff in the arr UI. Currently Radarr's `Music by John Williams (2024)` shows `qualityCutoffNotMet: true`, meaning Radarr will keep searching for a higher-quality version until the cutoff is met. Worth a sanity-check of profile cutoffs if unexpected upgrades happen.
- **x265 block is HD-only.** The `Golden Rule HD` format only downscores x265 at 720p/1080p. 2160p x265 is fine (that's where x265 is the native encode). If/when a 4K profile is added, use the 2160p-aware format group, not this one.
- **`reset_unmatched_scores: enabled: true` is destructive.** Any manual scoring tweak made in the arr UI **will be erased** on the next sync. This is the intended tradeoff — predictable config at the cost of UI flexibility. If temporary manual overrides are ever needed, disable this flag (don't just expect it to stick).
- **Prowlarr's indexer-level filters** (Prowlarr → Indexers → edit → Limits) are a separate filter layer, currently unused. Setting `minimumSeeders` in Prowlarr would apply BEFORE Radarr/Sonarr see the release, which is more efficient but also opaque (the arr UI won't show filtered-out releases at all). Current choice: filter at the arr level for visibility.

---

## Relevant Config Locations

| Component | Path | Purpose |
|---|---|---|
| Recyclarr config | `/opt/containers/recyclarr/recyclarr.yml` | TRaSH profile + format selection |
| Recyclarr logs | `/opt/containers/recyclarr/logs/` | Per-run sync logs |
| Recyclarr state | `/opt/containers/recyclarr/state/` | Sync cache |
| Radarr DB | `/opt/containers/radarr/radarr.db` | Quality profiles, custom formats, indexers, minSeeders |
| Sonarr DB | `/opt/containers/sonarr/sonarr.db` | Same for Sonarr |
| Prowlarr DB | `/opt/containers/prowlarr/prowlarr.db` | Indexer definitions, tags, indexer proxies |

---

## API Cheatsheet

### Check all indexer minimumSeeders (Radarr or Sonarr)

```bash
curl -sk -H "X-Api-Key: <KEY>" "https://<app>.media.michaelpmcd.com/api/v3/indexer" | \
  python3 -c "
import json,sys
for i in json.load(sys.stdin):
    ms = next((f['value'] for f in i.get('fields',[]) if f['name']=='minimumSeeders'), 'N/A')
    print(f\"  id={i['id']:3} {i['name']:<35} minSeeders={ms}\")"
```

### Set minimumSeeders on an indexer

```bash
APP_URL="https://radarr.media.michaelpmcd.com"
API_KEY="<redacted>"
ID=6
TARGET=3

curl -sk -H "X-Api-Key: $API_KEY" "$APP_URL/api/v3/indexer/$ID" > /tmp/i.json
python3 -c "
import json
d = json.load(open('/tmp/i.json'))
for f in d['fields']:
    if f['name']=='minimumSeeders':
        f['value']=$TARGET
json.dump(d, open('/tmp/i.json','w'))"
curl -sk -X PUT -H "X-Api-Key: $API_KEY" -H "Content-Type: application/json" \
  "$APP_URL/api/v3/indexer/$ID" -d @/tmp/i.json
```

Both arr APIs return HTTP 202 on success.

### Force Recyclarr sync

```bash
docker exec compose-recyclarr-1 recyclarr sync radarr
docker exec compose-recyclarr-1 recyclarr sync sonarr
```

---

## Open Questions

1. **Prowlarr-level filtering instead of per-arr.** If grabbed-but-stale torrents become a problem again at minSeeders=3/5, the next layer to add is Prowlarr's per-indexer query caps (Indexer → Edit → Query Limits). Tradeoff is visibility: Prowlarr-filtered results never reach Radarr/Sonarr, so the UI shows "no results" vs "filtered out."

2. **Sonarr v4 custom-format scores.** Sonarr released native custom-format support in v4; TRaSH Sonarr profiles exist but the community is still iterating. Re-check [Recyclarr's Sonarr guide](https://recyclarr.dev/wiki/yaml/config-reference/quality-profile/) every few months for new recommended formats.

3. **Adding a 4K profile.** Current stack is 1080p-first. If a 2160p/UHD profile is ever added, the corresponding TRaSH quality profile + `Golden Rule UHD` format group should be added to `recyclarr.yml`, not copied from the HD profile. Using HD formats on a UHD profile silently mis-scores releases.

4. **Recyclarr on an opt-in or opt-out basis for new arrs.** If Readarr/Lidarr/etc. are added to the stack, Recyclarr supports them — add a top-level section to `recyclarr.yml`. If the decision is to NOT use TRaSH for music (for example), document that explicitly in the config comments.
