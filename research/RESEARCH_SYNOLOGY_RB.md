# RESEARCH R-B: Synology DSM 7.x as-code — is there a maintained library?

**Date:** 2026-08-25
**Status:** RESEARCH — answers `RESEARCH_SYSADMIN_AGENT.md` §11 R-B (survey again for a
maintained Synology collection/module set before accepting observe-only; if
none qualifies, design the NFS self-backup + manifest scheme). Feeds §9 Q11
and Phase 4 (`observed` provision type).

**Ground rules honoured:** no file in `McHomeLab` or `McHomeLab-Inventory` was
modified. Nothing was run against the live Synology (`synology.michaelpmcd.com`,
192.168.255.10/.2) — this is a documentation/source-code survey only, using
WebSearch/WebFetch and direct `curl`/`gh api` reads of public GitHub/PyPI/Galaxy
endpoints. Everything below is dated **2026-08-25**; check freshness before reuse.
**Citation convention:** every non-obvious claim carries a `[KEY]` tag; the
full source list with the exact URL, fetch method, and observed
date/version/commit for each key is in §7. A claim with no `[KEY]` is either
this report's own reasoning/recommendation, or restates something already
`[KEY]`-cited one sentence earlier.

---

## 0. tl;dr verdict

**No maintained library exists that both covers this scope and can be trusted
as-is.** One brand-new Ansible collection (`stevefulme1.synology_dsm`) is
structurally on-target and worth a second look later, but it fails this
session's inspection on two independent grounds (idempotency bug in the exact
module this research needed, and no track record — see §2). Recommend:
**fallback design (§4) now, re-evaluate `stevefulme1.synology_dsm` at Phase 4
start against the live box in `--check` mode only.**

The one genuinely good outcome of this research: Synology's own official,
actively-maintained open-source Go client (`SynologyOpenSource/synology-csi`,
§3) hands us **exact, authoritative API call shapes** for shares, NFS
privileges, and permissions — better grounding than any of the community
wrappers gave last session. That upgrades §5 (the `uri`-declarable subset)
from "reverse-engineered guess" to "sourced from Synology's own code."

**Two corrections this pass made to its own earlier drafts, caught only by
going back and re-verifying every claim against a primary source per the
coordinator's citation request** — kept here because the correction itself is
informative:
- `py-synologydsm-api` is **not dead**. An earlier pass in this same session
  characterized it as inactive/discontinued based on a WebSearch AI-summary
  of Snyk/libraries.io (never independently fetched). Querying PyPI's and
  GitHub's own APIs directly shows the opposite: v2.10.4 released
  2026-07-08, repo pushed 2026-08-01 `[GH-PSDA][PYPI-PSDA]`. The
  **maintenance-status claim was wrong; the scope claim (no
  share/NFS/user/group/task-scheduler write capability, read-only sensor
  data only) still holds** on direct inspection of its source (§1.2). See
  §0.1 for the full correction record.
- A claim that `SYNO.Core.Share.lib`'s method list is independently
  corroborated by a DSM-5.1-era third-party API-definitions repo
  (`kwent/syno`) could not be re-verified — the file 404s at the path this
  report originally cited, and the repo has no `definitions/` tree at all
  under that name `[GH-KWENT-404]`. **That corroboration claim is retracted**
  (§5's table below no longer cites it; the underlying finding — the
  `SYNO.Core.Share` verb set — still stands on its two remaining, actually
  fetched sources, `[SRC-CSI-SHARE]` and `[SRC-N4S4-SHARE]`).

### 0.1 Correction record: `py-synologydsm-api`

| | Original claim (uncorrected pass) | What re-verification found |
|---|---|---|
| Source of original claim | WebSearch AI-summary quoting Snyk Advisor and libraries.io pages — **neither page was fetched directly**, only a search-engine's synthesis of them | `curl https://pypi.org/pypi/py-synologydsm-api/json` and `gh api repos/mib1185/py-synologydsm-api{,/releases}` — both fetched directly, 2026-08-25 |
| Claim | "hasn't seen any new versions ... in the past 12 months," "classified as Inactive," "46 weekly downloads" | v2.10.4 uploaded **2026-07-08T16:48:48Z**; six releases in the 10 weeks before that (v2.9.0 through v2.10.3, 2026-06-04 through 2026-07-08); repo `pushed_at` **2026-08-01T10:28:32Z**; 32 GitHub stars; not archived `[GH-PSDA][PYPI-PSDA]` |
| Likely explanation | There *is* a separate, genuinely archived repo, `hacf-fr/synologydsm-api` (org-owned, `archived: true`, last pushed 2025-02-09) `[GH-PSDA-PARENT]` — the Snyk/libraries.io pages the WebSearch summary drew from were almost certainly describing that dead predecessor/fork-source, not the actively-maintained `mib1185/py-synologydsm-api` continuation that PyPI's `py-synologydsm-api` package now ships from. | |
| What still holds | Its API surface (`src/synology_dsm/api/core/share.py`, read on 2026-08-25 at commit `d4da6388815d`) has `shares`, `get_share`, `share_name`, `share_path`, `share_recycle_bin`, `share_size` — **read-only**, no `create`/`set`/`delete`. Directory listing of `src/synology_dsm/api/` shows `core`, `download_station`, `dsm`, `file_station`, `photos`, `storage`, `surveillance_station`, `virtual_machine_manager` — **no `user.py`, `group.py`, or `task_scheduler.py` anywhere in the package** `[SRC-PSDA-APIDIR][SRC-PSDA-COREDIR][SRC-PSDA-SHARE]`. | |

