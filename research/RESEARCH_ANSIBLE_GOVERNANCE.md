# RESEARCH: Total revisioned governance of the home environment

**Date:** 2026-08-24
**Status:** RESEARCH PLAN — not yet executed. No code, hooks, or repo changes
from this document exist yet. **Expanded 2026-08-24 by
`RESEARCH_SYSADMIN_AGENT.md`** (feature baseline, verified findings for every
track below, target agent architecture, phases, and the consolidated question
list Q1–Q13). §0 here stays the binding ideology; read both.
**Target:** the whole McHomeLab-governed environment (controller, util, media,
unifi) + the McHomeLab-Inventory repo + this project's own Claude Code
configuration (`.claude/settings.json`, hooks).
**Written for:** a fresh Claude Code session with no memory of the
conversation that produced this document. Read this whole file before doing
anything. It is a research and decision plan, not an implementation ticket —
most sections end in open questions, not answers.

---

## 0. The ideology (verbatim distillation — do not re-derive this differently)

The user's own words, from the conversation that produced this document:

> I want to make a conversion — where you as an agent legitimately never do
> anything to the entire lab environment that isn't controlled by revisioned
> ansible and inventory. [...] I'm zeroing in on an ideology of "no changes
> without trackable revision history to any part of the home environment."
> Meaning — any configuration, any adjustment, any necessary disk change gets
> codified so it's never forgotten and should the worst happen, we can raise
> everything from the dead.

Corollaries worked out in that conversation, load-bearing for everything
below:

1. **This governs writes, not reads.** Reading live state to diagnose or
   verify (`docker ps`, `curl` a health endpoint, `docker logs`) is untouched
   — rule 3 of `~/.claude/CLAUDE.md` already requires reading the live system
   before asserting anything. The new rule is about what happens the moment
   you decide to *change* something.
2. **"Codified" does not mean "a static file."** An idempotent Ansible task
   that calls an app's API on every run (check current value, write only if
   wrong) is a legitimate declaration, exactly as legitimate as a templated
   file import — as long as it is committed to git and re-runnable from
   nothing. This is what makes the ideology achievable rather than circular:
   apps that rewrite their own config files (bazarr) don't need to be routed
   around, they need a proper idempotent task.
3. **A three-bucket model for classifying state**, and the litmus test for
   which bucket something is in — **"if everything burned down, could this be
   raised from committed history alone?"**
   - **Source** — Ansible roles, `hosts.yml`, generator scripts. Hand-edited.
   - **Derived** — rendered compose files, `registry.json`, `~/.mhl` exports,
     a tool's own cached tag list. Never hand-touched; reproducible by
     re-running source against the live system. No separate revisioning
     needed *as long as the run that produces it is itself revisioned.*
   - **Ephemeral** — container health, current DNS resolution, a scanner's
     pending-update snapshot. Not declarable, observation-only, expected to
     reconstruct itself once declared config is reapplied.
4. **"Any part of the home environment" is meant literally**, including the
   controller's own local state (Docker CLI contexts, throwaway certs issued
   for verification, anything under `~/.mhl` that isn't purely regenerated
   output) and systems outside McHomeLab's current reach entirely (UniFi
   firewall/VLAN/DHCP config, Synology, UISP).
5. **UNRESOLVED — ask before treating this as binding.** Is there any
   emergency exception (a service is down, the fix can't wait for a role to
   be written), or is it truly zero-exceptions, codify-first-always, every
   time, under all conditions? The user was asked this directly and has not
   yet answered. Per the HA workspace's own directive #2 (surface every
   ambiguity, get an explicit answer before acting, however pedantic it
   feels) — **ask this question again, explicitly, before doing anything in
   §6 that assumes an answer.**

---

## 1. Why now — current-state audit (verified 2026-08-24, this session)

Concrete, already-observed facts establishing the gap between the ideology
and today's reality. Nothing here needs re-verification; it was checked live.

- **`McHomeLab-Inventory` (the repo holding `hosts.yml`) is not a git
  repository.** `git status` returns `fatal: not a git repository`. This is
  the single largest structural gap: the primary declarative source of truth
  for the entire fleet has **zero revision history**, and holds plaintext
  secrets (vCenter/become passwords, AirVPN WireGuard keys, the WUD MQTT
  password, a GitHub PAT, ARR/Plex API keys) — which is *why* it was never
  made a repo. The ideology cannot hold until this is solved.
- **`McHomeLab` (the Ansible role/playbook repo) is a git repo and was used
  correctly** for every role/template/inventory change made this session —
  commit-per-unit, `ansible-lint` clean, offline-rendered before applying.
  That half of the pattern already works; it's the template to extend, not
  invent.
