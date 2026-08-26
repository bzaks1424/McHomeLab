# RESEARCH: The McHomeLab sysadmin agent ("BM") — governance, baseline, architecture, phases

**Date:** 2026-08-24
**Status:** RESEARCH + DECISION PLAN — expands `RESEARCH_ANSIBLE_GOVERNANCE.md`
(which remains the ideology anchor; §0 there is binding and is not restated
differently here). Nothing in this document has been implemented. §7 lists the
questions that block implementation; §8 is the decision record to be filled
in once they are answered.
**Written for:** a fresh session. Read `RESEARCH_ANSIBLE_GOVERNANCE.md` §0
first, then this file end to end.

Research method this session: five parallel investigations — (1) a full
feature inventory of the repo + inventory, (2) a full read of the
`~/workspace/claude` hook precedent and the McHomeLab `.claude/settings.json`,
(3) web research on secrets/testing/lint/drift/pinning, (4) local + web
research on UniFi/Synology/UISP/vCenter/iDRAC/printer as-code, (5) web
research on current Claude Code hooks/permissions/subagents/headless/SDK.
Every claim marked **verified** was checked against a live doc or the live
repo/controller today. Anything else is labelled.

---

## 1. The goal, stated precisely

Produce a sysadmin agent that runs McHomeLab under the ideology of
`RESEARCH_ANSIBLE_GOVERNANCE.md` §0: **no change to any part of the home
environment that is not reproducible from committed history**, while
retaining **every feature and function MHL performs today** (§2 below is the
contract for that), and migrating away from *some* of the old Ansible where
it is dead, procedural, or stubbed — never from the provisioning abstraction,
the registry, or the service (compose) generator, which are the product.

The agent has three modes, all governed by the same rules:

| Mode | Who drives | What it may do |
|---|---|---|
| **Interactive** | Mike at the keyboard | Everything, gated by hooks + per-run confirmation on applies/commits |
| **Unattended** | systemd timer on the controller | Read-only: drift check (`--check --diff`), cert/credential expiry, backup-artifact capture, report + notify. Never applies. |
| **Emergency** | Mike, explicitly invoked | **Undefined until §7 Q1 is answered.** |

---

## 2. Feature baseline — what the agent must keep doing (verified 2026-08-24)

This is the "you are still responsible for all of it" contract. Anything in
this table that a migration phase touches must come out the other side still
working, with a test that proves it.

### 2.1 Lifecycle engine (keep — this is the product)
- `site.yml` 3-play structure: Initialize (build_hosts sorted by `priority`,
  registry init) → Controller → Build (`serial: 1`, per host: Validate (local)
  → facts → Import → Configure (BTF) → Export). Appliances get
  validate→provision only, never import/configure/export.
- BTF dispatch: `{action}_{type}_{manager}.yml` → `{action}_{type}_all.yml`
  → `{action}_all_{manager}.yml` → `{action}_all_all.yml` → `{action}.yml`.
  **Hazard (verified):** the final fallback is the caller itself → infinite
  include if any `*_all_all.yml` is removed. A migration must add a guard.
- Registry: `~/.mhl/registry.json`; file exports fetched to
  `export_root/{host}/{name}`; var exports inline; required/optional imports;
  stale-file purge on init; `registry_get` / `inventory_entry` filters.
- Provisioning: `provision_vm_vmware.yml` (create VM → MAC → `host_provision`
  → PXE assets pushed via registry export override → power on → wait for
  autoinstall poweroff → cleanup); `host_provision` methods `iso` and `pxe`
  (netboot.xyz v3 per-MAC gate, Ubuntu autoinstall `user-data.j2` with LVM
  layout from `mounts`). Appliance provisioning: Synology cert import
  (`curl` multipart — `uri` mangles PEM), HP printer PFX upload (`openssl
  pkcs12` + `curl`).
- `step-ca-cert` role: controller-side `step ca certificate` with
  `needs-renewal` gate; reused by docker TLS, WUD client certs, appliances.
- `service` role: compose generation from `services:` — infra templates
  (traefik, gluetun, wud), regular services with traefik shorthand
  (`dns_name`/`routes`/`rule`), gluetun-tunneled services, labels
  passthrough, bind-mount pre-creation, `docker_compose_v2` with
  `remove_orphans: true` and `service_pull_policy`. WUD mTLS remote watchers.
