# Review handover — McHomeLab, 2026-08-26

For a reviewer (human or Claude) starting with a clean context. Everything you
need to audit this repo against Ansible best practice, without talking to the
person who wrote it. Written by the agent that built most of what is reviewed
here; treat its claims as claims and check them.

## 1. What this is

McHomeLab is an Ansible project that builds and runs a home lab from one
inventory file. Two git repositories:

| Repo | Path on the controller | Contents |
|---|---|---|
| `McHomeLab` (public, github.com/bzaks1424/McHomeLab) | `~/workspace/McHomeLab` | roles, `site.yml`, filter plugins, one custom module, scripts, tests, research/decision docs |
| `McHomeLab-Inventory` (private) | `~/workspace/McHomeLab-Inventory` | `hosts.yml` (single source of truth; every secret is an inline `!vault` value), `findings/`, `incidents/`, step-ca config |

The **controller** is this laptop (Ubuntu 24.04, user `mmcdonnell`). Fleet:
`util` and `media` (Ubuntu VMs running Docker Compose stacks), `unifi` (VM:
UniFi OS Server + UISP, hand-installed, observed), `synology` (DSM appliance),
`printer` (appliance). vCenter hosts the VMs.

`ansible/site.yml` has three plays: *Initialize* (localhost: sort hosts by
`priority`, load the registry), *Configure Controller* (toolchain, expiry
watch, vault escrow, UniFi objects, governance assertions, captures), *Build*
(`serial: 1`; per host: validate → facts → registry import → configure via
"BTF" dispatch on `provision.type`/`provision.manager` → export). Design and
decision record: `research/RESEARCH_SYSADMIN_AGENT.md` (§9 decisions Q1–Q13,
§12 dated execution log, §13 where things live).

## 2. Rules of engagement for the reviewer

- **Read-only.** Never run `site.yml` without `--check`. Never `ssh host`,
  `docker … exec/restart`, write-method `curl`, `unifly … create/update/delete`,
  `step ca …`. Reads are free: `docker --context <host> ps|logs|inspect`,
  `unifly … list -o json`, `ansible-inventory`, `make …` targets below.
- **Secrets.** `hosts.yml` is vault-encrypted inline; the vault password is at
  `~/.mhl/vault/mhl.pass` and the venv's `ansible.cfg` knows how to read it.
  Do not print decrypted values. `scripts/mhl-no-secrets` is the gate; run it
  on anything you write.
- **Do not edit** files to "fix" things as part of the review; report. If you
  do propose patches, put them on a branch and open a PR — `main` is protected
  by a `pre-push` git hook in both repos and the owner merges.
- Report failures verbatim (quote the output). "Verified" means you ran it.

## 3. How to run the checks (all from `~/workspace/McHomeLab`)

```
make validate      # yamllint, ansible-lint (production), syntax, offline render, no-secrets, secrets matrix, unit tests
make unit          # pytest tests/unit (86 cases; no Ansible runtime)
make restore-test  # decrypts every backup type from the NFS share into a temp dir and integrity-checks it (needs /mnt/Backups + ~/.mhl/vault/backup.pass)
make ci            # what GitHub Actions runs (lint, syntax, no-secrets, unit) — green on main since #45
cd ansible && ../.venv/bin/ansible-playbook site.yml -i ../../McHomeLab-Inventory/hosts.yml --check   # full dry run against the live lab (~4 min, reads only)
```

All were green at commit `52c3ae3` (McHomeLab) / `7230649` (Inventory) on
2026-08-26. A real apply from those commits was idempotent (0 changed).

Known `--check` artefacts (not bugs): `docker : Download Docker GPG key` shows
changed (get_url + flush_handlers under check); registry file imports are
skipped with a report when the export has not run; captures and UniFi writes
are skipped by design and reported as what they *would* do.

## 4. Map of what to review (newest first — least battle-tested)