- **At least half a dozen mutations happened this session outside any
  revisioned artifact**, each individually reasonable and reversible, none
  reproducible from git: a bazarr Sonarr/Radarr address change via a bare
  `ansible localhost -m uri` call; a forced WUD scan via raw
  `wget --post-data`; a `recyclarr sync` run directly via `docker exec`
  before its config was inventory-managed (this one caused an unintended
  quality-profile change, later repaired); `step ca certificate` issuance run
  directly for verification, outside the `step-ca-cert` role; `docker context
  create` entries added to the controller's local Docker CLI config.
- **`.claude/settings.json` for this project is a ~124 KB accumulated
  allowlist** of hundreds of individually-approved one-off Bash commands
  (many are literal historical `ssh util.michaelpmcd.com "..."` strings).
  This is a symptom, not a mechanism — permission caching records that a
  command was once approved, it does not make anything revisioned or
  repeatable.
- **No hooks exist in McHomeLab's `.claude/` config at all** — no
  `PreToolUse`, no `Stop`. Contrast: `~/workspace/claude` (the Home Assistant
  project) already runs exactly this class of governance via four hooks
  (`guard_bash.sh`, `guard_writes.sh`, `check_edit.sh`, `stop_gate.sh`) —
  **even though that project isn't a git repo either**, proving the mechanism
  works independent of the storage backend. `guard_bash.sh` in full, as a
  worked example of the shape (narrow, deny-with-a-reason,
  `PreToolUse`/`hookSpecificOutput` JSON contract):

  ```bash
  #!/usr/bin/env bash
  # PreToolUse[Bash]: catch the two ways a shell command routes around the file
  # guards, plus the destructive-command rule.
  # Deliberately narrow. A hook that denies too much gets worked around, and a
  # worked-around hook enforces nothing.
  set -uo pipefail
  PAYLOAD=$(cat)
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null)
  [ -z "$CMD" ] && exit 0

  deny() {
    jq -n --arg reason "$1" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
    exit 0
  }

  GEN='(\./)?(workspace/home-assistant/)?(INVENTORY\.md|snapshots/)'
  if printf '%s' "$CMD" | grep -qE "(sed +-i[^>|]*|tee +(-a +)?|>>?[[:space:]]*|truncate[^>|]* )${GEN}"; then
    deny "CLAUDE.md rule 2: ... regenerate instead: python3 scripts/ha_snapshot.py"
  fi
  # ... a second rule for rm -rf without confirmation, a third for git
  # init/commit/push run in a workspace that is deliberately not a repo ...
  exit 0
  ```

  Read all four files at `~/workspace/claude/scripts/hooks/*.sh` and
  `~/workspace/claude/scripts/test_hooks.sh` (their test harness) before
  designing anything in §3 — this is proof-of-concept, not theory.
- **`.ansible-lint.yml` sets `profile: moderate`**, but every `ansible-lint`
  run this session actually passed at the stricter **`production`** profile
  — low-hanging fruit to tighten the declared bar to match reality.
- **No Molecule, no `tests/` directory, no automated role tests exist.**
  Verification this session was ad hoc every time: a hand-written scratch
  playbook rendering templates offline to a scratchpad directory,
  `docker compose config --quiet` for syntax, manual `curl`/`docker inspect`
  checks post-deploy. The pattern was good; it was never captured as
  something a future session (or a hook) can just re-run.
- **Collection version skew observed live**: `vmware.vmware` 2.4.0 in the
  project `.venv` vs. 2.5.0 in `~/.ansible/collections` (`ansible-lint`
  warned about this). Nothing pins the collection set used to build the
  fleet; it should be revisioned like everything else.
- **Systems entirely outside McHomeLab's declarative reach today:** UniFi
  firewall policies/VLANs/DHCP reservations (configured live via the `unifly`
  CLI or the UI; read-only recon was done this session, a policy change was
  discussed and explicitly **not** applied — that non-decision itself has no
  artifact recording it), Synology beyond its cert delivery, UISP/unifi-os
  beyond initial provisioning, the HP printer beyond its cert.
- **A decision the user was already asked and has not yet answered**: whether
  `McHomeLab-Inventory` becomes a local-only git repo, a private remote repo
  (which requires vaulting secrets first), or stays as-is. Re-surface this —
  do not assume an answer.

---

## 2. Research Track A — Ansible practices for revisioned, idempotent infrastructure

Framed as questions. **Verify every claim against current docs before acting
on it** — per the global rule, never invent a flag, module option, or
tool-status claim from training-data memory alone; several things below (tool
maintenance status, current strictest lint profile, module check-mode
support) are exactly the kind of fact that goes stale.

