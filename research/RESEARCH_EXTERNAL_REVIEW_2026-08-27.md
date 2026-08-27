# External review — McHomeLab, 2026-08-27

Clean-context review per `research/REVIEW_HANDOVER.md`, anchored on KISS,
SOLID and (where it pays) DRY. Read-only: nothing on the fleet, the share, or
the controller's state was changed. Every defect below was **verified** this
session — by running the code (marked *repro*) or by reading the exact lines
(marked *read*) — after an initial multi-agent finder/verifier pass. Where a
finder's claim was refuted or softened, that is said.

Baseline at `db31aa0` (McHomeLab) on 2026-08-27:

| Check | Result |
|---|---|
| `make validate` | green (`MATRIX: 38 passed, 0 failed`; `86 passed in 0.07s`) |
| `make restore-test` | green (`RESTORE-TEST: all backup types rehearsed OK`, 18 PASS lines) |
| `site.yml --check` (full, live lab) | see §4 |

## 1. Defects, ranked

### D1 — PXE provisioning is broken: the push to the PXE server was deleted (*read*)

`ansible/roles/host/tasks/provision_vm_vmware.yml:61-85` builds export entries
with `dest:` / `dest_path:` intending the registry to rsync the staged
`MAC-*.ipxe`, `user-data`, `meta-data` onto util. Commit `9fad126`
(2026-03-17, "Remove unused rsync push code from registry export") deleted the
only consumer of `dest`/`dest_path` from `roles/registry/tasks/export.yml`.
Today export only fetches to `~/.mhl/<host>/<name>`; no host imports
`pxe_ipxe_*`/`pxe_userdata_*`/`pxe_metadata_*` (grep of `ansible/` and
`hosts.yml`: zero consumers).

Every staged PXE file on this controller (`~/.mhl/pxe_staging/{bravo,unifi}`)
has an mtime between 2026-03-06 and 2026-03-12 — all before `9fad126`. The
memory "PXE autoinstall confirmed working end-to-end" is therefore stale.

**Failure:** reprovision a `provision.method: pxe` host with the VM absent →
files staged locally, nothing lands on util, VM boots to the default
netboot.xyz menu, "Wait for install completion (poweroff)" polls 60×60 s and
fails; `cleanup_pxe.yml` later `ssh … rm -f`s a file that never existed.

**Fix:** restore delivery as a proper task — a `copy`/`template` delegated to
the PXE host (inventory name, not the FQDN from the registry, so it inherits
util's connection vars; explicit `ansible_connection: ssh` because `site.yml:86-88`
forces `local` at task level in the Validate phase), or an `import:` on util
that materialises the files. Then `cleanup_pxe.yml` becomes `file: state=absent`
on the same delegation and is check-mode honest.

### D2 — Vault escrow `rsync --delete` can wipe the Drive copy of the keys (*read*)

`roles/controller/defaults/main.yml:36`:
`rsync -rti --delete ~/.mhl/vault/ <escrow>/`, guarded only by
`mountpoint -q` on the *destination* (`escrow.yml:7-19`, and the installed cron
line verified with `crontab -l`: `17 * * * * mountpoint -q … && rsync -rti --delete …`).

`toolchain.yml:55-63` creates an empty `~/.mhl/vault` *before* the `mhl.pass`
assert at `:72`. On a rebuilt controller, restoring `mhl.pass` alone and
letting the hourly cron (or "sync now", `escrow.yml:35`) run mirrors the
near-empty source into the escrow: `backup.pass`, `uisp.token`, … are deleted
there and the deletion syncs to Google Drive. Every encrypted capture and
`make restore-test` become undecryptable unless Drive's trash still holds them.
This is the exact scenario escrow exists to survive.

**Fix:** drop `--delete` (escrow is append-only by nature), or refuse to sync
unless the source contains the expected file set (`mhl.pass`, `backup.pass`).

### D3 — `governance_unshadowed` excuses a broad Allow on the strength of a narrow Block; C5 passes falsely (*repro*)

`ansible/filter_plugins/governance.py:68-90`. A later Allow is dropped whenever
*any* enabled Block/Reject on the same zone pair reaches the port and has a
lower index — ignoring the block's source filter, destination `ip_address`
scope, `connection_states` and schedule. `enabled` is tested by raw
truthiness (`p.get("enabled")`), so the string `"false"` counts as enabled.
`governance_allowing` (`:37-44`) normalises both; `unshadowed` does not.