Net effect on the verdict: **unchanged**. `py-synologydsm-api` is a live,
well-maintained library — just never intended for declaring state (it backs
Home Assistant's Synology sensor integration). It stays out of contention for
the same reason it always would have: no write surface for anything this
research asked about.

---

## 1. Survey of candidates

### 1.1 Ansible Galaxy / GitHub collections

| Candidate | Repo | Last push | Galaxy releases | License | Verdict |
|---|---|---|---|---|---|
| `tafeen.synology` | github.com/Tafeen/ansible-synology-collection | **2023-07-13** `[GH-TAFEEN]` | 1.0.0 (2023-07-12), 1.0.1 (2023-07-17) `[GALAXY-SEARCH]` | GPL-2.0 `[GH-TAFEEN]` | Dead. 3+ years stale. |
| `agaffney.synology_dsm` | github.com/agaffney/ansible-synology-dsm | **2024-01-10** `[GH-AGAFFNEY]` | role (not independently confirmed as a Galaxy-indexed version in the collection-versions search — see §6) | MIT `[GH-AGAFFNEY]` | Dead as of this session (96 stars is the highest adoption of any candidate, but no activity in 2.5 years). |
| `meyayl/syno-ansible` | github.com/meyayl/syno-ansible | **2021-02-07** `[GH-MEYAYL]` | — | none declared `[GH-MEYAYL]` | Dead. |
| **`stevefulme1.synology_dsm`** | github.com/stevefulme1/ansible-synology-dsm | **2026-06-12** `[GH-SF]` | **0.1.0 only**, published 2026-05-21T14:07:22Z `[GALAXY-SF-VER]` | GPL-3.0-or-later `[SRC-SF-LICENSE]` | New, broad, but disqualified this session — see §2. |

Verified via the GitHub REST API (`repos/<owner>/<repo>` for `pushed_at`/
`archived`/`license`/`stargazers_count`, `repos/.../commits`,
`repos/.../contributors` — see §7 for exact endpoints) and the Ansible Galaxy
v3 API (`galaxy.ansible.com/api/v3/plugin/ansible/search/collection-versions/?keywords=synology`,
18 results total `[GALAXY-SEARCH]`, all captured above or irrelevant unrelated
hits — `jaxzin.infra` and `brainfartlab.overlord` matched the keyword search
but are not Synology collections on inspection).

No other Synology-scoped Ansible collection turned up in a second, differently
worded Galaxy/GitHub search pass (WebSearch for "github synology ansible 2025
2026 nfs share module idempotent" `[WS-GH-SEARCH-2]`) beyond the same four
names.

### 1.2 Python libraries

| Library | Repo/PyPI | Latest release | Activity | License |
|---|---|---|---|---|
| **N4S4/synology-api** | github.com/N4S4/synology-api, pypi `synology-api` | **v0.9.2, 2026-08-04T13:16:52Z** `[GH-N4S4-REL]` | `pushed_at` **2026-08-24T14:28:40Z** (yesterday relative to this research date) — genuinely active `[GH-N4S4]` | MIT `[GH-N4S4]` |
| **py-synologydsm-api** (`mib1185/py-synologydsm-api`) | pypi `py-synologydsm-api` (2.10.4) | **v2.10.4, 2026-07-08T16:48:48Z** `[PYPI-PSDA]` | `pushed_at` **2026-08-01T10:28:32Z** — active, but see §0.1 for the correction and §1.2 below for scope | MIT `[GH-PSDA]` |

**Correction to the prior session's finding** (`RESEARCH_SYSADMIN_AGENT.md`
§11: "N4S4/synology-api last release 2024-08"): that was true on the date it
was checked but is **stale today**. Verified via
`curl https://api.github.com/repos/N4S4/synology-api/releases` and
`.../repos/N4S4/synology-api`, both fetched 2026-08-25 `[GH-N4S4][GH-N4S4-REL]`:

```
v0.9.2  2026-08-04T13:16:52Z
v0.9.1  2026-07-03T17:41:18Z
v0.9.0  2026-05-27T22:11:49Z
v0.8.2  2025-12-08T01:48:36Z
v0.8.1  2025-05-07T10:50:48Z
v0.8    2025-02-20T10:01:17Z
v0.7.3  2024-09-28T01:56:30Z   (added TaskScheduler, see GH-N4S4-158)
v0.7.2  2024-03-15T00:00:17Z
pushed_at (repo): 2026-08-24T14:28:40Z
open_issues: 7, archived: false, license: MIT
```

`N4S4/synology-api` is real, MIT-licensed, and under active single-maintainer
development (readme `[SRC-N4S4-README]`: "I do this for hobby... in my little free time" — a
hobby project, but a genuinely maintained one; 34 total PyPI releases per
`pypi.org/pypi/synology-api/json` `[PYPI-N4S4]`). **It is a raw API wrapper,
not a declarative/idempotent tool** — it exposes Python methods that call DSM
webapi endpoints 1:1; there is no Ansible-module layer, no `check_mode`, no
diff, and no built-in "only change if different" logic anywhere in it,
confirmed by reading `core_share.py`, `core_group.py`, `core_user.py`,
`task_scheduler.py`, `core_backup.py` source directly (commit SHAs and dates
in §7 — each was fetched pinned to the specific commit that last touched that
file, not a moving `master` HEAD). Using it means writing the
GET→compare→SET wrapper yourself, in Python, inside a custom Ansible module —
exactly the `api_setting.yml` pattern (`RESEARCH_SYSADMIN_AGENT.md` A2) that's
already the plan for other non-native systems, just done in Python instead of
`uri`+Jinja.

**Confirmed by reading the actual source** (`synology_api/*.py`, each pinned
to the commit SHA in §7):

- `core_share.py` `[SRC-N4S4-SHARE]` → class `Share`: `validate_set`,
  `list_folders`, `get_folder`, `create_folder`, `delete_folders`, `clone`,
  `decrypt_folder`, `encrypt_folder`; class `SharePermission`:
  `get_folder_permission_by_name`, `get_folder_permissions`,
  `set_folder_permissions`, `get_local_group_permissions`,
  `set_local_group_permissions`. **No NFS privilege methods anywhere in this
  file or the package** — there is no `file_serv_nfs.py`/similar module in
  `synology_api/` at all, confirmed by listing the full package directory via
  the GitHub Contents API (47 files, none NFS-share-privilege-shaped)
  `[SRC-N4S4-PKGLIST]`. The "Supported APIs" reference page at
  `n4s4.github.io/synology-api/docs/apis` `[N4S4-DOCS-APIS]` that lists
  `FileServ.NFS.SharePrivilege` is a **catalog of the DSM API surface for
  reference**, not a claim that the Python wrapper implements it — a
  distinction the page's presentation doesn't make obvious, and one an
  earlier WebFetch-AI-summary in this research session got wrong before
  source inspection corrected it.
- `core_group.py` `[SRC-N4S4-GROUP]` → class `Group`: **full CRUD** —
  `get_groups`, `get_users`, `get_speed_limits`, `get_quota`,
  `get_permissions`, `set_group_info`, `set_share_quota`,
  `set_share_permissions`, `set_speed_limit`, `add_users`, `remove_users`,
  `create`, `delete`.
- `core_user.py` `[SRC-N4S4-USER]` → `user_list`, `user_get`, `user_create`,
  `user_set`, `user_delete`, `user_group_join(_status)`.
- `task_scheduler.py` `[SRC-N4S4-TASK]` → `SYNO.Core.TaskScheduler` (list v3,
  get_task_config v4, set_enable, run, delete, create_script_task,
  modify_script_task, plus beep/service-control/recycle-bin task variants)
  and `SYNO.Core.EventScheduler` (`config_get`/`config_set` for output
  config). Implemented per GitHub issue #158, opened 2024-03-07, **closed
  2024-09-13** (shipped in v0.7.3) `[GH-N4S4-158]`. No Hyper Backup-specific
  scheduling coverage in this class.
- `core_backup.py` `[SRC-N4S4-BACKUP]` → **this is the one genuinely useful
  discovery from this library for R-B's fallback design**: it wraps
  `SYNO.Backup.Config.Backup` (methods `list`/`start`/`status`/`download`,
  version 2) and `SYNO.Backup.Config.Restore` (`check`/`delete`/`list`/
  `list_conflict`/`start`/`status`/`upload`, version 2) — this **is** DSM's
  Configuration Backup feature (System → Update & Restore → Configuration
  Backup; the `.dss` file the SSH `synoconfbkp` utility also produces),
  reachable over the **Web API**, not just SSH. It also wraps Hyper Backup
  task control (`backup_task_list/get/run/cancel/suspend/discard/resume/
  remove`, `backup_repository_list/get`) and Hyper Backup Vault
  (`vault_target_list`, `vault_target_settings_get`,
  `vault_task_statistics_get`) — read/control surface, not
  schedule-declaration. **This one method/version mapping (`SYNO.Backup.Config.Backup`,
  v2) has only this single source** — it was not cross-checked against
  `synology-csi` or an official doc; see §6.

**py-synologydsm-api scope** (the corrected finding from §0.1): read-only
info-gathering only. `src/synology_dsm/api/` contains `core`,
`download_station`, `dsm`, `file_station`, `photos`, `storage`,
`surveillance_station`, `virtual_machine_manager` `[SRC-PSDA-APIDIR]`; `core/`
contains `external_usb.py`, `hardware.py`, `security.py`, `share.py`,
`system.py`, `upgrade.py`, `utilization.py` `[SRC-PSDA-COREDIR]` — no
`user.py`, `group.py`, or `task_scheduler.py` anywhere. `core/share.py`'s
`SynoCoreShare` class exposes exactly `update`, `shares`, `shares_uuids`,
`get_share`, `share_name`, `share_path`, `share_recycle_bin`, `share_size` —
all reads, no writes `[SRC-PSDA-SHARE]`. This is the library backing the Home
Assistant Synology DSM integration's sensors; it was never meant to declare
state.

### 1.3 DSM SSH CLI (`synoshare`, `synouser`, `synogroup`, `synoconfbkp`)

Source: Synology's own **"CLI Administrator Guide for Synology NAS"**
(`https://global.download.synology.com/download/Document/Software/DeveloperGuide/Firmware/DSM/All/enu/Synology_DiskStation_Administration_CLI_Guide.pdf`
`[SYN-CLI]`), fetched and extracted with `pdftotext`. **PDF metadata:
CreationDate 2021-03-18** — this is the DSM 6/early-7 vintage of the guide;
I found no DSM 7.2/7.3-specific republication, only third-party 2023–2024
sources asserting these commands still work unchanged on DSM 7
(mariushosting.com "Basic Command Lines For DSM 7" `[WS-MARIUS]`, the
`wuseman/SYNOLOGY` cheatsheet repo `[WS-WUSEMAN]` — both are community blogs/
repos, not Synology, and neither was independently fetched in full this
session beyond the WebSearch summary that surfaced them; treat as weak
corroboration, not confirmation). **I did not run these against the live
Synology, so DSM 7.2/7.3 exact-syntax compatibility is documented, not
verified this session.**

Confirmed present in the guide, with syntax `[SYN-CLI]`:
- `synouser {--add|--del|--rename|--modify|--setpw}` — local user CRUD. `--add username passwd full_name expired email app_privilege`. Root/sudo only.
- `synogroup {--add|--del|--rename|--member}` — local group CRUD + membership.
- `synoshare {--add|--del|--rename|--setuser}` — shared-folder CRUD **and
  local user/group access-list editing** (`--setuser sharename {NA|RO|RW}
  {+|-|=} user_list`). **This is share-level ACL only — it has no NFS
  client/IP-privilege verb.** `nfs` appears in the guide exactly once, as a
  service name argument to `synoservice --enable/--disable/--start/--stop nfs`
  (the NFS *service* on/off switch, not per-share export rules).
- `synoservice {--list|--enable|--disable|--start|--stop|--restart|--keyon|--keyoff|--detail}` — service management, `nfs`/`samba`/`afp`/`ssh`/`ftp`/... are valid service names.
- `synowin {--joinWorkgroup|--joinDomain}` — AD/workgroup join.

**Conclusion: the SSH CLI has no path to declare NFS export/client privileges.**
That configuration is Web-API-only (`SYNO.Core.FileServ.NFS.SharePrivilege`,
§3). This matters directly for the two shares named in the research question
(`/volume1/SSD_SHARE`, `/volume4/Plex`) — CLI cannot do it, API can.

`synoconfbkp` was **not** in the official CLI guide (it postdates the 2021
document, or lives in a different guide not located this session). Confirmed
instead via community sources only — blackvoid.club `[WS-BLACKVOID]`,
3os.org `[WS-3OS]`, a forum.synology.com thread `[WS-FORUM-CONFBKP]` — as:
```
/usr/syno/bin/synoconfbkp export --filepath=/volume1/backups/DSMconfig.dss
```
**This exact flag syntax has no official-document citation and is unverified
against DSM 7.2/7.3** (see §6). No source found this session gave a confirmed
CLI restore command either — only "use the DSM UI wizard." Given §1.2's
`SYNO.Backup.Config.Backup` Web API finding, **the API route is both more
capable (list/status/download programmatically) and better-evidenced than the
SSH route** — recommend the API for the fallback design, with `synoconfbkp`
as a documented-only backup option if SSH access is what's available and the
API proves gated.

### 1.4 DSM Web API — general findings

Full class/method inventory pulled from the docs index at
`n4s4.github.io/synology-api/docs/apis` `[N4S4-DOCS-APIS]` (a
community-curated reference of DSM's API surface, cross-checked against
Synology's own code in §3 rather than trusted alone): the relevant
subcategories under `FileServ.NFS` are `AdvancedSetting`, `ConfBackup`,
`IDMap`, `Kerberos`, `SharePrivilege`; under `Core.Share`: `Crypto`,
`CryptoFile`, `KeyManager` variants, `Migration`, `Permission`,
`PermissionReport`; under `Core.User`: `Group`, `PasswordExpiry`,
`PasswordMeter`, `PasswordPolicy`, `UsernamePolicy`; under `Core.Group`:
`ExtraAdmin`, `Member`, `ValidLocalAdmin`; under `Core.TaskScheduler`: `Root`.
None of Synology's official developer-guide PDFs found this session
(`[SYN-CLI]`, `[SYN-LOGIN]`, `[SYN-FS]`) document `SYNO.Core.Share`,
`SYNO.Core.FileServ.NFS.*`, `SYNO.Core.User`, `SYNO.Core.Group`, or
`SYNO.Core.TaskScheduler` — those remain **undocumented/internal APIs**, same
conclusion as last session, reverse-engineered by every third party covering
them (including Synology's own `synology-csi`, which is first-party code but
still calling undocumented internal endpoints — see §3 disclaimer).

---

## 2. Why `stevefulme1.synology_dsm` is disqualified this session

This collection looked, on paper, like exactly the answer to the research
question — a single Galaxy release (0.1.0, published 2026-05-21T14:07:22Z
`[GALAXY-SF-VER]`) with modules named `dsm_shared_folder(_info)`,
`dsm_nfs_share(_info)`, `dsm_user(_info)`, `dsm_group(_info)`,
`dsm_task_scheduler(_info)`, `dsm_hyper_backup(_info)`, `dsm_snapshot(_info)`,
`dsm_snapshot_replication`, `dsm_service(_info)`, `dsm_ssh`, plus roles
`dsm_share_setup`, `dsm_user_management`, `dsm_backup_setup`,
`dsm_replication_setup`, `dsm_security_hardening` — 83 plugin/role entries in
total `[GALAXY-SF-VER]`, GPL-3.0-or-later `[SRC-SF-LICENSE]`,
`requires_ansible >=2.16.0` `[GALAXY-SF-VER]`.

Inspection findings that disqualify it as-is:

1. **Track record: none.** Repo created 2026-04-30T13:41:16Z, single Galaxy
   release, last GitHub push 2026-06-12T14:08:04Z (10+ weeks stale as of this
   research date), **0 stars, 0 forks, 0 watchers, 0 open issues**
   `[GH-SF]` — zero evidence any human other than the author has ever run it.
   README's "Usage" section literally reads "Coming soon" `[SRC-SF-README]`.
2. **Commit history admits fabrication.** `gh api
   repos/stevefulme1/ansible-synology-dsm/commits` `[GH-SF-COMMITS]` shows a
   commit `a5bd1c61` dated 2026-05-20T23:11:46Z titled `"audit: delete 23
   fabricated stub modules, fix validate-modules finding"` — the author (or
   an agent working for them; the large majority of commits are authored as
   `Test User`, not a human name, a pattern consistent with AI-agent-generated
   commits) had already shipped and then had to remove 23 non-functional
   stub modules before the first release. That is a strong signal the
   *remaining* ~60 modules have not each been individually verified against
   a real device either — the audit that caught 23 fakes is not evidence the
   other 60 are real, only that a sweep happened once. Only one contributor,
   `stevefulme1` (38 contributions) `[GH-SF-CONTRIB]`.
3. **A confirmed, concrete idempotency bug in the exact module this research
   needed.** Read `plugins/modules/dsm_nfs_share.py` in full (raw source,
   commit `a598c6215159`, 2026-05-15T18:40:13Z) `[SRC-SF-NFS]`: the module
   fetches `existing_rules` via `SYNO.Core.Share` `get` with
   `additional=["nfs_privilege"]`, but in the `state: present` branch it
   **never compares `existing_rules` to the desired `privilege` dict** — it
   sets `changed = True` unconditionally and always issues the
   `SYNO.Core.Share` `set` call, on every run, regardless of whether anything
   differs. Contrast with `dsm_user.py` (`[SRC-SF-USER]`, same commit batch,
   2026-05-15T18:09:08Z), `dsm_group.py` (`[SRC-SF-GROUP]`, same commit), and
   `dsm_shared_folder.py` (`[SRC-SF-SHARED]`, same commit) in the same
   collection, which **do** implement a proper existing-vs-desired field
   comparison before setting `changed`. So the idempotency defect is not
   systemic across the collection, but it is present in precisely the module
   the research question is about (NFS share privilege declaration), and
   `supports_check_mode=True` is declared on a module whose check-mode
   behaviour would misreport "would change" on every run even when nothing
   would.
4. **No stated DSM version support anywhere** — no README claim
   `[SRC-SF-README]`, no compatibility note found in the files inspected, no
   CHANGELOG entry evidencing testing against a real DSM 7.2 or 7.3 box (a
   CHANGELOG.md is referenced in one commit message but was not itself
   fetched/read this session — see §6).

None of this means the collection is worthless — its `module_utils/dsm_api.py`
`[SRC-SF-API]` auth flow and its correctly-idempotent modules (`dsm_user`,
`dsm_group`, `dsm_shared_folder`, `dsm_task_scheduler`) are a reasonable
starting skeleton, and its `dsm_task_scheduler_info` module (listed in
`[GH-SF-CONTENTS]`, not itself read in full — see §6) is presumably the
read-only "does this scheduled task exist" check the fallback design (§4)
needs, matching the sibling `dsm_task_scheduler.py`'s `find_task()` pattern
which *was* read in full `[SRC-SF-TASK]`. But "reasonable skeleton from an
unreviewed single-release hobby collection with a documented fabrication
incident" is not "maintained library — use X." **Recommend: revisit at Phase
4 start, in `--check`-only mode against a non-critical DSM setting, before
trusting it for anything that writes.**

---

## 3. Authoritative source for exact API shapes: Synology's own `synology-csi`

The best evidence this session found for what the undocumented Core.Share /
FileServ.NFS APIs actually expect is **not** a third-party wrapper — it's
Synology's own official open-source Kubernetes CSI driver:

- **Repo:** `github.com/SynologyOpenSource/synology-csi`
- **License:** Apache-2.0
- **Activity:** `pushed_at` **2026-08-05T02:41:01Z** (3 weeks before this
  research), 701 stars, not archived, tagged releases up to **v1.3.1**
  (2026-07-29) `[GH-CSI][GH-CSI-TAGS]`
- This is a production Kubernetes storage driver that provisions/deletes
  Synology shares and NFS exports as PersistentVolumes — i.e., its DSM API
  calls are exercised continuously by real users' clusters, which is a
  materially stronger idempotent-behaviour and correctness signal than any
  candidate in §1–§2, even though it is not itself an Ansible artifact.

Exact API shapes read directly from `pkg/dsm/webapi/share.go`, pinned to the
commit that last touched it, `e2cc8de2fa55` (2024-08-27T15:56:44Z)
`[SRC-CSI-SHARE]`:

```
SYNO.Core.Share            get      v1   additional=["encryption","enable_share_cow","recyclebin","support_snapshot","share_quota"]
SYNO.Core.Share            list     v1   (same additional)
SYNO.Core.Share            create   v1   shareinfo=<JSON ShareInfo>
SYNO.Core.Share            set      v1   shareinfo=<JSON ShareUpdateInfo>
SYNO.Core.Share            delete   v1   name=[<sharename>]
SYNO.Core.Share            clone    v1   shareinfo=<JSON>, snapshot=<name>

SYNO.Core.Share.Snapshot   create   v1
SYNO.Core.Share.Snapshot   list     v2   additional=["desc","lock","schedule_snapshot","ruuid","snap_size"]
SYNO.Core.Share.Snapshot   delete   v1

SYNO.Core.Share.Permission set      v1   name=<share>, user_group_type=<local_user|local_group|system>, permissions=<JSON []SharePermission>
SYNO.Core.Share.Permission list     v1   name=<share>, user_group_type=<...>   -> {"items": [SharePermission,...]}

SYNO.Core.FileServ.NFS.SharePrivilege   load   v1   share_name=<share>          -> SharePrivilege{share_name, rule:[PrivilegeRule]}
SYNO.Core.FileServ.NFS.SharePrivilege   save   v1   share_name=<share>, rule=<JSON []PrivilegeRule>

SYNO.Core.FileServ.NFS     get      v2   -> NfsInfo{enable_nfs, enable_nfs_v4, nfs_v4_domain, read_size, write_size, support_encrypt_share, unix_pri_enable, ...}
SYNO.Core.FileServ.NFS     set      v2   enable_nfs=<bool>, enable_nfs_v4=<bool>, enabled_minor_ver=<int>
```
(All of the above from `[SRC-CSI-SHARE]`.)

```
SYNO.API.Auth              login    v3   (this is the CSI driver's login version, read from
                                          pkg/dsm/webapi/dsmwebapi.go, commit 4c5e192954be,
                                          2026-07-29T02:47:02Z — [SRC-CSI-DSMAPI]. MHL's existing
                                          cert-import task in provision_appliance_synology.yml
                                          uses v7 — both are accepted by DSM's version-negotiation
                                          model, but this is a second confirmed-working version
                                          number, not proof v3 and v7 behave identically for
                                          every method)
```

`PrivilegeRule` JSON shape (Go struct tags = the wire field names, from
`[SRC-CSI-SHARE]`):
```jsonc
{
  "async": false,
  "client": "192.168.255.0/24",           // host/CIDR/hostname pattern
  "crossmnt": false,
  "insecure": false,
  "privilege": "ro",                       // or "rw" — exact enum not spelled out in this source; verify live
  "root_squash": "no_squash",              // or "root_squash" / "all_squash" — enum values inferred from field name, not enumerated in source; verify live
  "security_flavor": {
    "kerberos": false,
    "kerberos_integrity": false,
    "kerberos_privacy": false,
    "sys": true
  }
}
```
`SharePrivilege` wraps this as `{"share_name": "<name>", "rule": [PrivilegeRule, ...]}`.

**This resolves a memory finding from a prior session — now with a directly
quoted, matching primary source rather than a plausible mechanism.** Memory
file `infrastructure-inventory.md` records: *"DSM Info/FileStation APIs
returned error 119 (insufficient permissions for API user)."* Three
independent, authoritative sources contradict that interpretation of code
119:

1. **Synology's own DSM Login Web API Guide**, fetched and `pdftotext`-extracted
   (PDF metadata: CreationDate 2023-04-19) `[SYN-LOGIN]` — common error code
   table lists, verbatim: `105` "The logged in session does not have
   permission," `106` "Session timeout," ... `119` "**Invalid session.**"
2. **Synology's own Synology File Station Official API guide**, fetched and
   `pdftotext`-extracted (PDF metadata: created 2021-03-22, modified
   2023-03-14) `[SYN-FS]` — its own common error code table, verbatim:
   `105` "The logged in session does not have permission," `106` "Session
   timeout," `107` "Session interrupted by duplicate login," `119` "**SID not
   found.**"
3. `synology-csi`'s own source (`pkg/dsm/webapi/dsmwebapi.go` line 95,
   `[SRC-CSI-DSMAPI]`) treats 105/106/119 together as relogin triggers, with
   an inline comment naming them explicitly: `// 105: WEBAPI_ERR_NO_PERMISSION,
   106: session timeout, 119: WEBAPI_ERR_SID_NOT_FOUND`.

So **119 = "session ID not found / invalid session," not "insufficient
permission."** (105 is the actual "no permission" code — a different number
from the one the memory note names.) A concrete, now-**confirmed** mechanism
(not merely plausible): the same File Station API guide's own worked example
shows the login call for a File Station session must carry
`session=FileStation`, verbatim from the PDF text `[SYN-FS]`:
```
http://myds.com:port/webapi/auth.cgi?api=SYNO.API.Auth&version=3&method=login&account=admin&
passwd=12345&session=FileStation&format=cookie
```
MHL's own `provision_appliance_synology.yml` authenticates today with no
`session=` parameter at all (confirmed by reading the file directly — the
login task's URL has `api=SYNO.API.Auth&version=7&method=login&format=sid`
and nothing else). A login without `session=FileStation` would produce a
`sid` valid for the base/default session but **not found** when presented to
a FileStation-scoped call — which is exactly error 119's documented meaning.
**Recommend the memory note be corrected** (not done here — this report
doesn't touch memory) to: "119 = invalid/wrong-scope session (confirmed:
`SYN-LOGIN`, `SYN-FS`, `synology-csi` source), most likely because the login
call omitted `session=FileStation` — confirmed as the documented requirement
for File Station calls, not yet confirmed as the actual cause on the live
box. Not an account-privilege problem; code 105 is the actual permission
error and was not the one returned." A live retest — adding
`session=FileStation` to the login call before a FileStation/DSM-Info probe —
would fully close this out, and wasn't done here per the ground rules (no
live Synology access this session).