- **A1. Secrets in a revisioned inventory.** `ansible-vault` (single vs.
  multi vault-id, `--vault-password-file` vs. a prompt, partial-file
  encryption of just the secret values vs. whole-file) vs. alternatives
  (`sops`+`age`, an external secret store). Evaluate specifically for a
  single-operator homelab with no CI runner and a `hosts.yml` shape that
  mixes secrets and non-secret config per-host. This directly unblocks C1.
- **A2. Idempotent API-driven tasks (the "bazarr pattern").**
  `ansible.builtin.uri` with `changed_when` built from a GET-then-compare
  step, so a task can declare "this API setting equals X" and only write when
  it's wrong — real idempotency, not "POST this every run." Survey how this
  is conventionally structured (a two-task GET+conditional-PUT pair? a
  custom module?) for apps with no dedicated Ansible module (bazarr,
  recyclarr, WUD, qbit-manage). Is there a reusable task file or role to
  standardize across the fleet, or does each app need its own?
- **A3. Testing.** Molecule's current maintenance status (it has changed
  hands before — check freshness, don't assume), whether the modules already
  in use here (`community.docker.docker_compose_v2`,
  `community.crypto.x509_certificate`, `ansible.builtin.uri`,
  `ansible.builtin.template`) actually honor `--check`/`--diff` faithfully.
  Given this is a single-operator homelab, is full Molecule (which spins up
  containers/VMs per role) worth the weight, or should this session's
  improvised scratch-playbook render-test pattern just be formalized as a
  committed, lightweight `tests/` entry point instead? Recommend one, with
  reasoning, don't just default to "the industry-standard tool."
- **A4. Drift detection.** Is there a pattern — or is WUD's own
  registry-vs-running model instructive — for periodically diffing live host
  state against what `site.yml` would produce, and surfacing drift, so an
  unrevisioned change (a future mistake, or a manual fix under time pressure)
  gets caught rather than silently persisting forever. This is the
  ideology's actual enforcement backstop, not just the hooks in §3.
- **A5. `ansible-lint` profile.** Bump `.ansible-lint.yml`'s
  `profile: moderate` → `production` now (already passing). Verify whether
  a current `ansible-lint` release has gained anything stricter than
  `production`.
- **A6. Extending the model to non-Ansible-native systems.** UniFi via
  `unifly` — does it support enough of a `--from-file` JSON-apply idiom to
  wrap in an idempotent Ansible task with the payload committed to git?
  Synology already has one inventory-driven pattern (cert delivery via
  `step-ca-cert` + a REST upload task) — is it extensible to other DSM
  settings? UISP?
- **A7. Pin the collection set.** `requirements.yml` with exact versions,
  committed — closing the `vmware.vmware` 2.4.0/2.5.0 skew observed live this
  session.

## 3. Research Track B — Claude Code harness enforcement

Design questions, informed directly by the working precedent in §1.

- **B1.** Read all four hooks in `~/workspace/claude/scripts/hooks/` in full,
  plus `scripts/test_hooks.sh`, before designing anything below.
- **B2.** Design (do not yet implement without sign-off) a
  `PreToolUse[Bash]` hook for McHomeLab that recognizes and denies ad hoc
  *mutating* patterns against lab hosts — mirroring `guard_bash.sh`'s own
  stated design principle ("a hook that denies too much gets worked around,
  and a worked-around hook enforces nothing"), so it must stay narrow.
  Candidate patterns to deny: `ansible ... -m (shell|command|uri|copy|file|
  template)` targeting a real inventory host (not `localhost`/controller-safe
  invocations, which this session used constantly and correctly for
  read-only recon and for controller-side cert issuance *inside* a role);
  `docker exec`/`docker --context <host> exec` against a container on a
  managed host; `ssh <lab-host>` carrying a mutating command; `step ca
  certificate` issuance run outside the `step-ca-cert` role; `curl -X
  POST/PUT/PATCH/DELETE` against a lab host's API. Read-only diagnostics
  (`docker ps`/`logs`/`inspect`, `ansible -m setup/ping`, `curl` with no `-X`
  or `-X GET`) must **not** be blocked — false positives here defeat rule 3
  (the live system is the authority) and will get the hook disabled.
- **B3.** Should the same mechanism gate `ansible-playbook` itself — e.g.
  deny the run if the working tree has uncommitted changes to
  `roles/`/`hosts.yml`? Research whether this is enforceable cleanly from a
  `PreToolUse[Bash]` hook (it would need to `git status` the relevant repo(s)
  before allowing the command through) and whether it's desirable, versus
  relying on convention (commit, then run — which is what actually happened
  most of the time this session, but not verified by anything but intent).
- **B4.** A `Stop`-hook analog to `check_edit.sh`/`stop_gate.sh`: should
  ending a McHomeLab session require a green validation run (ansible-lint +
  syntax-check + whatever §A3 lands on)? Design it, following the existing
  precedent's shape.
- **B5.** A no-secrets-committed check, portable from
  `~/workspace/claude/scripts/validate.sh`'s existing invariant of the same
  name — read that check and see if it transfers directly to gate commits in
  a newly-vaulted `McHomeLab-Inventory`.
- **B6.** How do hooks compose with the interactive permission-prompt
  discipline this session actually ran on (every `ansible-playbook` run and
  every commit was confirmed with the user explicitly, turn by turn)? Are
  hooks the *backstop* for when that discipline lapses, or should they be the
  *primary* gate with prompts secondary? Recommend a stance.

## 4. Research Track C — closing this environment's specific gaps

Concrete follow-through items, derived from §1, once A/B produce answers.

- **C1. Turn `McHomeLab-Inventory` into a real git repo.** Blocked on the A1
  secrets decision and on re-asking the user the local-only-vs-private-remote
  question (§1, last bullet) — do not assume either answer.
- **C2.** Convert today's ad hoc bazarr Sonarr/Radarr-address fix into a
  committed, idempotent role task using the A2 pattern.
- **C3.** Formalize this session's scratch render-test playbook into a
  permanent, committed test entry point, per whatever A3 concludes.
- **C4.** Audit for other ad hoc-only state from today that needs to become
  codified: the controller's `docker context media`/`docker context unifi`
  entries (script them rather than leave them as a one-time manual create?);
  the LSCR GitHub PAT's ~2027-08-24 expiry (currently only a doc comment and
  a memory note — should something actually check and alert, extending the
  drift-detection idea from A4 to credentials/certs generally?).
