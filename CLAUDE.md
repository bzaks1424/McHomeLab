# McHomeLab — binding project rules

These are non-negotiable. Hooks enforce what a command or path alone can decide
(`.claude/hooks/`, tested by `scripts/hooks/test_hooks.sh`); the rest is on you.
**Live enforcement = user-scope hooks (`~/.claude/settings.json`, Mike's file;
reference block `scripts/hooks/user-settings-hooks.json`) running the installed
copies in `~/.mhl/hooks/`**, populated from `main` by `scripts/mhl-install-hooks`
after a governance PR merges. Editing `.claude/hooks/*` on a branch changes
nothing until then; `make hooks-installed` verifies what is actually enforcing.
Files that define what runs unprompted or what the guards check (`.claude/*`
other than `hooks/`, `Makefile`, the harness, git hooks, installer, `.mcp.json`)
are not editable by the agent. `.claude/settings.json` and `CLAUDE.md` are
edited only after Mike runs `touch ~/.mhl/approvals/<file>` (one-shot, 30 min).
Fleet-touching commands are always invoked directly (never via `make`), so the
Bash guard sees every real command.
The global `~/.claude/CLAUDE.md` still applies; this file is more specific.
Design, decisions and the organization strategy: `research/RESEARCH_SYSADMIN_AGENT.md`
(§9 decisions, §13 where things live). Ideology: `research/RESEARCH_ANSIBLE_GOVERNANCE.md` §0.

1. **No change to the lab without revision history.** Anything that changes a
   host, container, appliance, network device, certificate, or the controller's
   own state is expressed as a change to a role or `hosts.yml`, lands via a pull
   request, and is applied by `site.yml`. Never `ssh host "docker …"`, never
   `ansible host -m shell|uri|copy`, never a write-method `curl` to a lab API,
   never `step ca certificate` outside `roles/step-ca-cert`. Reads are free.
2. **Emergencies get an incident record, always.** If service is down and a
   manual action cannot wait: write
   `McHomeLab-Inventory/incidents/INCIDENT-<YYYY-MM-DD>-<slug>.md` first
   (`status: open`), take the action, record exactly what was done. A restart is
   allowed; any parameter/config change must then be codified before the
   incident is closed. The Stop gate blocks while an incident is open.
3. **PR workflow, both repos.** Branch → commit → `scripts/mhl-pr` → Mike
   reviews. Never commit on the default branch, never push to it. `site.yml`
   (without `--check`) runs only from a committed tree. Never `--limit site.yml`.
4. **`make validate` is "done".** yamllint, ansible-lint (`production`), syntax,
   offline render + `docker compose config`, no-secrets, hook tests. Red output
   is quoted verbatim, never summarised; a check is never loosened to pass.
5. **Secrets.** Every secret is an inline `!vault` value (vault-id `mhl`) in
   `hosts.yml` or a vault-encrypted side file. Password source:
   `~/.mhl/bin/mhl-vault-client` → `~/.mhl/vault/mhl.pass` (escrowed in Mike's
   password safe). Never print a secret value; `scripts/mhl-no-secrets` redacts.
   Writing files whose *content* contains guarded patterns (e.g. hook scripts)
   must use the Write/Edit tools, not a Bash heredoc — the Bash guard reads the
   whole command text.
6. **Three buckets.** Source (roles, `hosts.yml`) is hand-edited via PR. Derived
   (`~/.mhl`, rendered compose, `ansible/collections`) is regenerated, never
   edited. Ephemeral (container health, DNS answers) is observed only.
   Backups (restore-and-run artefacts) live on the Synology `HomeLabBackup`
   share with a manifest in the inventory repo; configuration lives in git.
7. **The live system is the authority.** Read it before asserting; confirm
   first-pass output against a second source; report disagreement between
   live state and documents, never average them.
8. **Non-destructive by default.** Retire to `archive/` with a README row.
   Each destructive step is confirmed individually, even inside an approved plan.
9. **Escalation** goes to Mike's `personal` session (cross-session
   `SendMessage`) with a committed finding in `McHomeLab-Inventory/findings/`
   as the durable record — never direct HA/email notifications.
10. **Memory.** Significant findings, decisions and corrections go to the
    auto-memory with a `MEMORY.md` pointer; touch `memory/.last-validated` daily.
11. **Honesty.** "Verified" = read live this session. "Documented" = read a
    file. Say what was skipped, assumed, or could not be verified.