**Caveat on `synology-csi` itself:** first-party origin does not mean these
are *documented, published, stable-contract* APIs — they remain internal DSM
APIs Synology has not put in a developer-guide PDF, and the CSI driver could
in principle be relying on behaviour Synology reserves the right to change.
Treat this as the best available evidence, not a stability guarantee, and
smoke-test against the live DSM 7.2/7.3 box before depending on it.

---

## 4. Fallback design — NFS self-backup + manifest (per Q11's steer)

Given §0–§3, "observe-only + capture" is still the right default for the
*whole-system* backup story, but landing point differs from the original
`RESEARCH_SYSADMIN_AGENT.md` §5 sketch (`captures/<host>/` blobs committed
into the private inventory repo) per Mike's Q11 answer: point the capture at
an **NFS path visible to the controller**, not git.

### 4.1 Mechanism

1. **DSM side — trigger + produce the backup.** Two options, in preference
   order:
   - **(a) Web API (preferred — no SSH round trip, scriptable status
     polling):** `SYNO.Backup.Config.Backup` (method/version confirmed only
     in `[SRC-N4S4-BACKUP]` — single-source, not cross-checked; this is the
     same feature as `synoconfbkp`/the DSM UI's "Configuration Backup" panel,
     exposed over HTTP):
     ```
     POST .../webapi/entry.cgi  api=SYNO.Backup.Config.Backup  method=start    version=2  _sid=<sid>
     GET  .../webapi/entry.cgi  api=SYNO.Backup.Config.Backup  method=status   version=2  _sid=<sid>   # poll until done
     GET  .../webapi/entry.cgi  api=SYNO.Backup.Config.Backup  method=list     version=2  _sid=<sid>   # get filename/id of the produced archive
     GET  .../webapi/entry.cgi  api=SYNO.Backup.Config.Backup  method=download version=2  _sid=<sid>&<archive-id-param-per-list-result>
     ```
     Exact response schema (what `list`/`status` return, and how `download`'s
     file-vs-JSON response is distinguished) is **not verified this session**
     — `[SRC-N4S4-BACKUP]`'s docstrings only name the DSM API, not the payload
     shape; this needs one live round-trip against the real Synology,
     `--check`-safe (start/list/status are non-destructive reads except
     `start` itself, which only creates a new backup file — safe to test).
   - **(b) SSH fallback**, if (a) proves gated by permissions or 2FA:
     `/usr/syno/bin/synoconfbkp export --filepath=/volume1/backups/DSMconfig.dss`
     (community-sourced syntax — `[WS-BLACKVOID]`/`[WS-3OS]`/
     `[WS-FORUM-CONFBKP]` — **not from an official 2026 doc**; verify
     `--help` output live before trusting the flag name).
