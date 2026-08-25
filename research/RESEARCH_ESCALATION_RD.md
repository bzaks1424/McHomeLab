# R-D — Personal-agent escalation interface

Research item opened by the 2026-08-25 decision record (§9 Q10, §11 R-D) in
`RESEARCH_SYSADMIN_AGENT.md`. This document does not modify that file or any
repo file — it is the deliverable requested for R-D and stands on its own.

Date: 2026-08-25.

## 0. What this answers

> **Q10 — Escalation goes through Mike's personal agent, which reaches him.**
> The agent emits findings to an interface (file/queue/message) the personal
> agent consumes; transport to be agreed with that agent (**R-D**). No direct
> HA/email notify from this agent.

> **R-D** (§11): agree the transport with Mike's personal agent (file drop,
> MCP tool, message bus) and the finding schema (severity, host, what/why,
> proposed codified fix, PR link).

`RESEARCH_SYSADMIN_AGENT.md` §6.5 (Unattended mode, written before the
decision record) still says drift notification goes out "via HA `notify`
(deterministic, in the wrapper script, not the model)". **That line
contradicts Q10 as decided** and needs correcting when §6.5 is next edited —
flagged here, not fixed here, since this document does not touch that file.

---

## 1. Local discovery (read-only) — hypotheses about "the personal agent"

Everything in this section is inference from what's on disk and in the
process table today, **not confirmed with Mike**. Treat every claim here as
a hypothesis to validate, not a fact to design against blindly.

### 1.1 `~/workspace/claude` is almost certainly the personal agent's home

- Living-document project (no `git log`), own `CLAUDE.md` ("binding rules"),
  own auto-memory directory
  (`~/.claude/projects/-home-mmcdonnell-workspace-claude/memory/`), own
  `.claude/settings.json` with `SessionStart`/`PreToolUse`/`PostToolUse`/`Stop`
  hooks (`session_context.sh`, `guard_writes.sh`, `guard_bash.sh`,
  `check_edit.sh`, `stop_gate.sh` — the same shape McHomeLab's Phase 2 is
  building, one level ahead).
- Its documents of record are Home Assistant (`todo.md`,
  `lighting-daily-defaults.md`), hardware (`system-inventory.md`), and closed
  `crash-rca-*/RCA.md` incident writeups — i.e. this is Mike's household/HA
  agent, not an infra-as-code project.
- `~/workspace/claude/workspace/` holds `hass-mcp`, `vmware-monitor`,
  `unifly`, `arrspan`, `logspan` — tooling that overlaps with McHomeLab's own
  concerns (UniFi, vCenter, the *arr stack), suggesting this agent already has
  hands in the same infrastructure from the "reach Mike" side.
- **No existing inbox/queue/escalation convention was found anywhere in this
  tree** (`grep -rli` for inbox/escalat/finding/queue turned up only unrelated
  matches — docs, RCA files, an audit command name). R-D is greenfield.

### 1.2 A live process match, not just a plausible directory

`ps aux` at the time of this research showed two long-running interactive
`claude` processes on this machine:

```
claude --chrome --dangerously-skip-permissions --remote-control personal --resume 49a6133a-... (started 08:55)
claude --chrome --dangerously-skip-permissions --remote-control mhl      --resume 88c1942d-... (started 09:08, this session)
```

Each has its own `hass-mcp` and `vmware-monitor` MCP child processes spawned
from `~/workspace/claude/workspace/{hass-mcp,vmware-monitor}/.venv/...` — i.e.
**both sessions load those two MCP servers globally** (confirmed separately:
`~/.claude.json` → `mcpServers: qmd, claude-conversation-search,
vmware-monitor, home-assistant, hass-mcp` at the top level, not per-project).

This is strong (not certain) evidence that:
- `personal` is the session name of Mike's personal agent, launched the way
  this session (`mhl`) was launched, under the same account, on the same
  machine.
- Every session on this machine — the sysadmin agent included — already has
  read/action access to Home Assistant and vCenter via those global MCP
  servers, regardless of which project's `.claude.json`/`settings.json` is in
  play.