Reproduced with the plugin loaded directly (Allow-All Vpn→Dmz at index 20000,
block at 10000):

```
narrow single-IP block       -> allow survives: False   (correct answer: True)
INVALID-only states block    -> allow survives: False   (correct answer: True)
enabled='false' string       -> allow survives: False   (correct answer: True)
```

**Failure:** a single-host block on 2376 (or UniFi's SystemDefined
"Block Invalid Traffic", which is INVALID-only) shadows a user-defined
Allow-All into Dmz; `_gov_c5_violations` is empty; "C5 holds" while every
other DMZ host is reachable on 2376.

**Fix:** a block shadows an allow only if its match set is a superset of the
allow's (same source filter or ANY, destination ANY, no `connection_states`
restriction or the allow's states ⊆ the block's, no schedule). Use the same
`enabled` normalisation as `governance_allowing`. Add these three cases to
`tests/unit`.

### D4 — Secret-rotation restart is lost if the run fails between write and restart (*read*)

`roles/service/tasks/main.yml:206-208` sets `service_secret_restart` from the
*current run's* `copy` results; `:245` restarts. Nothing is persisted, no
handler. If "Deploy compose stack" (`:235`) fails between them (image pull
timeout), the next run sees an unchanged secret file, `service_secret_restart
== []`, and the restart never happens. Compose does not recreate on
bind-mounted secret content change, so gluetun (and the tunnelled services keyed
off it at `:249`) run with the old key indefinitely while `site.yml` is green.

**Fix:** a handler with `flush_handlers` after deploy (handlers survive a later
task failure within the play only if `force_handlers: true` is set — set it),
or a pending-restart marker file written with the secret and cleared by the
restart.

### D5 — Service backups: "backup root not mounted" still exits green (*read*)

`roles/service/tasks/main.yml:95-104`: `failed_when: false` + a `debug`.
Timers install and "Run backups now" (`:145-154`, `changed_when: true`) still
starts the unit; the unit's `ConditionPathIsMountPoint` turns that into a
silent condition-skip. No freshness/existence assert exists for the service
backup dir on the share (captures and escrow both `fail`). Contradicts
`RESEARCH_SYSADMIN_AGENT.md:749` and `REVIEW_HANDOVER.md:89-90` ("not mounted
is red everywhere"). The probe also swallows `rc` outside `[0,1]` (missing
`mountpoint`, hung NFS) which `capture/main.yml:283` and `escrow.yml:12` treat
as errors.

**Failure:** `/mnt/Backups` down on util → `-e service_backup_force_run=true`
prints BACKUP ROOT NOT MOUNTED, reports *changed*, finishes green; step-ca
secrets/db snapshots silently stop until someone runs `make restore-test`.

**Fix:** same semantics as captures — `fail` when a backup is declared and the
root is not mounted; `failed_when: rc not in [0,1]` on the probe.

### D6 — `failed_when: false` makes `when: item is failed` unreachable (*repro*)

`roles/controller/tasks/main.yml:21` and the verbatim copy at
`roles/host/tasks/configure_all_all.yml:46`. Ansible's task executor rewrites
`result['failed'] = failed_when_result`, so the follow-up "Report optional
… mounts that failed" never fires. Reproduced locally:

```
failed_when: false  -> report task:  skipping  ('failed': False in the result)
ignore_errors: true -> report task:  "REPORT FIRED b"
```

**Fix:** `ignore_errors: true` (preserves `failed`), or test `item.msg is defined`.

### D7 — UniFi `.unf` encryption is not atomic; a truncated `.enc` becomes permanent (*read*)

`roles/capture/tasks/capture_unifi_network.yml:71-73` writes `openssl` output
straight to `<share>/<name>.enc` — no `.tmp` + `mv`, unlike the UISP, Synology
and settings-export paths in the same repo. The "already captured" gate
(`:61-64`) stats that same path, so an interrupted encrypt (NFS stall, Ctrl-C,
ENOSPC) is skipped forever after, then `:106-115` `ln -sfn`s `latest.unf.enc`
to the truncated file and records its sha256 in `SHA256SUMS`. The freshness
assert checks the controller's own auto-backup age, not the share copy; only
`make restore-test` would catch it.