- OS roles: `ubuntu` (dist-upgrade every run, sudoers, editor), `apt` proxy
  with rescue, `ca-certificates` (`update-ca-certificates` with `creates:` —
  **won't re-run on CA content change**, known gap), `chrony`, `rsyslog`
  (UDP forward), `docker` (repo, daemon.json, optional TLS listener 2376,
  first-run restarts every container), `nfs-common`, `controller` NFS mounts,
  `iso` (download + 7z), trivial apt roles.
- Inventory-managed side files delivered via registry: 5× homepage YAML,
  `recyclarr.yml`.

### 2.2 Hosts and external systems in scope today
controller (local), util (vm/vmware/iso, 192.168.254.3), synology (appliance,
cert), printer (appliance, cert), media (vm/vmware/pxe, DMZ .255.34, dockerd
mTLS), unifi (vm/vmware/pxe, DMZ .255.35, dockerd mTLS, traefik external
routes to UISP + UniFi OS Server). External systems touched: vCenter,
Synology DSM API, HP EWS, step-ca, NFS, SSH, Docker remote API, GitHub (LSCR
PAT), HA MQTT (WUD notifications).

### 2.3 Known dead / stubbed / procedural Ansible (migration candidates)
| Item | State (verified) | Proposed disposition |
|---|---|---|
| `roles/uisp` | installer execution commented out; `_uisp_installer_args` Jinja syntactically broken | Either finish (idempotent install + `uri`-declared settings) or retire to `archive/` with the manual install documented as an appliance-style "observe + backup" entry. **Ask (Q6).** |
| `roles/unifi-os` | run + systemd enable commented out | Same as above. |
| `host/tasks/configure_container_docker.yml` | unused by inventory | Retire to `archive/`. |
| `host_provision` `iso` method | ISO never rebuilt once present (xorriso has no `creates:` and is guarded only by a stat) | Keep; add content-hash guard. util still uses it. |
| `roles/host/vars/appliance.yml` | hardcoded `export_root/util/…` paths (registry-convention violation) | Fix to `registry_get`. |
| `roles/rsyslog` | vendor name baked into a generic role (`90-synology.conf`); silent placeholder default `syslog.example.com` | Rename + fail-if-undefined. |
| `roles/ca-certificates` | `creates:` guard misses CA rotation | Hash-compare guard. |
| `roles/docker` | `refresh_inventory` used where `reset_connection` intended | Fix. |
| `roles/chrony` | TODO connectivity check; dead `chrony_proxy_check_*` vars | Clean. |
| Inventory literals | `plex.ADVERTISE_IP`, WUD `remote_watchers[].host`, appliance `cert.ca_url` duplicating `step_ca_url`, netbootxyz route embedding `192.168.254.3`, media `dns.servers` = MGMT gateway (breaks DNS=gateway convention) | Derive from registry / hostvars; fix media DNS. |
| Inventory repo cruft | `hosts.yml.bak` (stale Feb v2), `README.md` (stale Semaphore-era TODO), `seedpool.api.key` (mode 755, unreferenced) | Archive / delete on repo init. **Ask (Q2).** |
| Secret duplication | step-ca provisioner password in 4 places; ARR API keys in both homepage and recyclarr files; `DOCKER_STEPCA_INIT_PASSWORD` in compose env | Single vaulted value referenced everywhere; compose secrets land in 0644 files today — see §4.4. |

### 2.4 Ad hoc state the ideology does not yet cover (from MIGRATION_PLANS + memory)
- bazarr Sonarr/Radarr addresses (set via bare `ansible localhost -m uri`).
- qBittorrent `current_network_interface=tun0` (manual one-shot API call).
- `docker context media` / `docker context unifi` on the controller.
- `step` CLI on the controller installed by hand.
- WUD forced scans via raw `wget --post-data`.
- LSCR GitHub PAT expiry ~2027-08-24 (a comment, nothing checks it).
- The C5 non-decision (no compensating firewall rule for dockerd mTLS).

---

## 3. Findings — Track A (Ansible practice), verified against current docs

**A1 Secrets → recommendation: `ansible-vault` inline `!vault` values, one
vault-id (`mhl`), password from a `*-client` script.**
- `community.sops` 2.4.0's vars plugin only decrypts `group_vars/`/`host_vars/`
  files, **not an inventory file** — adopting it means splitting secrets out
  of `hosts.yml`, contradicting "hosts.yml is the single source of truth".
- Inline `!vault` keeps keys plaintext → `git diff` shows *which* secret
  changed, same as sops. Whole-file vault is rejected (opaque diffs).
- Password source: ansible-core calls any executable named `*-client` with
  `--vault-id <label>`; `vault_identity_list = mhl@scripts/mhl-vault-client`
  in `ansible.cfg`. Backing store options (**Q3**): `pass` (gpg), OS keyring,
  or a 0600 file outside both repos.
- ansible-lint honours `vault_identity_list`/`ANSIBLE_VAULT_PASSWORD_FILE`;
  yamllint in VS Code flags `!vault` tags (known cosmetic issue).
- Gap: no in-place edit for a single inline value; a small wrapper around
  `ansible-vault encrypt_string` closes it.

**A2 Idempotent API tasks ("bazarr pattern")** — no upstream convention;
standardize on a role-local task file `api_setting.yml` = GET → compare →
conditional PUT/POST with `changed_when` on the write and `check_mode`
handling (`uri` is **skipped in check mode**, so the GET must set
`check_mode: false`, `changed_when: false`, and the write must be
`when: not ansible_check_mode` with a reported would-change diff). One
shared task file, per-app payload dicts in `hosts.yml`.

**A3 Testing → recommendation: no Molecule.** Molecule is maintained
(v26.8.0, 2026-08-12) but Docker/Podman drivers live in `molecule-plugins`
and the repo's roles are VM-lifecycle/NFS/PXE shaped; the `delegated` driver
against a throwaway VM is the only honest fit and adds weight without
catching the bugs we actually hit. Module check/diff support (verified from
docs): `template` full/full; `docker_compose_v2` check full, **diff none**;
`x509_certificate` check full, diff undeclared; **`uri` check none (skipped)**.
Test ladder to commit as `make validate`:
1. `ansible-inventory --list` (proves vault + parse) + `--syntax-check`.
2. `yamllint` + `ansible-lint --profile production --offline`.
3. Render-only playbook (`ansible_connection: local`) templating every
   compose/traefik/gluetun/wud/autoinstall file to scratch, then
   `docker compose -f … config -q` per host — formalizes this session's
   scratch pattern (**C3**).
4. `ansible-playbook --check --diff site.yml` against the live fleet as the
   pre-apply gate and the unattended drift probe.
5. Hook test script (mirrors `test_hooks.sh`).

**A4 Drift → controller-side systemd timer running step 4 read-only, plus a
compose-level probe:** compare `docker compose config --hash '*'` of the
rendered file vs the running containers'
`com.docker.compose.config-hash` label (or `docker compose up -d --dry-run`).
Pull model (`ansible-pull`) rejected: `serial: 1` + registry cross-deps and
the no-`--limit` rule. ARA 1.8.0 could record run history; optional.
Extend to credentials/certs: a read-only "expiry" task listing every cert the
fleet serves + the LSCR PAT + AirVPN key age, emitted in the same report.

**A5 Lint → `production` is the strictest profile that exists** (min →
basic → moderate → safety → shared → production); nothing above it. Bump
now; add opt-in rules via `enable_list` (e.g. `jinja2-template-extension`).

**A6 Non-native systems** — see §5.

**A7 Pinning → `requirements.yml` with `==` pins is the lockfile; no
lockfile feature exists in ansible-core 2.19–2.21** (verified changelogs).
Install with `-p ./collections --force`, `collections_path = ./collections`
in `ansible.cfg`, and add `ansible-galaxy collection list` to `make validate`.
Currently unpinned and used: community.vmware 5.10.0, vmware.vmware 2.4.0
(2.9.0 upstream; the declarative `vmware.vmware.vm` module needs ≥2.5),
community.docker 4.8.2, community.general 11.4.1, community.crypto 3.0.5,
ansible.posix 2.1.0. Also unmanaged controller prerequisites: `step`,
`xorriso`, `7z` — should become a `controller` role responsibility.

---

## 4. Findings — Track B (Claude Code harness), verified against current docs

### 4.1 Precedent (`~/workspace/claude`, read in full)
Four hooks + SessionStart context injector; every hook exits 0 and
expresses deny purely via JSON; `test_hooks.sh` keeps payloads inside the
script so testing the guards doesn't trip them; `stop_gate.sh` fails open
once per day ("a reminder that can loop is a reminder that gets disabled");
`validate.sh` sets `CLAUDE_WS_VALIDATING=1` to break hook→validate
recursion. The no-secrets regex only matches **double-quoted** values ≥24
chars after a credential-shaped key, or JWTs — it would miss unquoted YAML
(`api_key: abc…`) and must be widened for `hosts.yml`.

### 4.2 Current McHomeLab `.claude/settings.json` (verified)
876 `permissions.allow` entries, no `hooks`, no `deny`, no `ask`. 339 are
`Bash(ssh …)` one-offs (183 to media), 232 embed remote `docker exec/logs/
restart/stop`; 39 end in a bare `:*` prefix wildcard including
`Bash(ssh media.michaelpmcd.com:*)`, `Bash(ssh util.michaelpmcd.com:*)`,
`Bash(python3:*)`, `Bash(git commit:*)`. Destructive commands are
allow-listed verbatim (`ssh media … sudo rm -rf …`). **One entry embeds a
literal Plex token.** Three entries grep API keys out of config.xml. This
file is untracked and should be replaced wholesale, not pruned (**Q9**).

### 4.3 Mechanism facts that shape the design
- Permission evaluation order is **deny → ask → allow**, first match wins;
  deny rules apply in every mode including `bypassPermissions`; allow lists
  *merge* across user/project/local scopes (a project file cannot cancel a
  user-level allow — keep `~/.claude/settings.json` free of Bash allows).
- `PreToolUse` hook JSON contract confirmed current:
  `hookSpecificOutput.{permissionDecision: allow|deny|ask,
  permissionDecisionReason, updatedInput}`. Exit 2 = hard block. Hooks are
  "enforced by Claude Code, not by the model"; CLAUDE.md/rules are context
  only.
- `.claude/rules/*.md` exists (same priority as CLAUDE.md, optional `paths:`
  frontmatter to scope a rule to files being touched).
- Subagents (`.claude/agents/*.md`) can carry their own `tools`,
  `disallowedTools`, `permissionMode`, `maxTurns`, and **their own hooks**.
  Skills can set `disable-model-invocation: true` so only a human can
  trigger them — exactly right for `/apply-site`.
- Headless: `claude -p --permission-mode dontAsk --allowedTools … --max-turns
  … --max-budget-usd … --output-format json --json-schema …`. Project hooks
  and `.mcp.json` load in `-p` when the folder is trusted; `--bare` skips
  them (and needs an API key). Cloud routines (`/schedule`) run in
  Anthropic's cloud with no local access → **ruled out**. Desktop scheduled
  tasks need the desktop app open → ruled out for the controller.
- Agent SDK (Python) adds a `can_use_tool` callback for mid-run human
  approval and in-process custom tools, but requires API-key billing.
- Sandbox (bubblewrap) exists on Linux; whether it permits SSH to raw LAN
  IPs is **unverified** — test before relying on it.

### 4.4 A finding the ideology forces: secrets in rendered artifacts
Rendered `docker-compose.yml` on media contains the AirVPN WireGuard keys,
`PLEX_CLAIM`, and on util `DOCKER_STEPCA_INIT_PASSWORD`, all in a 0644 file
on an NFS-backed or local path. That is *derived* state (fine to be
unrevisioned) but it is not *protected*. Options: compose `secrets:` with
files rendered 0600, or `env_file` 0600. This is not blocking but belongs in
Phase 3.

---

## 5. Findings — external systems as-code (verified 2026-08-24 unless noted)

| System | Verdict | Engine | Committed artifact |
|---|---|---|---|
| UniFi VLANs / firewall zones+policies / DNS policies / traffic lists / ACLs | **declarable with work** | Integration API v1 via `unifly … --from-file` or `uri`; **no create-or-update exists** → name-keyed reconcile loop (list → branch → update `<id>` or create); `firewall policies reorder --get/--set` for ordering | `unifly … list --all -o yaml` snapshot + `system backup download` (.unf) |
| UniFi DHCP reservations | declarable with work | `unifly clients set-ip` (legacy session API only; effectively idempotent) | `clients reservations -o yaml` |
| UniFi NAT policies | **not available** — `nat/policies` returns 404 on this controller (Network 10.1.84) | — | — |
| UniFi via Terraform | possible but rejected as default: `paultyng/unifi` archived 2026-04-30; `filipowm/unifi` 1.1.0 and `badgerops/unifi` 0.2.15 active but churning; adds state (plaintext secrets) as a second source of truth | — | — |
| Synology cert | declarable now (exists) | `provision_appliance_synology.yml` | — |
| Synology shares / NFS / users / tasks | **observe-only + backup** | `SYNO.Core.*` undocumented; `synology-api` lib last release 2024-08 | `synoconfbkp export` `.dss` (binary, opaque) |
| UISP | observe-only + backup (NMS settings declarable via `PUT /nms/api/v2.1/nms/settings` if wanted) | `uri` | `POST /nms/backups/create` + download |
| vCenter VMs | declarable now (exists, `community.vmware.vmware_guest`) | upgrade `vmware.vmware` ≥2.5 for the declarative `vm` module (check_mode) | hosts.yml |
| vCenter portgroups / vSwitch | declarable now | `community.vmware.vmware_(dvs_)portgroup`, `vmware_vswitch` (idempotent, check_mode) — *not yet in inventory* | hosts.yml |
| HP printer | declarable now (cert only); nothing else has an API | exists | — |
| iDRAC8 (R630, fw 2.83) | observe-only + backup — `dellemc.openmanage` supports iDRAC9/10 only; Redfish cert actions 405; cert upload only via `racadm` (deferred 2026-03-17) | `racadm` | SCP XML export (untested on this firmware) |

Design consequence: the inventory schema gains a **fourth provision type**
beyond `vm`/`appliance`/`controller` — call it `observed` — whose lifecycle
is validate (reachability + cert) → **capture** (pull the backup artifact
into the inventory repo) → no configure. That gives Synology/UISP/iDRAC a
revisioned artifact without pretending they are declarable.

---

## 6. Target architecture — the sysadmin agent

### 6.1 Repos (three, each revisioned)
1. `McHomeLab` (public-safe: roles, site.yml, tests, hooks, agent definition,
   `requirements.yml`, `.claude/settings.json` now **tracked**).
2. `McHomeLab-Inventory` (private: `hosts.yml` with inline `!vault` values,
   side files, `captures/` for observe-only backup artifacts, `unifi/`
   payloads). Location: **Q2**.
3. `~/.mhl` stays derived + `.gitignore`-style excluded; anything in it that
   is not regenerated output (docker contexts, the vault client's store) gets
   a role that creates it.

### 6.2 Files the agent is made of (all in `McHomeLab`)
```
CLAUDE.md                       # project-level binding rules (today there is none)
.claude/rules/governance.md     # ideology as directives; paths-scoped rules for hosts.yml
.claude/settings.json           # curated: deny/ask/allow + hooks registration (replaces 876-entry file)
.claude/hooks/guard_bash.sh     # PreToolUse[Bash]: deny ad-hoc mutation of lab hosts
.claude/hooks/guard_writes.sh   # PreToolUse[Write|Edit]: deny edits to derived paths (~/.mhl, rendered files)
.claude/hooks/check_edit.sh     # PostToolUse: yamllint/ansible-lint the touched file
.claude/hooks/stop_gate.sh      # Stop: make validate green + memory touched, fail-open once/day
.claude/hooks/session_context.sh# SessionStart: git state of both repos, last drift report age
.claude/agents/drift-checker.md # read-only subagent, own hooks, dontAsk
.claude/agents/renderer.md      # render-only subagent
.claude/skills/apply-site/      # disable-model-invocation: true — human-only apply
.claude/skills/drift/           # /drift → check --diff + compose-hash probe → report
scripts/hooks/test_hooks.sh
scripts/validate.sh             # the green/red check
scripts/mhl-vault-client        # vault password source
tests/render.yml                # render-only playbook
systemd/mhl-drift.{service,timer} # unattended mode (installed by the controller role)
```

### 6.3 `guard_bash.sh` — rule set (deliberately narrow)
Deny:
- `ansible <host> -m (shell|command|raw|script|uri|copy|file|template|lineinfile|blockinfile)` where host ≠ `localhost`.
- `ssh <lab-host> …` whose remote command contains a mutating verb
  (`docker (exec|restart|stop|start|rm|compose up)`, `sudo (rm|tee|systemctl restart)`, `>`/`>>` redirect, `sed -i`, `apt`, `mv`, `cp`).
- `docker --context <host> (exec|restart|stop|rm|compose)`.
- `curl|wget` with `-X (POST|PUT|PATCH|DELETE)` / `--post-data` / `-d` to a `*.michaelpmcd.com` or `192.168.*` host.
- `step ca certificate` outside `ansible-playbook`.
- `ansible-playbook … --limit` (existing rule).
- `ansible-playbook site.yml` without `--check` when `git -C <either repo> status --porcelain` is non-empty for `roles/`, `site.yml`, `hosts.yml` (**B3 — Q9 asks whether to enforce or only warn**).
- `docker context create` (must come from the controller role).
Allow (never block): `docker ps|logs|inspect|stats`, `ansible -m (setup|ping|debug)`, `curl` with no method or `-X GET`, `ssh host "cat|grep|ls|systemctl status|journalctl"`, `unifly … list|show|export`, all `git` reads.
Ask (not deny): `git commit`, `git push`, `ansible-playbook` without `--check`.

### 6.4 Interactive loop the agent runs (the "how it works")
1. Read live state (permitted freely).
2. Decide a change → **express it as a diff to `hosts.yml` or a role**, never
   as a command.
3. `make validate` (lint, render, syntax) → `ansible-playbook --check --diff`.
4. Show the diff; ask; commit both repos (inventory first).
5. `/apply-site` (human-invoked) → `site.yml` → post-apply verification reads.
6. Record decision in the document of record; memory; stop gate green.

### 6.5 Unattended mode
`systemd` timer on the controller: `claude -p "/drift" --permission-mode
dontAsk --allowedTools Read Grep Glob "Bash(ansible-playbook * --check --diff *)"
"Bash(docker --context * inspect *)" … --max-turns 20 --max-budget-usd 2
--output-format json --json-schema drift.json` → JSON report under
`~/.mhl/reports/`, summary committed to the inventory repo's `captures/`,
notification on drift or failure via HA `notify` (deterministic, in the
wrapper script, not the model). **Unverified:** subscription login under a
TTY-less systemd unit; **Q4** covers billing/auth.

### 6.6 What "BM" does and does not write
Memory says BM "never writes/modifies playbooks — inventory-only changes,
proposes new capabilities to Mike". This document's phases require writing
roles. Reconciliation proposed: the *unattended* agent never writes anything
but reports; the *interactive* agent may write roles and inventory, gated by
hooks + validation + Mike's commit confirmation. **Q5 confirms.**

---

## 7. Open questions — answer before Phase 0

Numbered for reference. Recommendations given where I have one.

**Q1 — Emergency exception (§0.5 of the governance doc, still unanswered).**
Options: (a) zero exceptions, codify-first always; (b) a named emergency
mode: the agent may take a manual action to restore service *only after*
writing a dated `INCIDENT-<date>.md` in the inventory repo stating the
action, and the next session's stop gate blocks until the action is codified
or the incident is explicitly closed as "not to be codified". Recommend (b) —
(a) will be violated the first time Plex is down at 9pm, and a violated rule
enforces nothing.

**Q2 — Where `McHomeLab-Inventory` lives.** (a) local-only git repo (history
but no off-box copy — fails the "raise from the dead" test if the controller
dies); (b) private GitHub remote with vaulted secrets (recommended — same
account as McHomeLab, `bzaks1424`); (c) a bare remote on the Synology.
Also: may I delete `hosts.yml.bak`, the stale README, and the unreferenced
`seedpool.api.key` on init, or archive them?

**Q3 — Vault password backing store.** `pass` (gpg key on the controller),
system keyring, or a 0600 file at `~/.mhl/vault/mhl.key` outside both repos?
And: is the vault password itself allowed to live in your password manager
as the single recovery root? (It has to live *somewhere* not in git.)

**Q4 — Unattended mode: yes/no now, and auth.** Do you want the drift timer
in Phase 2, or defer until interactive governance has run clean for a while?
If yes: subscription login on the controller (unverified under systemd) or
an API key (metered)?

**Q5 — Who writes roles.** Confirm §6.6: interactive agent may write roles
under hook+validate+confirm; unattended agent is read-only forever.

**Q6 — Migration scope for the old Ansible.** Confirm dispositions in §2.3.
Specifically: (a) `uisp`/`unifi-os` roles — finish them, or retire and treat
UISP/UniFi OS Server as manually-installed "observed" appliances with
backup capture? (b) OK to retire `configure_container_docker.yml`?
(c) Should `ubuntu`'s dist-upgrade-every-run become an explicit inventory
flag (it's a mutation that isn't declared per se)?

**Q7 — UniFi as-code engine.** Ansible `uri` + name-keyed reconcile with
payloads in the inventory repo (recommended; no state file, one language)
vs Terraform (`filipowm/unifi`) with sops-encrypted state. Also: which UniFi
objects go first — firewall policies (C5's test case), VLANs, DNS,
reservations? Note NAT is unavailable on this controller.

**Q8 — Non-decisions.** Does "we decided not to add a firewall rule for
dockerd mTLS" need a checkable assertion (an Ansible `assert` that no policy
matches port 2376 from non-MGMT), or is prose in a decision record enough?
Recommend: assertion, because it is cheap and it is exactly the drift the
ideology exists to catch.

**Q9 — Hook stance and the allowlist.** (a) Hooks primary, prompts secondary
(recommended: hooks are the only thing enforced by the harness, not the
model). (b) Replace the 876-entry `settings.json` wholesale with a curated
tracked file (it contains a Plex token — I'd also like to rotate that
token). (c) B3: hard-deny `ansible-playbook` on a dirty tree, or `ask` with a
warning? Recommend `ask`.

**Q10 — Escalation channel** for unattended findings: HA notification
(mobile push), email, or just the committed report? Recommend HA `notify` +
committed report.

**Q11 — Observe-only backup artifacts.** OK to commit binary captures
(Synology `.dss`, UniFi `.unf`, UISP backup, iDRAC SCP XML) into the private
inventory repo under `captures/<host>/`, replacing in place (git keeps
history)? Any size concern for the Synology `.dss`?

**Q12 — Controller as a managed host.** The ideology says the controller's
own state counts. Today the `controller` role only mounts NFS. Should it
also own: `step` CLI install, docker CLI contexts, the vault client, the
drift timer, collections install (`requirements.yml`)? Recommend yes to all.

**Q13 — Compose secret exposure (§4.4).** Move gluetun/plex/step-ca secrets
into compose `secrets:`/0600 `env_file` in Phase 3, or accept as derived?

---

## 8. Phases — original proposal (superseded by §10 after the decision record; kept for provenance)

**Phase 0 — Decide.** Answer Q1–Q13; write §9.

**Phase 1 — Revision the source of truth.** Init inventory repo (Q2);
vault every secret inline (A1) with the `-client` script (Q3); wire
`vault_identity_list`; widen the no-secrets check and add it to
`validate.sh`; `requirements.yml` pins + `collections_path` (A7);
`.ansible-lint.yml` → `production`; `tests/render.yml` + `make validate`
(A3/C3); fix the BTF infinite-include hazard. *Exit test:*
`make validate` green, `ansible-inventory --list` decrypts, one commit per
unit in both repos.

**Phase 2 — Govern the agent.** Project `CLAUDE.md` + `.claude/rules/`;
curated tracked `settings.json` (Q9); the five hooks + `test_hooks.sh`;
`/apply-site` skill (human-only); `drift-checker` subagent; SessionStart
context. *Exit test:* `test_hooks.sh` passes with ≥1 deliberately-bad ad hoc
command denied and one good `--check` run allowed; one full interactive
change end-to-end under the hooks.

**Phase 3 — Codify the known ad hoc state (C2/C4).** `api_setting.yml`
pattern (A2) → bazarr addresses, qBT `tun0`; controller role owns docker
contexts, `step`, vault client, collections (Q12); credential/cert expiry
task (LSCR PAT, AirVPN key, every served cert); registry-convention fixes
from §2.3; compose secret hardening (Q13); retire dead roles (Q6).

**Phase 4 — Drift.** Unattended timer (Q4/Q10), compose-hash probe, report
capture, HA notify. *Exit test:* deliberately hand-edit a container env on
media → next timer run reports it.

**Phase 5 — Extend reach: `observed` provision type + UniFi.** Schema for
`observed` hosts (Synology full, UISP, iDRAC) with capture lifecycle (Q11);
UniFi reconcile engine (Q7) starting with the C5 assertion (Q8), then
firewall policies, VLANs, DNS, reservations; vCenter portgroups declared.

**Phase 6 — Roadmap items under governance.** Re-IP (roadmap Phase 5) and
decommissions (Phase 6) executed *only* as inventory diffs + UniFi payload
diffs, proving the model on a real multi-system change.

---

## 9. Decision record — 2026-08-25 (answers given by Mike, one card per question)

| # | Decision | Consequence for the plan |
|---|---|---|
| Q1 | **Every emergency action gets an incident record** (needed to track trends). **Any config/parameter change must be codified**; a pure restart with no parameter change is permitted with the record. | `incidents/INCIDENT-<date>-<slug>.md` in the inventory repo; stop gate blocks the next session until any parameter change in an open incident is codified or the incident is explicitly closed. Hook allows `docker restart`-class actions only when an incident file for today exists. |
| Q2 | **Private GitHub remote for now**; a self-hosted FOSS git will replace it later, so the remote is **an interface, not a hardcoded GitHub dependency**. | One `git_remote_url` setting per repo (inventory `all.vars` / controller config); no `gh`-specific logic in roles, hooks, or scripts. PR creation goes through a thin adapter (`scripts/mhl-pr`) with a GitHub backend today. |
| Q2b | Delete `hosts.yml.bak`; `seedpool.api.key` is backed up in gdrive → remove; README rewritten. | Done at repo init, before the first commit. |
| Q3 | **Research a best-practice secret-management approach** before committing to one. | New research item **R-A** (§11). Interim assumption, vetoable: a 0600 file outside both repos so Phase 1 can proceed; replaced by R-A's outcome. |
| Q4 | **Unattended mode deferred** — no "automagic" without Mike engaged. | Phase 4 timer removed from the near-term plan; drift check exists as an interactive `/drift` skill only. `.claude/agents/drift-checker.md` still built (read-only subagent) for in-session use. |
| Q5 | **PR workflow.** The agent branches, writes code, opens a pull request in either repo; Mike approves/denies/comments. | Hooks deny commits to `main` and any `git push` to `main`; applies (`site.yml` without `--check`) run only from a merged/committed state. Inventory repo uses the same flow. |
| Q6 | Retire `uisp` and `unifi-os` roles to `archive/`; those apps are manually installed and get backup capture. | Phase 3. |
| Q6b | **Ground-up rewrite expected**; logic placement (e.g. where the dist-upgrade flag lives) is the agent's call. | Phases 1–3 are a rewrite under the same abstractions (provisioning, BTF, registry, service generator), not a patch series. Each rewritten unit must keep §2's baseline and ship with a render/check test. |
| Q7 | **Ansible** for UniFi; a dedicated research pass for a good UniFi Ansible collection happens when Phase 5 starts. | Research item **R-C**. |
| Q8 | Non-decisions are **codified as assertions**. | `assert` tasks in a `governance` role, each linked from a decision record entry. First one: no firewall policy matches TCP 2376 from non-MGMT. |
| Q9 | **Hooks primary**; replace the 876-entry allowlist wholesale with a curated tracked file; **rotate the Plex token**. | Phase 2. Token rotation is a Phase 2 task with its own incident-style note. |
| Q9b | Dirty-tree apply "shouldn't happen — your job is to do the commit and get it to a PR." | **Hard deny**: `ansible-playbook site.yml` without `--check` is denied if either repo has uncommitted changes to roles/site.yml/hosts.yml or is not on a committed ref. |
| Q10 | **Escalation goes through Mike's personal agent**, which reaches him. | The agent emits findings to an interface (file/queue/message) the personal agent consumes; transport to be agreed with that agent (**R-D**). No direct HA/email notify from this agent. |
| Q11 | **Research whether a Synology Ansible library exists** before accepting observe-only. If none: let the systems store their own backups on an NFS path visible to the agent (e.g. `../HomeLabBackup` relative to the workspace) and track them there — **not** as blobs in git. | Research item **R-B**. `captures/` in the inventory repo is dropped; the `observed` type's capture step points at the NFS backup path and records a manifest (hash, date, size) in the inventory repo instead. |
| Q12 | Today's controller is a **laptop**; a new controller / master-agent VM will be built in vCenter **after** the Ansible is perfected. **Controller owns its own toolchain.** | Controller role owns: `step`, `xorriso`, `7z`, docker CLI + contexts, `ansible-galaxy` install from `requirements.yml`, vault-client presence, hooks/skills install, git remote config. The new controller VM becomes a `vm/vmware` host in the inventory provisioned by MHL itself (Phase 6). |
| Q13 | **Research best practices** for secrets in rendered compose and put them into motion. | Research item **R-A** (shared with Q3 — one secrets design covering vault storage, runtime secret delivery to compose, and rotation). |

## 10. Phases — revised after the decision record

**Phase 0 — Research items R-A…R-D (§11)** — R-A (secrets) must land before
Phase 1's vaulting; R-B before Phase 5; R-C at Phase 5 start; R-D with Phase 2.

**Phase 1 — Revision the source of truth.** Init inventory repo (delete
`.bak` + seedpool key, rewrite README), push to the private remote via the
remote-URL interface; vault every secret per R-A; `requirements.yml` pins +
`collections_path`; `.ansible-lint.yml` → `production`; `tests/render.yml`
+ `make validate`; widened no-secrets check; BTF include guard. Delivered as
PRs (first PR in each repo establishes the flow).

**Phase 2 — Govern the agent.** Project `CLAUDE.md` + `.claude/rules/`;
curated tracked `settings.json` (Plex token rotated); hooks: `guard_bash`
(incl. main-branch and dirty-tree denies, incident-gated restarts),
`guard_writes`, `check_edit`, `stop_gate` (validate + memory + open-incident
check), `session_context`; `test_hooks.sh`; `/apply-site` (human-only),
`/drift` (interactive), `drift-checker` subagent; `scripts/mhl-pr` adapter;
escalation interface to the personal agent (R-D).

**Phase 3 — Rewrite + codify.** Ground-up rewrite of the roles under the
same abstractions, unit by unit, each behind a render test and a `--check`
diff of zero against the live fleet before merge: OS roles (explicit upgrade
policy), docker (TLS, contexts, `reset_connection`), ca-certificates
(content hash), rsyslog (generic), host_provision (ISO rebuild guard),
`api_setting.yml` pattern → bazarr addresses, qBT `tun0`; controller role
owns toolchain (Q12); compose secret delivery per R-A (Q13); expiry checks
(LSCR PAT, AirVPN key, served certs); `governance` role with the first
assertion (Q8); retire uisp/unifi-os/configure_container_docker to
`archive/`; registry-convention fixes.

**Phase 4 — `observed` provision type.** Synology (per R-B: declare what a
library allows, otherwise NFS-backed self-backups + manifest), UISP, iDRAC.

**Phase 5 — UniFi as code** (R-C first): C5 assertion, then firewall
policies, VLANs, DNS, reservations; vCenter portgroups declared.

**Phase 6 — New controller VM** built by MHL in vCenter; laptop retired as
controller. Then the roadmap's re-IP and decommissions executed purely as
inventory + UniFi payload diffs.

**Deferred (Q4):** unattended systemd timer / headless `claude -p`. Design
stays in §6.5 for when Mike is ready.

## 11. Research items opened by the decision record

- **R-A Secrets end-to-end** (Q3 + Q13): vault-password custody on a headless
  controller (options: 0600 file, `pass`, a self-hosted secret store such as
  Vault/OpenBao/Infisical/Bitwarden Secrets Manager with an Ansible lookup),
  rotation, and runtime delivery of secrets into compose (compose
  `secrets:`, 0600 `env_file`, Docker Swarm-less secret files) so rendered
  artifacts never hold plaintext. Deliver: recommendation + PoC before
  Phase 1 vaulting.
- **R-B Synology Ansible library** (Q11): survey again for a maintained
  collection/module set covering shares, NFS permissions, users, scheduled
  tasks; this session's pass found only unmaintained ones (`tafeen.synology`,
  `agaffney.synology_dsm`, `N4S4/synology-api` last release 2024-08). If none
  qualifies, design the NFS self-backup + manifest scheme.
- **R-C UniFi Ansible collection** (Q7): at Phase 5 start, survey for a
  collection wrapping the Integration API with idempotent modules; this
  session found none (only installer roles and an inventory plugin).
- **R-D Personal-agent escalation interface** (Q10): agree the transport with
  Mike's personal agent (file drop, MCP tool, message bus) and the finding
  schema (severity, host, what/why, proposed codified fix, PR link).

---

## 10. Provenance and what was not verified

Verified live today: repo contents, inventory shape (values withheld),
`.claude/settings.json` shape, the `~/workspace/claude` hooks and tests,
`unifly 0.9.0 --help` and read-only Integration API probes on the live
controller (including the NAT 404), installed collection versions in
`.venv`. Verified against current published docs: ansible-vault/sops
behaviour, Molecule/ansible-lint/ansible-core versions and profiles, module
check/diff attributes, `requirements.yml` semantics and absence of a
lockfile, Claude Code hooks/permissions/subagents/skills/headless/SDK
contracts, Terraform provider status.

Not verified: `ansible-doc` re-check of module attributes (no toolchain on
the research agent's PATH); UISP live swagger; Synology `.dss` contents;
iDRAC SCP export on fw 2.83; bubblewrap sandbox + SSH to LAN IPs;
subscription auth for `claude -p` under systemd.

## 12. Execution log

### 2026-08-25 — repo setup (verified live)
- `gh` 2.45 installed and authenticated as `bzaks1424` (scopes `repo`, `read:org`, `admin:public_key`, `gist`; token in gh's keyring, outside both repos).
- **Decision: keep the public `McHomeLab`** (portability goal; never held secrets by design). Full-history `gitleaks` 8.24.3 scan: 10 hits, all benign — 9× `curl -u root:calvin` (Dell iDRAC factory default) in the two iDRAC research docs; 1× `ansible/inventory/test-key`, the mock inventory's throwaway key, verified authorized on **no** host (laptop, util, media, unifi). No history rewrite. Follow-up for Phase 4: confirm the R630 iDRAC no longer uses the factory password (host is powered off; unverified).
- **`bzaks1424/McHomeLab-Inventory` created (private)** and initialized with README + `.gitignore` + the four secret-free homepage side files. `hosts.yml`, `homepage-services.yaml`, `recyclarr.yml` are **withheld (gitignored) until Phase 1 vaulting** — they hold plaintext API keys/passwords. `hosts.yml.bak` and `seedpool.api.key` removed per Q2b.
- **Branch protection on `main`**: McHomeLab — PR required, 0 approvals (owner cannot approve own PRs; Mike merges), `enforce_admins`, no force-push/delete. McHomeLab-Inventory — **not available** (GitHub Pro feature on private repos, HTTP 403); enforced client-side instead (git pre-push hook + Claude `guard_bash`), noted as a gap the future self-hosted git (Q2) should close.

### 2026-08-25 — research items R-A..R-D delivered (each reviewed against its brief; citations added where thin)
- **R-A** `RESEARCH_SECRETS_RA.md` — vault password: 0600 file `~/.mhl/vault/mhl.pass` read by `~/.mhl/bin/mhl-vault-client`, escrowed as one password-manager entry (every self-hosted store just moves the unseal secret one hop and is itself infra MHL would have to declare). Secrets stay **inline `!vault` in hosts.yml** (verified: lint, `dict2items`, `to_json` all survive). Compose delivery: file-sourced `secrets:` — every image in use has a file form (gluetun `*_SECRETFILE`, LSIO `FILE__*`, WUD `*__FILE`, step-ca `*_FILE`, homepage `HOMEPAGE_FILE_*`, recyclarr `!file`) → `homepage-services.yaml` and `recyclarr.yml` can leave `.gitignore`. **Corrections to this doc:** §3 A3 step 1 — `ansible-inventory --list` proves *parse only* (succeeds with no vault password); a decrypt probe is a separate test. `ansible-vault rekey` cannot rekey inline values — R-A ships a replacement script. Changed secret files need `docker compose restart <svc>` (atomic-rename inode trap; config-hash unchanged). `DOCKER_STEPCA_INIT_PASSWORD` on util is inert (CA already initialised) → delete, don't plumb. Stale plaintext found on the fleet: `media:/opt/docker/compose/docker-compose.yml.bak-2026-07-19`, `util:/opt/docker/compose/diun-watch.yml` — **removal needs Mike's go-ahead**.
- **R-B** `RESEARCH_SYNOLOGY_RB.md` — **no maintained library qualifies** (`stevefulme1.synology_dsm` 0.1.0 has a real idempotency bug in `dsm_nfs_share`; `N4S4/synology-api` is active (v0.9.2, 2026-08-04) but raw, no NFS-privilege coverage; `py-synologydsm-api` active but read-only). Authoritative API shapes come from Synology's own `synology-csi` driver → a small `uri` GET/compare/SET set (NFS share privileges for the two exports) is declarable without a library. Fallback for the rest: DSM `SYNO.Backup.Config.Backup` self-backup to the NFS path + Task Scheduler existence check + manifest. Memory corrected: DSM error 119 = `WEBAPI_ERR_SID_NOT_FOUND`, not a permissions problem.
- **R-C** `RESEARCH_UNIFI_RC.md` — no collection covers the object set; `hellqvio86.unifi` is the only idempotent one (alpha, Session-API-only, no network/DNS/ACL); the official `ubiquiti.unifi_api` is a non-idempotent codegen passthrough. **Recommendation: thin `mhl.unifi` collection** wrapping `unifly` with name-keyed reconcile (~8 modules; C5 slice ≈ half a day). C5 assertion drafted; `destination.port` field name unverified until a live `policies get` check.
- **R-D** `RESEARCH_ESCALATION_RD.md` — **primary: git-committed `findings/` queue in the inventory repo; complement: cross-session `SendMessage` to the `personal` session** (v2.1.224+) for warning/critical. Finding schema (JSON + markdown) and Phase 2 PoC drafted; 8 questions for the personal agent's config. §6.5 of this doc (direct HA notify) is superseded by Q10/R-D. The Synology `Backups/claude` share is a separate channel, not this transport.

### 2026-08-25 — step-ca decision (Mike) and the organization strategy

**Rule (Mike):** if an artefact can be dropped into a stateless container and it
runs as today, it is a **backup → Synology**. If it is used to *spin up* a new
container, it is **configuration → git**. Applied to step-ca: `config/`,
`templates/`, `certs/*.crt` → declared from `hosts.yml` (git);
`secrets/{root_ca_key,intermediate_ca_key,password}` + `db/` → Synology backup.
Losing util *and* Synology means a new CA and a fleet-wide re-issue via
`site.yml` (all certs and trust stores are Ansible-managed) — documented as
the restore procedure's worst case, not hidden.

## 13. Organization strategy — where things live (human-readable, keep current)

### 13.1 Git — `McHomeLab` (public; roles, never secrets)
```
ansible/site.yml, roles/, tasks/, group_vars/, filter_plugins/   the product
ansible/requirements.yml + collections/ (ignored)                pinned deps (make deps)
ansible/tests/                                                   offline render test (make validate)
ansible/inventory/test.yml                                       sanitised mock inventory for lint/check
scripts/mhl-*                                                    operator tools (vault client/file/no-secrets, pr helper)
.claude/{settings.json,rules/,hooks/,agents/,skills/}            the sysadmin agent itself (tracked)
CLAUDE.md                                                        binding project rules
research/                                                        documents of record: RESEARCH_*.md, decisions, execution logs
archive/                                                         retired code with a README row per item
```
### 13.2 Git — `McHomeLab-Inventory` (private; the fleet, secrets vaulted)
```
hosts.yml                        single source of truth; every secret an inline !vault (vault-id mhl)
homepage-*.yaml, recyclarr.yml   side files delivered by registry export/import (secret-bearing ones vaulted)
incidents/INCIDENT-<date>-<slug>.md   Q1 records: what was done by hand, what must be codified
findings/                        R-D escalation queue (Phase 2)
manifests/<host>/<name>.yml      hash/date/size of each Synology-held backup (Phase 4) — the git-side index of 13.3
unifi/                           UniFi object payloads (Phase 5)
README.md                        how to run, where the vault password comes from
```
### 13.3 Synology — `HomeLabBackup` share (backups: restore-and-run artefacts)
```
HomeLabBackup/
  <host>/<service>/<YYYY-MM-DD>/…      e.g. util/step-ca/2026-08-25/{secrets/,db/}
  <host>/<service>/latest -> …         symlink or copy of the newest set
  synology/config/<YYYY-MM-DD>.dss     DSM self-backup (SYNO.Backup.Config)
  unifi/network/<YYYY-MM-DD>.unf       UniFi controller backup
  unifi/uisp/<YYYY-MM-DD>.tar.gz       UISP backup
  idrac/scp/<YYYY-MM-DD>.xml           iDRAC server-config-profile export
```
Mounted on the controller (and visible to the agent) at a path declared in
`hosts.yml` (`controller.provision.mounts`), so nothing outside git decides
where backups are. Every directory above has a matching `manifests/` entry in
the inventory repo; a mismatch between manifest and share is a finding.
Retention: keep the last N (declared per service in `hosts.yml`); the agent
never deletes a backup without an incident record or a PR.
### 13.4 Controller local (derived only — `~/.mhl`)
`registry.json`, `<host>/` exports, `pxe_staging/`, `docker-tls/`: regenerated
by `site.yml`. The two exceptions are not derived and are created by the
controller role from inventory: `~/.mhl/vault/mhl.pass` (escrowed in Mike's
password safe) and `~/.mhl/bin/mhl-vault-client`.

### 2026-08-25 — first end-to-end `/drift` run (read-only, forked drift-checker under dontAsk)
**No configuration drift between the committed inventory and the live fleet.** Every apparent
difference traced to the checking tooling, now Phase 3 items:
- **F1 (medium, `roles/host`)** check mode cannot pass an appliance host: `get_certificate` and the DSM
  `uri` calls are skipped under `--check`, downstream tasks then fail, and `serial: 1` means media/unifi/
  printer are never evaluated. Fix: `check_mode: false` on the read-only probes.
- **F2 (medium, `tests/render.yml`, introduced in PR #5)** `include_vars` of `roles/service/defaults/main.yml`
  outranks inventory vars, so the render used `traefik:v3.6`/`gluetun:v3` instead of the pinned
  `v3.7.11`/`v3.41.3`. The deployed files match the inventory; the render did not. Fix: load defaults with
  lower precedence (play `vars:` from the defaults file) and assert `traefik_image` equals the inventory value.
- **F3 (low, `/drift` skill)** `docker compose config --hash` is not comparable with the
  `com.docker.compose.config-hash` label for `network_mode: service:*` containers (compose resolves to
  `container:<id>` before hashing). Use a text diff of rendered vs deployed compose for those.
- F4 `~/.mhl/synology/chain.pem` mode 0664 vs declared 0644 (controller-local, fixed by any run).
- F5 stale `known_hosts` entry for alias `unifi` on the controller (from the reprovision).
- F6 leftover `util:/opt/docker/compose/diun-watch.yml` — already on the codified-cleanup list (Q2).

### 2026-08-25 — escrow confirmed (Mike)
The recovery root is Mike's password safe: its own master password (independent
of the `mhl` vault password), backed up to Google Drive, openable from any
device. It holds the vault password and is where plaintext originals are
escrowed before `mhl-vault-file --purge`. Vault password rotation: **hold**
(no public exposure found; reviewer-reported transcript exposure unverified).
## 14. step-ca: configuration vs backup, and the restore procedure (Phase 3)

**Configuration (git):** `McHomeLab-Inventory/stepca/` holds `ca.json`
(vault-encrypted whole-file — it embeds the provisioners' encrypted JWKs),
`defaults.json`, `root_ca.crt`, `intermediate_ca.crt`. The controller exports
them through the registry; `util` imports them into
`/opt/containers/step-ca/{config,certs}/` before the service role runs compose,
so a rebuilt util gets the identical CA configuration. `DOCKER_STEPCA_INIT_*`
is retired (it only ever ran on an empty volume and would have minted a new CA).
A change to `ca.json` in git is applied by `site.yml` and needs a step-ca
container restart to take effect.

**Backup (Synology `/volume4/Backups/HomeLabBackup`, decided 2026-08-25):**
`secrets/{root_ca_key,intermediate_ca_key,password}` and `db/`. The service
role's `backup:` block renders a systemd timer on util (daily, keep 14) that
writes ONE ENCRYPTED tarball per run — `tar | openssl enc -aes-256-cbc -pbkdf2`
with the per-host key `/root/.mhl-backup.key` delivered from the vaulted
inventory (`service_backup_passphrase`; escrowed in Mike's safe as "McHomeLab
backup passphrase") — to `HomeLabBackup/util/step-ca/<UTC stamp>.tar.enc` +
`.sha256`, with a `latest.tar.enc` symlink. Nothing lands on the share in the
clear: it is a 777 export to two subnets. util mounts the share at
`/mnt/Backups` (`optional: true`, automount).

**Restore (rebuild util, CA intact):**
1. `site.yml` provisions util and imports the config/certs from the inventory.
2. Before the first `docker compose up` of step-ca (or: stop the container),
   restore the latest snapshot with the escrowed passphrase in a key file:
   `openssl enc -d -aes-256-cbc -pbkdf2 -pass file:/root/.mhl-backup.key -in
   /mnt/Backups/HomeLabBackup/util/step-ca/latest.tar.enc | sudo tar -x -C /`
   (paths inside are `opt/containers/step-ca/{secrets,db}`); check `secrets/`
   is 0700 owned by uid 1000.
3. `site.yml` again (compose up). Verify: `step ca health --ca-url
   https://ca.util.michaelpmcd.com` and that an existing fleet cert still
   validates against `root_ca.crt` from git.

**Worst case (util *and* Synology gone):** no key material → a **new CA**.
`site.yml` re-issues every certificate and re-delivers every trust store
(docker mTLS on media/unifi, WUD, Synology DSM, printer, traefik ACME) — a
fleet-wide re-issue event, not a restore. Documented here so nobody expects
otherwise.