**Not verified**: that `personal` literally runs out of `~/workspace/claude`
(inferred from the shared MCP child paths, not read directly from the
process's cwd or from `personal`'s own config) — that requires either asking
Mike or a same-machine `SendMessage`/`/list-agents` handshake, neither of
which this research step performed.

### 1.3 Everything else discovered (read-only, no secrets printed)

| Check | Result |
|---|---|
| `~/workspace/*` CLAUDE.md/README first lines | `brotracker` and `claude-conversation-search-mcp` are git-shaped code projects with their own CLAUDE.md; `~/workspace/claude` is the living-document candidate above; McHomeLab and McHomeLab-Inventory are this project's own two repos; the rest (`erlib`, `psdapi`, `wasdeapi`, `python-app-gen`, `tasmota_mgr`, etc.) show no agent-relevant CLAUDE.md. |
| `~/.claude/agents` | Empty — no globally-defined custom agents. |
| `~/.claude/skills` | Only `exp33` and `unifly` — no escalation/queue-related skill. |
| `~/.claude/settings.json` (global) | No `hooks`, no `mcpServers` key at all — just top-level prefs (`permissions`, `model`, `enabledPlugins`, `effortLevel`, `tui`, `skipDangerousModePermissionPrompt`, **`agentPushNotifEnabled`**). The last key is a hypothesis worth flagging: it implies Claude Code can push mobile/desktop notifications independent of Home Assistant — a possible channel to Mike that isn't "HA notify" and so isn't explicitly ruled out by Q10's wording, but is still a *direct* notify and should be treated as out of scope for this agent per the spirit of Q10 unless Mike says otherwise (see open questions, §6). |
| `~/.claude.json` `mcpServers` (global) | `qmd`, `claude-conversation-search`, `vmware-monitor`, `home-assistant`, `hass-mcp`. No dedicated "personal-agent-facing" MCP server exists today. |
| `systemctl --user list-units --type=service --all \| head -50` | Only stock GNOME/session/desktop services (dbus, gvfs, gnome-session-manager, IBus, keyring, etc.) plus one stray `launchpadlib-cache-clean.timer`. **No custom units** for a personal agent, a message bus, mail, or MQTT — confirms nothing like this is already running as a systemd service on this box. |
| Running `claude` processes | Two interactive sessions (`personal`, `mhl`, detailed in §1.2) plus their MCP children, `claude-conversation-search mcp`, and an unrelated `av2` project background job (`poetry run python -m av2.agent`, different repo, not relevant to this research). |
| Names matching assistant/personal/pa/butler | Only GNOME's `tiling-assistant`, Chrome's `SSLErrorAssistant`, Zoom's `PersonalWallpaper_Thumb`, and `~/workspace/claude/workspace/home-assistant` — none of these are agent infrastructure. The `--remote-control personal` flag (§1.2) is the only real match, and it names a *session*, not a directory. |
| MQTT broker already in the fleet | `hosts.yml` (McHomeLab-Inventory) has `wud_mqtt_url: mqtt://ha.michaelpmcd.com:1883`, `wud_mqtt_user: taz`, and a stored password — already used today by WUD (What's Up Docker) to publish container-update notifications into Home Assistant. This is a **working, authenticated precedent** for the fleet talking to HA over MQTT, not a hypothetical. |
| `~/.mhl` | Confirms it's purely controller-derived state (registry.json, PXE staging, docker-tls certs, homepage/recyclarr configs) — no notify/queue mechanism lives there, consistent with §6.1's "derived, not a home for durable state" framing. |

---

## 2. Transport survey

Scored 1 (poor) – 5 (excellent) on the five axes requested. Every Claude Code
product claim below (hook types, MCP scopes, cross-session messaging) was
checked against a specific page fetched from `code.claude.com/docs` on
2026-08-25; the exact page and its stated version constraints are given per
row via the bracket key and spelled out in full in §2.2. MQTT/HA claims come
from live inventory contents (§1.3), not from a published doc, and are
labeled `[live]`. Anything not backed by either a fetched doc or a live check
this session is labeled `[unverified]` or `[n/a]` (not a Claude-Code-product
claim to begin with) — never silently assumed.

| Option | Durability | Revisioned | Auth | Human-readable | Effort | Source | Notes |
|---|---|---|---|---|---|---|---|
| **Git-based findings queue** (file per finding, committed to a repo) | 5 | 5 | 4 | 5 | 2 | `[n/a]` | Reuses the PR/commit flow already decided in Q2/Q5/Q9b. Not "live" — needs a poll. Plain git/GitHub mechanics, not a Claude Code feature, so there is no code.claude.com page to cite. |
| **Watched-directory file drop + systemd path unit** | 3 | 2 (only if the dir happens to be inside a git repo) | 3 (file perms only) | 4 | 3 | `[unverified]` | A path unit is a real, working Linux primitive, but its behavior here is stated from general systemd knowledge — no systemd doc or Claude Code doc was checked this session, so treat the specifics (reliability, latency, exactly-once semantics) as unverified until tested. |
| **Local MCP server both agents mount** (`submit_finding`/`list_findings`) | Depends on backing store (3–5) | Only if backed by a git-tracked file | 4 | 2 (needs a query, not just `cat`) | 1 | `[MCP]` | Requires writing and maintaining a new server, plus registering it somewhere Claude Code loads it for both sessions. Per the MCP scope table on `[MCP]` (no version constraint stated for the base scope mechanics), a **user**-scoped entry in `~/.claude.json` loads in every project for the OS user — including both `mhl` and `personal` — without touching the personal agent's project-specific `.mcp.json`, but that also means it isn't scoped to just these two agents: it changes shared config every one of Mike's projects picks up. A **project**-scoped `.mcp.json` entry would need to live in whichever project's repo that is, which this research is not authorized to write. Either way, highest effort and broadest blast radius of the read-write options for the least readability gain over a plain file. |
| **HTTP webhook** | 1–3 (nothing persists unless the receiver stores it) | 1 | 2 (needs new TLS/token infra) | 2 | 1 | `[H]` `[CH]` | No inbound HTTP listener exists on either session today. Per `[H]`, Claude Code's `http` hook type is one of five handler types (`command`, `http`, `mcp_tool`, `prompt`, `agent`) and is defined as **outbound-only**: it POSTs the hook's JSON payload to a configured URL and treats the response like a command hook's stdout — it is not a way to push events *into* a session, and the page states no minimum version for this handler type. The only inbound-push mechanism Claude Code ships is **channels** (`[CH]`, explicitly labeled a "research preview" feature on that page), aimed at chat platforms/webhook-receiver plugins — not a good fit for an internal same-machine handoff. A bespoke webhook receiver would also collide with `guard_bash.sh`'s planned deny rule on `curl/wget -X POST/PUT/PATCH/DELETE` to `*.michaelpmcd.com`/`192.168.*` hosts unless carved out (that rule is this project's own design, §6.3 of `RESEARCH_SYSADMIN_AGENT.md`, not a doc claim). |
| **MQTT** (existing broker at `ha.michaelpmcd.com:1883`) | 2 (fire-and-forget unless retained/QoS≥1 and something durably stores it) | 1 | 5 (creds already exist, already used by WUD) | 3 (via HA logbook/entity, not the raw message) | 2 | `[live]` | Zero new infrastructure — the broker, credentials, and the "publish → HA state" pattern were confirmed live in `hosts.yml` (`wud_mqtt_url`, `wud_mqtt_user`) and the `service` role's `wud.yml.j2` template (§1.3), not from any Claude Code or MQTT spec. It only becomes durable if HA itself records it, and only reaches the personal agent if that agent reads that HA state on its own initiative — nothing about MQTT wakes it up. |
| **HA as broker** (write state/attribute HA already exposes to both agents' MCP tools) | 3 (HA history/logbook persistence) | 1 | 5 (both sessions already have `home-assistant`/`hass-mcp` MCP tools globally, per §1.2) | 4 (visible in the HA UI/logbook, which Mike already looks at) | 2 | `[MCP]` `[live]` | The "already shared globally" claim rests on two things together: `[MCP]`'s user-scope definition ("loads in all your projects... stored in `~/.claude.json`") and the live observation (§1.2/§1.3) that `home-assistant`/`hass-mcp`/`vmware-monitor` sit at the top level of this machine's `~/.claude.json`, plus separate `hass-mcp`/`vmware-monitor` child processes under **both** the `personal` and `mhl` PIDs. Writing a `persistent_notification`/`input_text` entity is *storage*, not *notification*, so it can be made Q10-compliant if the sysadmin agent never calls a `notify.*` service itself — that compliance argument is this project's own reasoning about Q10, not a documented Home Assistant or Claude Code guarantee. |
| **Email** | 4 | 1 | 2 (new SMTP secret, and R-A — secrets — hasn't landed yet) | 4 | 2 | `[n/a]` | Structurally this *is* a direct-notify channel to Mike, which is what Q10 says this agent should stop doing. General SMTP/email knowledge, not a Claude Code doc claim. |
| **Cross-session `SendMessage`** *(not in the original list — found during discovery, see §1.2)* | 1 (ephemeral; nothing is stored once delivered, 100-message inbound hold cap, ~5 min `dialogExpiry` default) | 1 | 5 (same-machine delivery is a Unix-domain socket scoped to the OS user, plus a per-session token — exactly the same-machine/same-user trust model the whole hooks design already assumes) | 5 (arrives as plain text directly in the receiving session's transcript) | 1 (the feature already exists, both sessions are already named and live, nothing to build) | `[CSM]` | `[CSM]` states this "requires Claude Code v2.1.224 or later on macOS and Linux, including Linux inside WSL 2" (v2.1.234+ on native Windows) and that the underlying tools are `ListAgents` (discover) and `SendMessage` (deliver by name); the `notify_when_idle` variant "Requires Claude Code v2.1.236 or later in both sessions." Same-machine delivery is described as running "Over a per-session socket on macOS and Linux... never through Anthropic servers," authenticated via OS-user-scoped socket permissions plus a per-session `CLAUDE_CODE_MESSAGING_TOKEN`. Demonstrably active on this exact machine right now (§1.2): this session (`mhl`) has a working `SendMessage` tool, and a session literally named `personal` is live in the process table. **Caveat**: the same page's "Control inbound messages" section says delivery depends on the receiving session's `crossSessionInbound` setting (`accept`/`hold`/`refuse`) and, absent an explicit value, on both sessions' permission-mode class — nothing is queued for a session that isn't running, past the `dialogExpiry` hold window (five minutes by default). Not a substitute for a durable queue; a strong complement to one. |

`[H]` = <https://code.claude.com/docs/en/hooks> · `[HL]` =
<https://code.claude.com/docs/en/headless> · `[CSM]` =
<https://code.claude.com/docs/en/cross-session-messaging> · `[CH]` =
<https://code.claude.com/docs/en/channels> · `[MCP]` =
<https://code.claude.com/docs/en/mcp> — all five fetched 2026-08-25. `[live]`
= verified against this machine/`hosts.yml` this session, not a published
doc. `[n/a]` = not a Claude Code product claim; general/domain knowledge, not
checked against any doc this session. `[unverified]` = claim not backed by
any doc or live check this session; treat as a hypothesis to test in the
Phase 2 PoC (§5), not a fact.

### 2.1 Two more Claude Code claims used elsewhere in this document, cited directly

- **Notification hook** (`[H]`): the `hooks` page lists a `Notification` event
  ("When Claude Code sends a notification") with matcher values including
  `permission_prompt`, `idle_prompt`, `agent_needs_input`, and
  `agent_completed`, no minimum version stated. It was considered and **not
  used**: it fires for a session's own local UI events (its own permission
  prompts, its own idle/completion state), not for delivering an arbitrary
  structured payload from one session into another — `SendMessage` is the
  documented mechanism for that (§2, `[CSM]`), so Notification isn't a
  competing transport, just a different kind of event.
- **`claude -p` (headless)** (`[HL]`, cross-referenced by `[CSM]`): `[HL]`
  documents `-p`/`--print`, `--output-format`, `--allowedTools`,
  `--permission-mode`, `--json-schema`, and `--continue`/`--resume` as
  baseline, version-independent behavior (individual sub-features on that
  page carry their own version notes, e.g. `--bare` "will become the default
  for `-p` in a future release," none of which this document relies on).
  `[CSM]`'s own "Non-interactive sessions" section adds the fact this
  document actually uses: "Claude Code binds an inbox socket for a `claude
  -p` session like an interactive one... so a long-running `-p` worker can
  receive messages," but *not* in `--bare` mode, and a default-held message
  in a `-p` session expires after `dialogExpiry` (five minutes by default)
  unless the session's own `--settings` sets `crossSessionInbound: accept`.
  This is why §4.2 does not lean on `SendMessage` reaching an unattended
  headless run — Q4 already deferred unattended mode, and this independently
  confirms headless delivery would need its own inbound-control
  configuration if Q4 is revisited later.

Channels (`[CH]`) — Telegram/Discord/iMessage/custom webhook-receiver
plugins, pushing external events *into* a running session — were also
checked and ruled out as a poor fit here: the page states they are a
"research preview," require Bun, require installing and pairing a plugin per
channel, and exist to bridge *non-Claude* external systems into a session —
not to let two Claude Code sessions that already speak `SendMessage` talk to
each other. Not scored in the table; ruled out on maturity and mismatch of
purpose.

---

## 3. Proposed finding schema

One file per finding, JSON as source of truth with a rendered Markdown
sibling for humans — the same file-pair convention already used for other
McHomeLab artifacts (e.g. render + check outputs).

### 3.1 JSON

```json
{
  "id": "F-2026-08-25-0001",
  "timestamp": "2026-08-25T14:32:00-05:00",
  "severity": "warning",
  "host": "util",
  "category": "expiry",
  "summary": "LSCR (linuxserver.io) PAT used by WUD expires in 14 days",
  "evidence": [
    "registry.json: lscr_pat_expiry = 2026-09-08",
    "ansible-playbook site.yml --check --diff excerpt: <path or inline>"
  ],
  "proposed_codified_fix": {
    "description": "Rotate the LSCR PAT and update the vaulted var in hosts.yml; no role change needed.",
    "role_or_var_touched": "McHomeLab-Inventory: all.vars.lscr_pat",
    "pr_url": null
  },
  "pr_url": null,
  "ack": {
    "state": "open",
    "by": null,
    "at": null,
    "note": null
  },
  "source_agent": "mhl",
  "source_session": "88c1942d-e0ba-401f-8b7d-728a2b21f702"
}
```

Field notes:
- `severity`: `info` | `warning` | `critical` — drives whether a live
  `SendMessage` nudge is sent at all (§4; avoid message-loop throttling on
  routine `info` findings).
- `category`: exactly the four from Q10/R-D plus `incident` per Q1's separate
  incident-record convention — `expiry | drift | validation | incident |
  proposal`. An `incident` finding cross-references the
  `INCIDENT-<date>-<slug>.md` file Q1 already mandates rather than
  duplicating it.
- `ack.state`: `open` → `acked` (personal agent/Mike has seen it) →
  `resolved` (fix applied/PR merged) | `dismissed` (Mike decided no action).
  This is the field the personal agent (or Mike through it) writes back.
- `source_session`: lets a human trace a finding back to the exact
  transcript that produced it.

### 3.2 Markdown rendering (per-finding file, generated from the JSON)

```markdown
## F-2026-08-25-0001 — WARNING — expiry — util

**When:** 2026-08-25 14:32 CDT
**State:** open

LSCR (linuxserver.io) PAT used by WUD expires in 14 days.

**Evidence**
- registry.json: `lscr_pat_expiry = 2026-09-08`
- `ansible-playbook site.yml --check --diff` excerpt: ...

**Proposed codified fix**
Rotate the LSCR PAT and update the vaulted var in hosts.yml; no role change
needed. (touches: `McHomeLab-Inventory: all.vars.lscr_pat`)

**PR:** none yet
```

Plus a single running `findings/INDEX.md` table (id, timestamp, severity,
host, category, one-line summary, state) so a human can scan open items
without opening every file — the same "index + detail file" shape as
`incidents/` will already use per Q1.

---

## 4. Recommendation

### 4.1 Primary — git-committed findings queue in `McHomeLab-Inventory`

Add `findings/` to `McHomeLab-Inventory` (the private repo, already the
target of the Q2 remote-URL interface and the Q5 PR workflow). The sysadmin
agent writes `findings/<id>.json` + `findings/<id>.md`, updates
`findings/INDEX.md`, and commits/pushes — through the same `scripts/mhl-pr`
adapter Q2 already calls for, so a findings-only push isn't a new code path.

Why this and not one of the others: it's the only option that is
simultaneously durable, revisioned, human-readable, and buildable with **zero
new infrastructure, zero new secrets, and zero changes to the personal
agent's own config** on the writing side. It also matches Rule 1 from the
global working rules directly — durable state belongs in the ledger of the
project shaped like a ledger, and `McHomeLab-Inventory` already is one.

Because it's a *poll*, not a *push*, delivery depends on the personal agent
choosing to look — which is where the fallback comes in.

### 4.2 Fallback / complement — cross-session `SendMessage` nudge

Whenever the sysadmin agent writes a new `open` finding at `warning` or
`critical` severity, it also calls `SendMessage(to="personal", message="New
finding <id> (<severity>/<category>) on <host>: <summary>. See
McHomeLab-Inventory/findings/<id>.md")` as an ordinary tool call in the same
turn. Per `[CSM]` (<https://code.claude.com/docs/en/cross-session-messaging>,
fetched 2026-08-25, "requires Claude Code v2.1.224 or later on macOS and
Linux") this costs nothing to build — the tool already exists and the target
session is already reachable by name, empirically confirmed live on this
machine (§1.2) — and gets a finding in front of Mike immediately whenever
both sessions happen to be live — which, because Q4 deferred
unattended/headless mode, is close to "always" for now: findings are only
produced during an interactive `mhl` session Mike is actively driving.

The nudge is deliberately **not** the source of truth: `[CSM]`'s "Control
inbound messages" section documents that if `personal` isn't running, isn't
reachable, or its `crossSessionInbound` setting holds/refuses the message,
Claude Code drops or expires it (default `dialogExpiry` of five minutes for
a held message) rather than queuing it indefinitely — so nothing about this
channel is durable on its own. Because of that, this design treats
`SendMessage` purely as a best-effort doorbell: if it doesn't ring, the
finding still sits in the git queue and surfaces the next time the personal
agent's own `SessionStart` hook polls it (§5). `info`-severity findings skip
the nudge entirely and rely on the queue alone, both to respect `[CSM]`'s
documented rate limits (burst refusal, a 50-message accepted-queue cap, and
repeat suppression, all stated on that page) and to avoid training Mike to
ignore routine pings.

This two-layer design is also the direct fix for §6.5's stale "HA `notify`"
line: nothing here calls an HA `notify.*` service or emails Mike directly:
the sysadmin agent only ever writes to its own repo and messages one other
Claude Code session — the personal agent decides, on its own terms, how (or
whether) that becomes something Mike sees.

---

## 5. Minimal Phase 2 PoC design

1. **McHomeLab-Inventory**: add `findings/` (empty, with a `SCHEMA.md`
   documenting §3's JSON shape) and `findings/INDEX.md` (header row only).
   One-line addition to that repo's README pointing at the convention.
2. **McHomeLab**: extend the `scripts/mhl-pr` adapter (already planned per
   Q2) with a `mhl-pr finding <json-file>` mode that renders the Markdown
   sibling, updates `INDEX.md`, and commits/pushes to
   `McHomeLab-Inventory`. Add one line to `.claude/rules/governance.md` (also
   already planned): "an `open` finding at `warning`/`critical` severity gets
   a `SendMessage(to="personal", ...)` nudge in the same turn it's written;
   `info` findings do not."
3. **`~/workspace/claude` (coordinate with its owner/config, do not edit
   unilaterally)**: propose one addition to its existing
   `session_context.sh` `SessionStart` hook — `git -C
   ~/workspace/McHomeLab-Inventory fetch --quiet && ls findings/*.json`
   filtered to `ack.state == "open"`, diffed against a locally-kept
   "last-seen" marker in that workspace (it has no git ledger of its own per
   Rule 1, so the marker is a plain file, e.g.
   `~/workspace/claude/.findings-last-seen`), surfaced into the injected
   session context the same way `session_context.sh` already surfaces "git
   state of both repos". This is the guaranteed-eventual-delivery path when
   the `SendMessage` nudge missed its window.
4. **Test end-to-end**: write one synthetic `info`-severity finding by hand,
   confirm it commits cleanly and appears in `INDEX.md`; write one
   `warning`-severity finding as the `mhl` session and confirm (a) the
   `SendMessage` arrives in the live `personal` session's transcript today,
   and (b) stopping `personal`, writing another finding, then restarting
   `personal` surfaces it via the proposed `SessionStart` addition instead.
5. **Round-trip (ack)**: decide, as one of the open questions below, whether
   the personal agent (or Mike through it) writes `ack.state` back into
   `McHomeLab-Inventory` directly — which needs its own git credentials and a
   `guard_writes`-equivalent carve-out on that side — or whether it only ever
   relays to Mike and the `mhl` session records the ack next time it runs
   `/drift` or opens a PR referencing the finding's id.

Nothing above touches a live host, a secret, or the personal agent's config —
it's additive to `McHomeLab-Inventory` and (pending agreement) an opt-in
addition to `~/workspace/claude`'s own hook.

---

## 6. Questions for the personal agent's owner/config

All of these are Mike's calls about the *other* project, which this research
did not touch:

1. Is `personal` (§1.2) actually the intended recipient, and does it in fact
   live at `~/workspace/claude`? (Inferred, not confirmed — see §1.2's
   "not verified" note.)
2. Is that session expected to be running near-continuously, or only when
   Mike is actively at the terminal? This determines how much weight the
   `SendMessage` nudge can carry versus the git-queue poll.
3. What is that session's own `crossSessionInbound` setting today
   (`accept`/`hold`/`refuse`, or unset/default)? An unset default holds a
   message for approval whenever the *sending* session identifies as
   bypassing permission prompts — and `mhl` runs with
   `--dangerously-skip-permissions`, which is exactly that case — so an
   unprompted nudge from this agent may currently sit in an approval dialog
   rather than deliver silently.
4. Should `~/workspace/claude` gain a "sysadmin-agent escalations" document
   of record (per its own Rule 1: "each subject area owns one document"), or
   should it treat `McHomeLab-Inventory/findings/` as that document of record
   and never duplicate its contents locally?
5. Should the personal agent (or Mike through it) write `ack`/`resolved`
   state back into `McHomeLab-Inventory` directly, requiring its own git
   credentials and a write carve-out — or only relay to Mike, leaving the
   `mhl` session to record acknowledgement next time it runs?
6. What severity threshold, if any, should page Mike immediately (phone/
   desktop) versus wait for him to next open the personal agent? Does the
   `agentPushNotifEnabled` mobile-push channel discovered in §1.3 count as
   "direct notify" that Q10 rules out for critical/incident findings, or is
   it acceptable for the *personal* agent to use once it has decided a
   finding warrants it (as opposed to the sysadmin agent using it directly,
   which Q10 clearly forbids)?
7. Should the escalation interface be robust to `personal`'s session name
   changing across restarts (the docs note Claude Code can rename a session
   to a variant on a collision, or Mike can `/rename` it) — e.g. by having
   the sysadmin agent re-resolve the name each time rather than hardcoding
   it, which is already consistent with this project's "no hardcoded
   hostnames" convention for the registry system?
8. Confirm the two MCP servers both sessions already share globally
   (`home-assistant`, `hass-mcp`, `vmware-monitor`, per §1.2/§1.3) are
   intentional and not an artifact of shared machine-wide config that Mike
   would rather scope per-project.

## 7. Correction (2026-08-25, from Mike)

The Synology share `Backups/claude` (`/media/Backups/claude` on Linux) is a
**separate** Claude↔Claude channel (identities `desktop`, `a8`, `researcher`)
— **not** the personal-agent transport. The personal agent is the Claude Code
session run under `--remote-control personal`; reach it via cross-session
`SendMessage` (§4.2). At the time of checking, `ListAgents` from this session
showed only peer `claude-8a`, so the `personal` session is not always
discoverable — which is exactly why the git-committed findings queue (§4.1)
stays primary. The share's `researcher` identity is available for research
questions (write one file to `inbox-researcher/`, per its README); it never
mutates anything and is not part of the escalation path.