**Fix:** `-out …enc.tmp && mv`, as the settings export already does two tasks below.

### D8 — Two-write converge in `mhl_unifi_firewall_policy` misreports on partial failure (*read*)

`ansible/library/mhl_unifi_firewall_policy.py:127-135`: `update` (ports) then
`patch` (enabled/logging); the `except` branch forces `result["changed"] =
False` before `fail_json`. If `patch` fails after `update` succeeded the
controller was mutated and the run says it was not.

**Fix:** track `mutated = True` after each successful write and report it in
`fail_json`. Secondary, from `plan()` and **not independently verified**:
`state: absent` matches on `(name, src zone, dst zone)` only, so a hand-made
policy with the same name and zones would be deleted regardless of action/ports.

### D9 — `api_setting.yml`: unchecked `json_query` result; `| string` comparison (*read*)

`roles/service/tasks/api_setting.yml:57`: `_api_actual` is the raw
`json_query(item.read.path)` result. The compare loop at `:63-70` indexes it
before the mapping assert at `:71-74`, under `no_log: true`. A `None` (app
renamed the section) raises `'NoneType' has no attribute keys` with a redacted
message instead of the designed `allow_absent` refusal; a list-valued path
marks every key `<absent>` and POSTs every run. `:68` compares `| string`, so
`want: {max_ratio: 2}` vs an API returning `2.0` rewrites every run (latent —
no float wants in `hosts.yml` today).

**Fix:** assert `_api_actual is mapping` right after `:57`; compare with a
type-aware test (`== entry.value` after `| from_yaml`-style normalisation, or
compare `| float` when the actual is a number).

### D10 — wud/gluetun templates reference secrets that are only conditionally declared (*read*, softened)

`roles/service/templates/wud.yml.j2:42-44` uses `wud_mqtt_url` /
`wud_mqtt_user` unconditionally (no default exists in the role) and
`/run/secrets/wud_WUD_TRIGGER_MQTT_HA_PASSWORD` which
`service/vars/main.yml:73-78` only adds when `wud_mqtt_password` is defined.
`gluetun.yml.j2:19/28` are gated on `vpn_type` but the matching secret entries
(`vars/main.yml:62-72`) are gated on the *value* being defined.

