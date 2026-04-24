# Research Brief: Sonarr Manual Import Ignoring `copyUsingHardlinks=true`

## Problem

On media.michaelpmcd.com the Sonarr + qBittorrent stack (linuxserver/sonarr:latest, qBittorrent 5.1.3.10, both network_mode: `service:gluetun`) is configured with:

- `mediaManagement.copyUsingHardlinks = true`
- qBt save path: `/data/downloads/torrents`
- Sonarr library path: `/data/media/tv`
- Both backed by the **same NFS export** (`synology.michaelpmcd.com:/volume4/Plex` → `/data`), so hardlinks across the two subtrees are filesystem-eligible.

Expected behavior when Sonarr imports from qBt's finished torrent folder: a hardlink (`nlink=2`, one inode, zero duplicate bytes on NFS).

Observed behavior on a manually-imported 86 GB season pack (Frieren S01, LostYears, 2026-04-22):

```
$ stat -c 'links=%n' "/data/media/tv/Frieren - Beyond Journey's End/Season 1/[LostYears]*S01E01*.mkv"
  links=1

$ qbit-manage log:
  | Torrent Name: [LostYears] Frieren Beyond Journey's End - Season 1 ... |
  | Added Tag: ~share_limit_2.noHL
  | Total noHL Torrents Tagged: 1
```

qbit-manage's `tag_nohardlinks` rule flagged the torrent `noHL` — i.e. it checked both sides of the expected hardlink pair and found separate inodes. Sonarr copied instead of hardlinking.

Result: **~86 GB of duplicate storage** on NFS until the torrent is removed. Not a blocker (39 TB free) but inefficient and it cascades into the qbit-manage share-limit rules (the `noHL` tag lowers the allowed seeding ratio, which on a private tracker like seedpool is quantifiable ratio loss).

## Import was done via the `ManualImport` command

The import was submitted via API (the UI route `/activity/manualimport` 404s in v4 — Manual Import is a modal, not a page):

```
POST /api/v3/command
{
  "name": "ManualImport",
  "importMode": "auto",
  "files": [ { path, seriesId, episodeIds, releaseGroup, quality, languages, indexerFlags: 0, releaseType: "seasonPack" }, ... 28 files ]
}
```

Command completed cleanly — all 28 files moved into the library with correct episode mapping, release group `LostYears`, dual audio Japanese+English, +625 custom format score under the newly-created `[Anime] WEB-1080p` quality profile (id 9). Old VARYG/MALD copies were auto-removed as "Upgrade."

`importMode: "auto"` is supposed to honor the global `copyUsingHardlinks` setting. In this case it demonstrably did not hardlink.

## Hypotheses to investigate

1. **`importMode: "auto"` accepts the string but falls through to a hard-coded path that skips hardlink logic.** The documented values for the `ManualImport` command's `importMode` field may only be `"copy"` and `"move"` — `"auto"` may silently default to `"copy"`. If true, the fix is to omit the field entirely (command default) or pass `"copy"` (same effect but explicit).

2. **Hardlink is attempted, fails silently on NFS, falls through to copy.** NFS technically supports hardlinks across directories on the same export, but:
   - Certain NFSv4 features (ACL mapping, ID squashing, subtree locking) can make `link(2)` return EXDEV or EPERM.
   - Sonarr's import code, when a hardlink fails, falls back to `File.Copy` — and doesn't log the attempt by default at Info level. Would need Sonarr on Debug logging + an immediate retry to catch it in action.
   - The Synology's DSM export for `/volume4/Plex` may have `no_subtree_check` / `secure` / `root_squash` combinations that block cross-subtree hardlinks for the container UID (`abc` inside linuxserver, typically uid 911 / gid 1028 on host).

3. **Container UID-mapping mismatch.** linuxserver/sonarr runs as uid 911 (configurable via PUID). qBt runs as uid 1028. If the NFS server squashes UIDs or the hardlink target directory is owned differently, `link(2)` can fail with EACCES even when unrelated file ops work.

4. **Sonarr v4 regression.** linuxserver/sonarr 4.0.17.2952 is current latest. There's been at least one open issue in the past where `ManualImport` specifically bypassed hardlink (unlike regular download-monitored imports). Worth searching Sonarr's GitHub issues for `ManualImport hardlink` around the v4 era.

## Reproduction path

Pick a small existing download in `/data/downloads/torrents/` that hasn't been imported yet. From outside the stack:

```bash
# Pre-import: verify source file nlink
docker exec compose-sonarr-1 stat -c '%i %h %n' /data/downloads/torrents/<path>.mkv

# Force-set a specific importMode by POSTing ManualImport with each of
# "auto" / "copy" / "move" / omitted on separate test episodes in a
# throwaway series. Compare nlink after each.

# Post-import: same stat on the library target.
```

Also toggle Sonarr's log level to Debug (`Settings → General → Logging`) and tail `/opt/containers/sonarr/logs/sonarr.debug.txt` while triggering the import — look for lines matching `TransferService`, `DiskProvider`, `hardlink`, or `EXDEV`.

## What NOT to do

- Don't delete the existing 86 GB duplicate Frieren copy manually. The torrent is seeding on seedpool (private tracker, ratio matters); when the seedpool seeding quota is hit, the user can remove the torrent via qBt and the duplicate frees naturally. Touching the library side breaks Sonarr's file tracking.
- Don't enable NFS `async` to "speed up hardlinks" — won't change `link(2)` behavior, and `async` is a data-loss risk on the Synology.

## Related

- `research/RESEARCH_ARR_QUALITY_AND_SEEDERS.md` — existing notes on *arr quality/seeder interaction
- `ansible/inventory/test.yml` — sanitized media-host service defs; confirms gluetun/qBt/Sonarr share `/media/plex` mount → `/data` inside containers
- qBt tag `qBitrr-ignored` was set on this torrent pre-import to keep qBitrr's cleanup loop from reaping it during the 86 GB download; may be worth adopting as a default for manually-added torrents outside the *arr grab path

## Urgency

Low. Cosmetic + modest storage cost. Not blocking anything. Fix once it's reproducible on command.