- **C5.** Decide the UniFi-as-code question concretely for the one live
  example already on the table: the decision to run dockerd's mTLS listener
  on media/unifi with **no** compensating firewall rule (documented as a
  choice in `research/RESEARCH_WUD_MTLS.md`, but the choice itself has no
  checkable artifact — just prose). Does "we decided not to add a rule" need
  a codified, verifiable assertion under this ideology, or is documented
  prose sufficient? This is a good small test case for how strict the
  ideology actually needs to be in practice.

## 5. Definition of done for this research pass

- A written decision record (append to this file, or its successor) with
  explicit answers to: the emergency-exception question (§0.5), the secrets
  mechanism (A1), and where `McHomeLab-Inventory` lives (§1, last bullet).
- At least one working, tested `PreToolUse` hook enforcing one concrete rule
  from §3, in the same file layout and JSON-output shape as the
  `~/workspace/claude` precedent, with its own test script mirroring
  `test_hooks.sh`.
- `McHomeLab-Inventory` converted to a revisioned repo, contingent on the
  decisions above.
- `.ansible-lint.yml` bumped to `production` (or stricter, if research finds
  something newer).
- A committed, runnable test entry point replacing the ad hoc scratch-render
  pattern.
- Either a new McHomeLab-specific `CLAUDE.md`, or an addition to the global
  one, stating this ideology as a durable binding rule the way
  `~/workspace/claude/CLAUDE.md` states its own rules — this session operated
  entirely off the *global* file, with no project-level rule of its own.

## 6. Suggested order of work

1. **Ask the user the open question in §0.5, and re-ask the §1 repo-location
   question, before building anything that assumes an answer to either.**
2. Research Tracks A and B — read current docs, do not assert tool status or
   API shape from memory.
3. C1 (inventory → repo) — the load-bearing blocker for "trackable revision
   history to the primary source of truth." Everything else is easier once
   this exists.
4. C2–C5 as time and priority allow.
5. Hook implementation from B2–B4, tested against one deliberately-bad ad hoc
   command (must be denied) and one deliberately-good `ansible-playbook` run
   (must pass), matching the existing `test_hooks.sh` pattern.
6. Write the decision record and the CLAUDE.md addition from §5.

## 7. Provenance

Verified live this session, 2026-08-24: `git status` on both
`~/workspace/McHomeLab` (clean repo) and `~/workspace/McHomeLab-Inventory`
(not a repo); full contents of
`~/workspace/claude/scripts/hooks/guard_bash.sh`; presence/absence of hooks
in `~/workspace/McHomeLab/.claude/settings.json`; size and shape of that
settings file; `.ansible-lint.yml` contents and this session's actual
`ansible-lint` output (passed at `production` profile against a declared
`moderate`); absence of any `molecule*`/`tests/` path in the repo; the
`vmware.vmware` 2.4.0/2.5.0 version-skew warning from a live `ansible-lint`
run. Everything in §2 and §3 is a research question, explicitly not a
verified finding — treat every specific tool/flag/module claim there as
unverified until the fresh session checks it against current documentation.