The finder called this "silent"; it is not — a wireguard gluetun without a
private key fails at `docker compose config` ("service refers to undefined
secret"), and wud without `wud_mqtt_url` fails as an undefined variable. It is
a **portability/UX** defect: the role's intended named refusal never fires,
and `tests/render.yml` never exercises either service without its secrets.

**Fix:** one `assert` per infra service listing its required vars, before
templating.

## 2. Cleanup (KISS / SOLID / DRY) — not defects

1. **Backup finalize pipeline ×4, already drifted.** `capture_uisp.yml:217-228`,
   `capture_appliance_synology.yml:124-135`, `capture_unifi_network.yml:106-115`,
   `service/templates/mhl-backup.sh.j2:20-28`. The service one writes
   per-file `.sha256` and no `SHA256SUMS`, so `scripts/mhl-restore-test` knows
   four layouts. → one shared task file / `mhl-backup-finalize` script.
2. **Mount guard ×6 with three semantics** (fail / fail-if-declared /
   debug-and-continue — D5 is one of them), and the share/key path re-defaulted
   as `capture_root`, `host_capture_root`, `service_backup_root`,
   `capture_key_path`, `host_capture_key_path` plus literals in
   `mhl-restore-test:8-9`. → one `all.vars` `backup_root`/`backup_key_path`
   and one `require_mounted.yml`.
3. `roles/controller/tasks/main.yml:1-30` is a verbatim copy of
   `roles/host/tasks/configure_all_all.yml:12-46` — which is why D6 exists twice.
4. **C5 hard-codes `Dmz`/`Internal`/`"2376"`** (`governance/defaults/main.yml:11-13`)
   while `docker_remote_api_port` lives in `roles/docker/defaults/main.yml:34`
   and is a literal again in `controller/tasks/toolchain.yml:90`. The Jinja
   pipeline in `governance/tasks/main.yml:20-45` parses the policy JSON three
   times and has no test. → one `governance_c5(policies, zones, port, …)`
   filter with fixtures; the task becomes one call.
5. **Portability:** `controller_host: "controller"` in `site.yml:18` and the
   `/util/root_ca_cert` fallback in `controller/defaults/main.yml:24`
   contradict the no-hard-coded-hostname claim.
6. **Repeated I/O:** every declared policy re-lists zones and policies
   (`mhl_unifi_firewall_policy.py:113-114`); governance lists both again
   (2N+2 unifly sessions per run). `registry.json` is rewritten once per host.
   Expiry watch and escrow "sync now" run unconditionally, including `--check`.
7. `toolchain.yml:21-22 / 27-28` paste the same 150-char `step version` lookup
   as two `when:` clauses. String-match `changed_when` at `escrow.yml:39` and
   `toolchain.yml:109` (docker-context "unchanged" compares only
   `.Endpoints.docker.Host`, not ca/cert/key — plausible stale-context if
   `export_root` moves; not verified).
8. `capture_unifi_network.yml:89-115`: three share-writing shell tasks are
   `changed_when: false` and ungated — every apply re-encrypts settings with a
   fresh salt and rewrites `SHA256SUMS` while reporting ok. `/drift` and apply
   summaries under-report.
9. **Dead code:** `roles/host/vars/main.yml:15-21` (`host_docker_*`,
   `host_ssh_known_hosts_path`), `controller_iso_root`, the `include_vars:`
   pseudo-key in `group_vars/all/main.yml:2-3`, `roles/podman` +
   `roles/slirp4netns` (only consumer archived) — still linted every
   `make validate`.
10. `Makefile` `syntax` parses `tests/render.yml`, not `site.yml`, while
    `.ansible-lint.yml:35` excludes `site.yml` "covered by make syntax"; `check`
    is in neither `validate` nor `ci`. (Read only; not exercised.)
11. `host_provision/tasks/cleanup_pxe.yml:5-10` shells `ssh … rm -f` (always
    changed, invisible in `--check`). Moot until D1 is repaired; fix together.
12. **Infra services are a closed set:** `service/vars/main.yml:55-78`
    hand-enumerates gluetun/wud secrets; the restart cascade keys on the
    literal `'gluetun'` at `tasks/main.yml:249`. (Open/closed.)

## 3. Checked and found fine

No `--limit` outside archive/prose. `Makefile` and `.claude/skills/*` invoke
only read-only or `--check` fleet commands. `.claude/settings.json` allow-list
has no write-method fleet commands. Every `archive/` entry has a README row.
`ansible/collections/` is not committed. `host_provision_pxe_server` is
registry-derived, not a literal. `scripts/mhl-restore-test` does **not** abort
on a dangling `latest` symlink (a finder claimed `readlink -f` returns non-zero;
refuted by test — GNU `readlink -f` returns 0 on a missing final component).
`make validate` and `make restore-test` green as tabled above.

## 4. Live `--check` run

Full `site.yml --check` against the live lab, 2026-08-27 (exit 0):

```
controller : ok=66  changed=0  failed=0  skipped=33
localhost  : ok=11  changed=0  failed=0  skipped=3
media      : ok=74  changed=2  failed=0  skipped=50
printer    : ok=7   changed=0  failed=0  skipped=7
synology   : ok=13  changed=0  failed=0  skipped=17
unifi      : ok=51  changed=1  failed=0  skipped=43
util       : ok=66  changed=2  failed=0  skipped=27
```

The five `changed` are: `docker : Download Docker GPG key` ×3 (the known
check-mode artefact) and `ubuntu : Apt upgrade -y` on **util and media** —
that one is real drift (pending package updates on both VMs; unifi was `ok`).
C5 reported `C5 holds … (136 policies checked)` and the design note "zone
defaults allow TCP/2376 into Dmz from Gateway, Vpn". Note that D3 means this
"holds" is currently evaluated by a shadow rule that can be fooled; on today's
live policy set the two declared policies are in sync and no narrow block
exists on the relevant pairs, so the verdict is believed correct for today's
data — but the check does not prove it.

## 5. Not done

- No apply, no fleet writes, no share writes, no edits to any file outside this
  report.
- D8's `state: absent` matching and cleanup item 10 (`Makefile syntax`) were
  read, not exercised.
- `main()` of the module and every `block/always` cleanup path remain untested
  (the handover's own §6.1); this review did not add tests.