| Area | Files | What it does | Notes for the reviewer |
|---|---|---|---|
| UniFi as code (Phase 5) | `ansible/library/mhl_unifi_firewall_policy.py`, `ansible/module_utils/mhl_unifly.py`, `roles/unifi/`, `scripts/mhl-unifi-adopt` | Name-keyed firewall policies declared under `controller.unifi.firewall_policies` in `hosts.yml`, reconciled through the `unifly` CLI (`~/bin/unifly` 0.10.0, pinned by the controller role). Upsert by `(name, source zone, destination zone)` among user-defined rules; `update` ports, `patch` enabled/logging, refuse anything else, `state: absent` deletes. | Pure `plan()` is unit-tested; `main()` is not. Live state today: 2 declared policies, both `in sync`. |
| Governance assertions | `roles/governance/`, `filter_plugins/governance.py` | "C5": no **user-defined** policy opens TCP/2376 into zone `Dmz` from outside `Internal`. Zone-pair defaults (`SystemDefined` Allow-All) that reach the port are *reported*, not asserted (owner's zone design, 2026-08-26). Reply-only allows and allows shadowed by an earlier Block are excused. | Runs every `site.yml`. Read the Jinja pipeline in `tasks/main.yml` against the plugin tests — the pipeline itself has no test. |
| Captures (Phase 4) | `roles/capture/` (controller-side: `unifi_network`, `uisp`), `roles/host/tasks/capture_appliance_synology.yml` | Pull each observed system's own backup to the NFS share `/mnt/Backups/HomeLabBackup/<system>/`, encrypted (`openssl enc -aes-256-cbc -pbkdf2`, key `~/.mhl/vault/backup.pass`), prune, `SHA256SUMS`, `latest` symlink, freshness assert. Plaintext only ever in `~/.mhl/tmp` (0700) and shredded. | UISP needs a Super Admin token (vaulted, `captures[].token`). DSM flow reverse-engineered from a HAR. UniFi controller auto-backup is monthly by decision (`max_age_days: 35`). |
| Service backups & secrets | `roles/service/` (`tasks/main.yml`, `tasks/api_setting.yml`, `templates/mhl-backup.*`, `filter_plugins/service_secrets.py`) | Compose stacks rendered from `hosts.yml`; per-service `backup:` → systemd timer, atomic encrypted tarball; `secrets:` → 0400 files + file-form env vars; `api_settings:` → idempotent GET/compare/write against app APIs; `service_retire_paths`. | The secret-rotation restart was dead code until today (#42) — check the ordering now. `api_settings` refuses non-JSON reads and unknown keys. |
| Controller role | `roles/controller/` | Pinned toolchain (step-cli .deb + sha256, unifly binary + sha256, docker CLI if the repo exists), vault dirs, docker contexts for mTLS hosts, expiry watch, hourly vault escrow (`rsync` of `~/.mhl/vault` to a Google-Drive-synced folder, mount-guarded). | Escrow mirrors plaintext key material to a cloud-synced folder — owner's decision, 2026-08-26. |
| Registry | `roles/registry/`, `filter_plugins/registry_filters.py` | Cross-host handoff (`export:`/`import:` in `hosts.yml`) through `~/.mhl/registry.json`; no hostnames hard-coded across hosts. | Check-mode-safe imports (F7). |
| Secrets tooling | `scripts/mhl-vault-file`, `scripts/mhl-no-secrets`, `scripts/mhl_secrets.py`, `scripts/tests/secrets_matrix.sh` | Vault plaintext values in place (backup outside the repo, purge after commit); gate refuses every shape the tool refuses. | Best-tested part of the repo (38-case matrix + unit tests). |
| Older roles | `roles/{host,host_provision,docker,ubuntu,apt,chrony,nfs-common,iso,xorriso,p7zip,vim-tiny,step-ca-cert}` | Provisioning (VMware ISO/PXE), OS baseline, appliance cert delivery. | Predate today's work; reviewed less. |

Retired: `archive/` (README has a row per item). The Claude Code hook
harness in `archive/governance-hooks/` is **dead code kept for provenance**;
nothing references it.

## 5. What is already known and does not need re-finding

Recorded in `research/RESEARCH_SYSADMIN_AGENT.md` §12 (2026-08-26 entries):

- Four adversarial reviews ran today (unifi; captures; service/controller;
  governance/scripts/hygiene). Every finding was fixed in PRs #42–#48.
  Highlights: C5 had excluded `filter: null` zone defaults; UniFi
  `settings.json`/`.unf` were plaintext on the share; `SHA256SUMS` was written
  before prune; DSM password rode a GET URL; secret-rotation restart was dead
  code; "not mounted" exited green in three places; CI had never been green.
- A plaintext copy of the step-ca CA keys sat on the share for ~15 h (Aug 25–26),
  left by a failed first backup design. Removed; finding closed with no
  rotation (NFS export limited to lab subnets). `McHomeLab-Inventory/findings/`.
- Process slip: PR #44 merged with a red `make validate`; fixed in #45.
- Pattern pitfalls that bit twice today: a more-indented continuation inside a
  folded `>-` scalar keeps its newline (use `|` for multi-statement shell);
  `.items` in Jinja resolves to the dict method (use `['items']`);
  `now(utc=true).timestamp()` is off by the UTC offset (use `now()`);
  a file bind-mount pins the inode, so re-templated files are invisible to a
  running container (mount the directory).

## 6. Where the author expects you to find problems

Honest self-assessment, not a steer:

1. **Error paths are untested.** `block/always` cleanup, the "refuse plaintext"
   asserts, module `main()`'s failure branches, UISP/DSM API errors mid-task.
2. **Jinja pipelines in tasks** (`roles/governance/tasks/main.yml`, the
   `service_secret_restart` computation) have no tests; only the Python behind
   them does.
3. **Check-mode honesty** across the older roles was audited by the author only.
4. **`no_log` coverage** on anything that registers a body containing a token
   or password — worth a grep-driven sweep.
5. **Portability claim** ("someone else runs this with their own inventory"):
   look for assumptions about this controller (`~/bin`, `~/.mhl`, mount
   paths, the `controller_host` name in `site.yml`).
6. **Role structure**: defaults vs vars discipline, handler use, FQCN, task
   naming, `changed_when`/`failed_when` honesty, `become` scoping.

## 7. Reporting

Rank by severity; for each: `file:line`, what is wrong, a concrete failure
scenario, a suggested fix. Separate a "cleanup" list from defects. State what
you checked and found fine. Put the report in
`research/RESEARCH_EXTERNAL_REVIEW_<date>.md` on a branch and open a PR, or
hand it to the owner as text — his call. The owner is Mike; he runs the
project and merges.