2. **Where it lands.** Mike's steer: "let the systems store their own
   backups on an NFS path visible to the agent (e.g. `../HomeLabBackup`
   relative to the workspace)." Concretely: a share/export the Synology
   itself writes the `.dss` (or the API's downloaded archive) into, that is
   also NFS-mounted on the controller — e.g. a new dedicated share
   (`/volume1/HomeLabBackup` or similar; naming TBD with Mike, not decided
   here) exported to the controller's IP only, read-only from the
   controller's side. This keeps the artifact **on Synology-owned storage,
   in Synology's own backup format**, not duplicated as an opaque git blob —
   directly answering Q11's "not as blobs in git."
3. **DSM Task Scheduler entry — the thing MHL verifies exists.** Rather than
   MHL creating/owning this schedule (which would mean writing to
   `SYNO.Core.TaskScheduler`, an undocumented API, from Ansible — extra risk
   for something that only needs to run reliably on the appliance itself),
   the recommendation is: **the schedule is configured once, by hand, in the
   DSM UI** (Control Panel → Task Scheduler, or the Configuration Backup
   panel's own "Backup Settings" recurring option if DSM 7.2/7.3 exposes one
   directly — the DSM 7 config-backup KB page `[SYN-KB-CONFBKP]` documents
   the Configuration Backup panel but was only seen via a WebSearch summary
   this session, not fetched and read in full, so it did not settle whether
   it has its own recurring-schedule UI distinct from Task Scheduler —
   **verify live**). MHL's job is **read-only verification**:
   ```
   POST .../webapi/entry.cgi  api=SYNO.Core.TaskScheduler  method=list  version=3  _sid=<sid>
   ```
   (version/shape from `[SRC-N4S4-TASK]`'s `get_task_list()`, cross-checked
   against `[SRC-SF-TASK]`'s `find_task()` which uses `version=2` for the
   same `list` method — **the two sources disagree on version number**; both
   are third-party, neither is `synology-csi`-grade evidence, so treat the
   exact version as unverified until tested live, but the API name and
   method are corroborated by two independent sources). Filter the returned
   `tasks[]` array by `name` for the expected backup job; assert
   `enable: true` and a sane `next_trigger_time`. This is a `uri` GET → JSON
   filter → `assert` task, exactly the "declarable subset" pattern in §5 —
   no write, no library needed, `check_mode`-safe by construction (a GET is
   always safe).
4. **Manifest MHL records.** After confirming (via the NFS mount) that a new
   backup file landed, an Ansible task on the controller (local, no SSH)
   computes and records, per the existing registry/export conventions
   (`feedback_reuse_existing_systems.md` — derive paths from what's already
   known, don't hardcode):
   - `stat` the file at the NFS-mounted path → size, mtime.
   - `sha256sum` (or `ansible.builtin.stat` with `checksum_algorithm: sha256`)
     → hash.
   - Write `{filename, sha256, size_bytes, mtime, dsm_task_id}` into the
     inventory repo as a small YAML/JSON manifest file **per host**
     (`captures/synology/manifest.yml` or similar — exact path/schema is
     Mike's call at Phase-4 design time, not fixed here), committed to git —
     this is what Q11 asks to be tracked "there" (in the inventory repo),
     while the binary itself stays on the NFS share, never in git.
   - Drift signal: if the live file's hash/mtime doesn't match the last
     recorded manifest entry *and* no new Task Scheduler run timestamp
     explains it, that's worth a report (Phase 4 drift, or an interactive
     `/drift` check per the deferred-unattended-mode decision in Q4).

### 4.2 What this does NOT attempt

- It does not attempt to *restore* Synology config from Ansible — restore
  stays a manual DSM-UI operation (the `SYNO.Backup.Config.Restore` methods
  exist and were found in §1.2 `[SRC-N4S4-BACKUP]`, but automating a restore
  of a NAS's own identity from itself is a much higher-risk action than this
  research was asked to scope, and isn't requested by Q11).
- It does not replace the `observed` type's "declare what you can" subset —
  §5 covers what genuinely can be declared idempotently today. The manifest
  scheme is strictly for the parts that can't (bulk config state Synology
  itself doesn't expose a clean declarative surface for).

---

## 5. What IS realistically declarable via `uri` + GET/compare/SET, no library

Given §3's authoritative call shapes, this is a materially stronger answer
than a guess. All of these are plain `ansible.builtin.uri` GET (informational,
`check_mode: false`, `changed_when: false`) → Jinja compare → conditional
`uri` POST/PUT gated on `not ansible_check_mode`, matching the `api_setting.yml`
pattern already adopted elsewhere in this project (`RESEARCH_SYSADMIN_AGENT.md`
A2). None of this needs `synology-api`, `stevefulme1.synology_dsm`, or any
other library — it's the same curl-via-`command` pattern MHL's existing
`provision_appliance_synology.yml` already uses for the cert (only the cert
*upload* needs raw `curl` for the CRLF reason documented there; everything
below is plain JSON GET/POST, which `ansible.builtin.uri` handles fine).

| Setting | GET (compare) | SET (apply) | Confidence + source |
|---|---|---|---|
| NFS export privilege for a named share (e.g. `SSD_SHARE` on volume1, `Plex` on volume4) | `SYNO.Core.FileServ.NFS.SharePrivilege` `load` v1, `share_name=<name>` | `SYNO.Core.FileServ.NFS.SharePrivilege` `save` v1, `share_name=<name>`, `rule=<JSON array>` | **High** — `[SRC-CSI-SHARE]`, Synology's own production driver. Exact `privilege`/`root_squash` enum values still need one live read to confirm spelling (`ro`/`rw`? `no_squash`/`root_squash`/`all_squash`?). |
| Share-level local user/group ACL | `SYNO.Core.Share.Permission` `list` v1 | `SYNO.Core.Share.Permission` `set` v1 | High — `[SRC-CSI-SHARE]`. |
| Global NFS service enable + version (v3/v4) | `SYNO.Core.FileServ.NFS` `get` v2 | `SYNO.Core.FileServ.NFS` `set` v2 | High — `[SRC-CSI-SHARE]`. |
| Share existence/description/quota/encryption flag | `SYNO.Core.Share` `get`/`list` v1 | `SYNO.Core.Share` `create`/`set`/`delete` v1 | High — `[SRC-CSI-SHARE]`, independently corroborated by `[SRC-N4S4-SHARE]`'s `core_share.py` (same verb set: `create_folder`/`get_folder`/`list_folders`/`delete_folders`/`clone`). *(An earlier draft of this report also cited a DSM-5.1-era third-party API-definitions repo, `kwent/syno`, as a third corroborating source — that citation is retracted: the specific file 404s and the repo has no matching `definitions/` tree `[GH-KWENT-404]`. Two sources, not three.)* |
| Local user CRUD (name/description/email/expired/password) | `SYNO.Core.User` `list`/`get` v1 | `SYNO.Core.User` `create`/`set`/`delete` v1 | Medium-high — corroborated by both `[SRC-N4S4-USER]`'s `core_user.py` and `[SRC-SF-USER]`'s `dsm_user.py` (whose compare logic, unlike `dsm_nfs_share.py`, was verified correct — see §2), independently, converging on the same field names (`cannot_chg_passwd`, `expired`). Not corroborated by the first-party `synology-csi` source (out of scope for a CSI driver). |
| Local group CRUD + membership | `SYNO.Core.Group` `get_groups`/`get_permissions` (naming per the N4S4 wrapper; raw API method names not independently confirmed by a second source) | `SYNO.Core.Group` `create`/`delete`/`add_users`/`remove_users`/`set_group_info` | Medium — only one source, `[SRC-N4S4-GROUP]`'s `core_group.py`, confirmed these method names; not cross-checked against `synology-csi` or an official doc. |
| Task Scheduler existence check (read-only, per §4) | `SYNO.Core.TaskScheduler` `list` (v2 per `[SRC-SF-TASK]`, v3 per `[SRC-N4S4-TASK]`) | n/a — read-only per §4's design choice | Medium — two third-party sources disagree on version; API name/method agree. |
| DSM config backup trigger/list/status/download | `SYNO.Backup.Config.Backup` `start`/`list`/`status`/`download` v2 | (trigger is itself the "apply"; nothing to compare against — this is an action, not declared state) | Medium — one source, `[SRC-N4S4-BACKUP]`, not cross-checked; exact response/download payload shape unverified. |

**Not realistically declarable without deep reverse-engineering, this
session:** snapshot schedules, Hyper Backup task definitions (create/modify
exist as raw API calls per §1.2/§2's `[SRC-SF-NFS]`-adjacent
`dsm_hyper_backup.py` — named in `[GH-SF-CONTENTS]` but not itself read in
full this session, see §6), package presence/install (`SYNO.Core.Package`
exists per `[N4S4-DOCS-APIS]`'s classes index but wasn't inspected this
session), DSM system-wide settings beyond NFS (SMB, DDNS, 2FA, etc. —
`stevefulme1`'s module list claims modules for many of these, but per §2 none
of that collection's untested modules should be trusted without individual
verification).

---

## 6. Honest unverified list

Everything below is a documented claim (from a source cited above) that was
**not** confirmed against the live Synology (`synology.michaelpmcd.com:5001`,
DSM version/build not re-checked this session) or by running any code, or is
a claim from a source this session did not itself fetch/read in full:

- Whether `SYNO.Core.FileServ.NFS.SharePrivilege` `load`/`save` v1 works
  unchanged on this NAS's actual DSM build (7.2 vs 7.3 — the current build
  wasn't re-queried this session). Source `[SRC-CSI-SHARE]` only.
- The exact enum values for `PrivilegeRule.privilege` and
  `PrivilegeRule.root_squash` (inferred from field names and Go types in
  `[SRC-CSI-SHARE]`, not from an enumerated list anywhere in that source).
- Whether the account MHL already uses for the cert-import task (member of
  `administrators`, per `RESEARCH_SYNOLOGY_CERT_API.md`) has the application
  permissions needed for `SYNO.Core.Share`/`SYNO.Core.FileServ.NFS.*`/
  `SYNO.Core.User`/`SYNO.Core.TaskScheduler`/`SYNO.Backup.Config.Backup` calls
  specifically — administrators-group membership got the cert-import call
  through, but that's a different API family, and the `session=FileStation`
  hypothesis from §3 is confirmed as *documented DSM behaviour*
  (`[SYN-FS]`) but not yet confirmed as *the actual cause of the prior
  session's error 119* on this specific NAS.
- The exact response schema for `SYNO.Backup.Config.Backup` `list`/`status`,
  and how `download` distinguishes a binary-file response from a JSON error
  response (relevant for whether `ansible.builtin.uri` or a `curl`-via-
  `command` shell-out, à la the existing cert task, is needed). Single
  source, `[SRC-N4S4-BACKUP]`, doc comments only — the actual JSON was never
  observed live.
- Whether DSM 7.2/7.3 still ships `synouser`/`synogroup`/`synoshare`/
  `synoservice`/`synowin` unchanged from the 2021 official CLI guide
  (`[SYN-CLI]`) — only third-party 2023–2024 sources (`[WS-MARIUS]`,
  `[WS-WUSEMAN]`), surfaced via a WebSearch summary and not independently
  fetched in full, corroborate continued applicability to DSM 7. No current
  official republication was located.
- The correct `synoconfbkp` CLI flag syntax for DSM 7.2/7.3 and its restore
  counterpart — sourced only from forum/blog posts (`[WS-BLACKVOID]`,
  `[WS-3OS]`, `[WS-FORUM-CONFBKP]`), none of them Synology's own, and none
  fetched beyond a WebSearch summary.
- Whether `stevefulme1.synology_dsm`'s other ~75 modules/roles beyond the six
  actually read in full this session (`dsm_nfs_share.py`, `dsm_user.py`,
  `dsm_group.py`, `dsm_shared_folder.py`, `dsm_task_scheduler.py`,
  `dsm_api.py`) have similar or different defects. `dsm_hyper_backup.py` was
  fetched and quoted for its `DOCUMENTATION`/`EXAMPLES` blocks only (§1 of
  this report's earlier draft), not its full implementation logic — treat
  its idempotency as **unverified**, not confirmed-good, unlike the six
  modules whose `main()` logic was read end-to-end. The `dsm_task_scheduler_info.py`
  module is named in the file listing `[GH-SF-CONTENTS]` but its content was
  never fetched.
- Whether DSM 7.2/7.3's Configuration Backup panel has its own built-in
  recurring-schedule UI (separate from Task Scheduler) — `[SYN-KB-CONFBKP]`
  was only seen via a WebSearch AI-summary this session, never fetched and
  read directly, so this is weaker sourcing than most of this report and
  should be treated accordingly.
- `agaffney.synology_dsm`'s exact Galaxy release history was not independently
  confirmed the way `tafeen.synology`'s was (`tafeen` appeared by name in the
  `[GALAXY-SEARCH]` results with version numbers and dates; `agaffney` did
  not appear in that same 18-result set under a distinguishable version, only
  its GitHub repo metadata was captured via `[GH-AGAFFNEY]`) — its
  Galaxy-vs-GitHub-only distribution status is unresolved.

---

## 7. Sources

Every key used inline above, with the exact URL/endpoint, how it was fetched,
and what was observed (date/version/commit), all captured 2026-08-25 unless a
different observation date is itself the finding (e.g. a file's last-commit
date).

### Official Synology documents

| Key | URL | Fetch method | Observed |
|---|---|---|---|
| `[SYN-CLI]` | `https://global.download.synology.com/download/Document/Software/DeveloperGuide/Firmware/DSM/All/enu/Synology_DiskStation_Administration_CLI_Guide.pdf` | WebFetch (binary saved locally) + `pdftotext`/`pdfinfo` on the saved file | Title "CLI Administrator Guide for Synology NAS"; PDF metadata CreationDate 2021-03-18T04:15:51-05:00; 22 pages; `synouser`/`synogroup`/`synoshare`/`synoservice`/`synowin` syntax read verbatim from extracted text |
| `[SYN-LOGIN]` | `https://global.download.synology.com/download/Document/Software/DeveloperGuide/Os/DSM/All/enu/DSM_Login_Web_API_Guide_enu.pdf` | WebFetch (binary saved locally) + `pdftotext`/`pdfinfo` | Title "DSM Login Web API Guide"; header text "Last Apr 19, 2023"; PDF metadata CreationDate 2023-04-19T03:55:26-05:00; common error code table extracted, codes 100–150 read verbatim, including "119 ... Invalid session." |
| `[SYN-FS]` | `https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/FileStation/All/enu/Synology_File_Station_API_Guide.pdf` | WebFetch (binary saved locally) + `pdftotext`/`pdfinfo` | Title "Synology File Station Official API"; PDF metadata CreationDate 2021-03-22T22:38:23-05:00, ModDate 2023-03-14T22:56:13-05:00; 112 pages; common error code table read verbatim ("119 ... SID not found"); login worked example with `session=FileStation` quoted verbatim from extracted text |
| `[SYN-KB-CONFBKP]` | `https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/system_configbackup?version=7` | Surfaced by WebSearch; **not fetched/read directly this session** — cited only via the WebSearch result summary. Treat as weak. | Page exists per WebSearch result listing; content not independently confirmed |

### GitHub repository metadata (via `api.github.com`/`gh api`)

| Key | Endpoint | Observed (2026-08-25 unless noted) |
|---|---|---|
| `[GH-TAFEEN]` | `https://api.github.com/repos/Tafeen/ansible-synology-collection` | `pushed_at` 2023-07-13T21:28:30Z, `archived` false, license GPL-2.0, 2 stars |
| `[GH-AGAFFNEY]` | `https://api.github.com/repos/agaffney/ansible-synology-dsm` | `pushed_at` 2024-01-10T23:27:38Z, `archived` false, license MIT, 96 stars |
| `[GH-MEYAYL]` | `https://api.github.com/repos/meyayl/syno-ansible` | `pushed_at` 2021-02-07T21:44:46Z, `archived` false, no license, 6 stars |
| `[GH-SF]` | `https://api.github.com/repos/stevefulme1/ansible-synology-dsm` | created 2026-04-30T13:41:16Z, `pushed_at` 2026-06-12T14:08:04Z, `archived` false, 0 stars/forks/watchers/open-issues, `license.key` "other"/NOASSERTION at the repo-metadata level (the collection's own `galaxy.yml`/LICENSE file says GPL-3.0-or-later — see `[SRC-SF-LICENSE]`) |
| `[GH-SF-COMMITS]` | `https://api.github.com/repos/stevefulme1/ansible-synology-dsm/commits?per_page=100` | 44 commits returned on this page; key commits: `5da75e8a` 2026-05-21T14:02:42Z "fix: add GPL-3.0-or-later license value"; `a5bd1c61` 2026-05-20T23:11:46Z "audit: delete 23 fabricated stub modules, fix validate-modules finding"; `889ecc16` 2026-05-20T23:00:50Z "chore: reset version to 0.1.0 pre-release"; `4434574d` 2026-05-21T00:30:33Z "Add integration and unit tests for top 20 modules"; `a078b162` 2026-06-11T19:52:23Z "feat: add 12 info modules and improve test coverage"; most commits authored as `Test User`, a minority as `sfulmer` |
| `[GH-SF-CONTRIB]` | `https://api.github.com/repos/stevefulme1/ansible-synology-dsm/contributors` | one contributor, `stevefulme1`, 38 contributions |
| `[GH-SF-CONTENTS]` | `https://api.github.com/repos/stevefulme1/ansible-synology-dsm/contents/plugins/modules` | 83-entry directory listing (first 30 entries captured directly; full 83-item module/role/inventory list captured via the Galaxy metadata call `[GALAXY-SF-VER]` instead, which enumerates the same set with descriptions) |
| `[GH-CSI]` | `https://api.github.com/repos/SynologyOpenSource/synology-csi` | `pushed_at` 2026-08-05T02:41:01Z, `archived` false, license Apache-2.0, 701 stars |
| `[GH-CSI-TAGS]` | `https://api.github.com/repos/SynologyOpenSource/synology-csi/tags` | latest tags: v1.3.1, v1.3.0, v1.2.1, v1.2.0, v1.1.3 |
| `[GH-N4S4]` | `https://api.github.com/repos/N4S4/synology-api` | `pushed_at` 2026-08-24T14:28:40Z, `archived` false, license MIT, `open_issues_count` 7 |
| `[GH-N4S4-REL]` | `https://api.github.com/repos/N4S4/synology-api/releases` | v0.9.2 2026-08-04T13:16:52Z; v0.9.1 2026-07-03T17:41:18Z; v0.9.0 2026-05-27T22:11:49Z; v0.8.2 2025-12-08T01:48:36Z; v0.8.1 2025-05-07T10:50:48Z; v0.8 2025-02-20T10:01:17Z; v0.7.3 2024-09-28T01:56:30Z; v0.7.2 2024-03-15T00:00:17Z |
| `[GH-N4S4-158]` | `https://api.github.com/repos/N4S4/synology-api/issues/158` (human-readable: `https://github.com/N4S4/synology-api/issues/158`) | "[Feature Request] Implement TaskScheduler API" — `state` closed, `created_at` 2024-03-07T22:06:35Z, `closed_at` 2024-09-13T19:18:20Z |
| `[GH-PSDA]` | `https://api.github.com/repos/mib1185/py-synologydsm-api` | `pushed_at` 2026-08-01T10:28:32Z, `archived` false, license MIT, 32 stars, description "Asynchronous Python API for Synology DSM" |
| `[GH-PSDA-PARENT]` | `https://api.github.com/repos/hacf-fr/synologydsm-api` | `archived` **true**, `pushed_at` 2025-02-09T14:00:35Z — the older, genuinely dead predecessor/org repo that the mis-sourced original claim in §0.1 was almost certainly actually describing |
| `[GH-KWENT-404]` | `https://raw.githubusercontent.com/kwent/syno/master/definitions/DSM/5.1/5022/SYNO.Core.Share.lib` and `https://api.github.com/repos/kwent/syno/contents/definitions/DSM` | `GET` on the raw file returns HTTP 404; `repos/kwent/syno/contents/definitions/DSM` also returns `404 Not Found` from the GitHub Contents API — **claim retracted**, no content was ever actually read from this repo despite an earlier draft citing it |

### Source code read directly (raw file content, pinned to the commit that last touched the file)

| Key | File | Commit (short SHA) | Commit date |
|---|---|---|---|
| `[SRC-N4S4-SHARE]` | `https://raw.githubusercontent.com/N4S4/synology-api/master/synology_api/core_share.py` | `73a7741dc6cc` | 2026-04-27T04:52:34Z |
| `[SRC-N4S4-GROUP]` | `https://raw.githubusercontent.com/N4S4/synology-api/master/synology_api/core_group.py` | `9c9b3e9f444b` | 2026-01-05T16:34:59Z |
| `[SRC-N4S4-BACKUP]` | `https://raw.githubusercontent.com/N4S4/synology-api/master/synology_api/core_backup.py` | `160741399d72` | 2026-06-07T21:29:18Z |
| `[SRC-N4S4-TASK]` | `https://raw.githubusercontent.com/N4S4/synology-api/master/synology_api/task_scheduler.py` | `1cc0e9e4a1a8` | 2025-07-13T05:04:16Z |
| `[SRC-N4S4-USER]` | `https://raw.githubusercontent.com/N4S4/synology-api/master/synology_api/core_user.py` | `6188a435e586` | 2026-06-07T21:53:16Z |
| `[SRC-N4S4-README]` | `https://raw.githubusercontent.com/N4S4/synology-api/master/README.md` | `787fecb26af3` | 2026-06-09T21:28:46Z |
| `[SRC-N4S4-PKGLIST]` | `https://api.github.com/repos/N4S4/synology-api/contents/synology_api` | directory listing, not commit-pinned | fetched 2026-08-25; 47 files enumerated, no NFS-share-privilege-shaped module present |
| `[SRC-SF-NFS]` | `https://raw.githubusercontent.com/stevefulme1/ansible-synology-dsm/main/plugins/modules/dsm_nfs_share.py` | `a598c6215159` | 2026-05-15T18:40:13Z |
| `[SRC-SF-USER]` | `https://raw.githubusercontent.com/stevefulme1/ansible-synology-dsm/main/plugins/modules/dsm_user.py` | `7b97941d05da` | 2026-05-15T18:09:08Z |
| `[SRC-SF-SHARED]` | `https://raw.githubusercontent.com/stevefulme1/ansible-synology-dsm/main/plugins/modules/dsm_shared_folder.py` | `7b97941d05da` | 2026-05-15T18:09:08Z |
| `[SRC-SF-GROUP]` | `https://raw.githubusercontent.com/stevefulme1/ansible-synology-dsm/main/plugins/modules/dsm_group.py` | `7b97941d05da` | 2026-05-15T18:09:08Z |
| `[SRC-SF-TASK]` | `https://raw.githubusercontent.com/stevefulme1/ansible-synology-dsm/main/plugins/modules/dsm_task_scheduler.py` | `a03a56437e26` | 2026-05-15T18:59:04Z |
| `[SRC-SF-API]` | `https://raw.githubusercontent.com/stevefulme1/ansible-synology-dsm/main/plugins/module_utils/dsm_api.py` | `9b5e5b20a68d` | 2026-05-19T00:21:53Z |
| `[SRC-SF-README]` | `https://raw.githubusercontent.com/stevefulme1/ansible-synology-dsm/main/README.md` | `883248d0aae2` | 2026-05-13T02:42:42Z |
| `[SRC-SF-LICENSE]` | `https://raw.githubusercontent.com/stevefulme1/ansible-synology-dsm/main/COPYING`, `https://raw.githubusercontent.com/stevefulme1/ansible-synology-dsm/main/LICENSE` | not commit-pinned (raw fetch of current `main`) | fetched 2026-08-25; both files are the GNU GPLv3 full text |
| `[SRC-CSI-SHARE]` | `https://raw.githubusercontent.com/SynologyOpenSource/synology-csi/main/pkg/dsm/webapi/share.go` | `e2cc8de2fa55` | 2024-08-27T15:56:44Z |
| `[SRC-CSI-DSMAPI]` | `https://raw.githubusercontent.com/SynologyOpenSource/synology-csi/main/pkg/dsm/webapi/dsmwebapi.go` | `4c5e192954be` | 2026-07-29T02:47:02Z |
| `[SRC-PSDA-SHARE]` | `https://api.github.com/repos/mib1185/py-synologydsm-api/contents/src/synology_dsm/api/core/share.py` (fetched with `--jq .content \| base64 -d`; human-readable: `https://github.com/mib1185/py-synologydsm-api/blob/d4da6388815d/src/synology_dsm/api/core/share.py`) | `d4da6388815d` | 2026-06-14T13:27:12Z |
| `[SRC-PSDA-APIDIR]` | `https://api.github.com/repos/mib1185/py-synologydsm-api/contents/src/synology_dsm/api` | directory listing, not commit-pinned | fetched 2026-08-25; entries: `core`, `download_station`, `dsm`, `file_station`, `photos`, `storage`, `surveillance_station`, `virtual_machine_manager` |
| `[SRC-PSDA-COREDIR]` | `https://api.github.com/repos/mib1185/py-synologydsm-api/contents/src/synology_dsm/api/core` | directory listing, not commit-pinned | fetched 2026-08-25; entries: `external_usb.py`, `hardware.py`, `security.py`, `share.py`, `system.py`, `upgrade.py`, `utilization.py` — no `user.py`/`group.py`/`task_scheduler.py` |

### Galaxy / PyPI APIs

| Key | Endpoint | Observed |
|---|---|---|
| `[GALAXY-SEARCH]` | `https://galaxy.ansible.com/api/v3/plugin/ansible/search/collection-versions/?keywords=synology&limit=20` | 18 total results; `stevefulme1.synology_dsm` 0.1.0 (2026-05-21T14:07:22Z), `tafeen.synology` 1.0.0/1.0.1 (2023-07-12/17), `jaxzin.infra` and `brainfartlab.overlord` (unrelated collections matching the keyword) |
| `[GALAXY-SF-VER]` | `https://galaxy.ansible.com/api/v3/plugin/ansible/content/published/collections/index/stevefulme1/synology_dsm/versions/0.1.0/` | full metadata: `requires_ansible >=2.16.0`, license `["GPL-3.0-or-later","GPL-3.0-or-later"]` (duplicated in the array as returned), repository/homepage/documentation all `github.com/stevefulme1/ansible-synology-dsm`, 83-entry `contents` list (doc_fragment, inventory, modules, module_utils, roles) |
| `[PYPI-N4S4]` | `https://pypi.org/pypi/synology-api/json` | `info.version` 0.9.2, `info.license` MIT, 34 total entries under `releases` |
| `[PYPI-PSDA]` | `https://pypi.org/pypi/py-synologydsm-api/json` | `info.version` 2.10.4, latest upload_time 2026-07-08T16:48:48; 41 total entries under `releases`; `project_urls.Repository` = `github.com/mib1185/py-synologydsm-api` |

### Community / secondary sources (weaker evidence — surfaced by WebSearch, several never independently fetched beyond the search summary; flagged individually where used)

| Key | URL | How used |
|---|---|---|
| `[WS-MARIUS]` | `https://mariushosting.com/synology-basic-command-lines-for-dsm-7/` | Cited via WebSearch result title/summary only, not fetched in full — corroboration (weak) that `[SYN-CLI]`'s commands still apply to DSM 7 |
| `[WS-WUSEMAN]` | `https://github.com/wuseman/SYNOLOGY` | Same as above |
| `[WS-BLACKVOID]` | `https://www.blackvoid.club/dsm-7-backup-and-restore-your-dsm-configuration/` | Cited via WebSearch summary only — source for `synoconfbkp export --filepath=...` syntax |
| `[WS-3OS]` | `https://3os.org/infrastructure/synology/auto-dsm-config-backup/` | Same as above |
| `[WS-FORUM-CONFBKP]` | `https://forum.synology.com/enu/viewtopic.php?t=128241` | Same as above |
| `[WS-GH-SEARCH-2]` | WebSearch query "github synology ansible 2025 2026 nfs share module idempotent -tafeen -agaffney" | Confirms no additional Synology Ansible collection surfaced beyond the four in §1.1 |
| `[N4S4-DOCS-APIS]` | `https://n4s4.github.io/synology-api/docs/apis` | WebFetch (AI-summarized) — used only as a cross-reference catalog of DSM's API surface, explicitly not trusted alone for what the Python library implements (verified separately against actual source in `[SRC-N4S4-*]`) |

### Prior McHomeLab material read as input (not re-verified except where explicitly noted above)

- `research/RESEARCH_SYSADMIN_AGENT.md` §5, §9 (Q11), §11.
- `research/RESEARCH_SYNOLOGY_CERT_API.md`.
- `ansible/roles/host/tasks/provision_appliance_synology.yml` (read directly this session — the login task's exact URL, lacking any `session=` parameter, is quoted in §3).
- `~/.claude/projects/.../memory/infrastructure-inventory.md` (the error-119 memory note, corrected in §3 with the caveat that the memory file itself carries a 180-day-staleness warning).
