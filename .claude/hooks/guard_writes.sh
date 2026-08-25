#!/usr/bin/env bash
# PreToolUse[Write|Edit|NotebookEdit]: the rules a file path alone can decide.
# Everything else is judgement and stays with the model. Fails closed.
#
# Live enforcement runs from the INSTALLED copy (~/.mhl/hooks, populated from
# main by scripts/mhl-install-hooks), so editing the repo copies on a branch
# changes nothing until merged and installed.
#
# Default-deny for everything that DEFINES what runs without a prompt or what
# a guard inspects: the whole .claude/ tree except hooks/ (repo copies, inert
# until installed), CLAUDE.md/CLAUDE.local.md, .mcp.json, Makefile (targets
# can be allow-listed), the hook test harness, the git hooks and their
# installer. settings.json and CLAUDE.md are editable with Mike's one-shot
# token (touch ~/.mhl/approvals/<basename>, 30 min); the rest change only on
# a branch via `git` (checkout/apply) — i.e. never silently by the agent.
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "guard_writes: jq missing — refusing to run unguarded" >&2; exit 2; }
REPO="$HOME/workspace/McHomeLab"; INV="$HOME/workspace/McHomeLab-Inventory"
MEM="$HOME/.claude/projects/-home-mmcdonnell-workspace-McHomeLab/memory"
RAW=$(cat | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""') || exit 2
[ -z "$RAW" ] && exit 0
P=$(realpath -m "$RAW")
deny() { jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
token_ok() { # one-shot, 30-minute approval from Mike
  local t="$HOME/.mhl/approvals/$1"
  if [ -f "$t" ] && [ "$(( $(date +%s) - $(stat -c %Y "$t") ))" -lt 1800 ]; then rm -f "$t"; return 0; fi
  return 1
}
case "$P" in
  "$HOME"/.mhl/vault/*|"$HOME"/.mhl/bin/*|"$HOME"/.mhl/hooks/*|"$HOME"/.mhl/approvals/*) deny "~/.mhl/{vault,bin,hooks,approvals} are installed/created outside the agent (scripts/mhl-install-hooks, controller role, Mike), never edited in place." ;;
  "$HOME"/.mhl/*) deny "~/.mhl is derived state (registry, exports, staging) — regenerate by running site.yml; never hand-edit." ;;
  /opt/docker/*|/opt/containers/*|/etc/*) deny "that is a managed host path. Declare the change in hosts.yml or a role." ;;
  "$REPO"/.claude/settings.json|"$REPO"/CLAUDE.md)
    token_ok "$(basename "$P")" && exit 0
    deny "$(basename "$P") takes effect live: ask Mike to run  touch ~/.mhl/approvals/$(basename "$P")  (30-minute, one-shot approval), then retry (review M2)." ;;
  "$REPO"/.claude/hooks/*.sh) exit 0 ;;   # repo copies: inert until installed from main
  "$REPO"/.claude/*|"$REPO"/CLAUDE.local.md|"$REPO"/.mcp.json|"$REPO"/Makefile|"$REPO"/scripts/hooks/*|"$REPO"/scripts/git-hooks/*|"$REPO"/scripts/mhl-install-hooks)
    deny "$(realpath --relative-to="$REPO" "$P") defines what runs unprompted or what the guards check (agents, skills, rules, settings.local.json, Makefile, git hooks, harness). Not editable by the agent; propose the change to Mike and land it via a PR he applies (review BL2)." ;;
  "$HOME"/.claude/settings.json|"$HOME"/.claude/settings.local.json|"$HOME"/.claude/CLAUDE.md|"$HOME"/.claude/agents/*|"$HOME"/.claude/skills/*|"$HOME"/.claude/hooks/*|"$HOME"/.claude.json) deny "user-level Claude settings/agents/skills are not this project's to change (rule 8)." ;;
  "$REPO"/archive/*) deny "archive/ is read-only provenance; restore from it into a live path via a PR instead." ;;
  "$REPO"/ansible/collections/*) deny "ansible/collections is installed by make deps from requirements.yml." ;;
  "$REPO"/*|"$INV"/*|"$MEM"/*|/tmp/claude-*/*|/tmp/mhl-*) exit 0 ;;
  *) deny "writes are confined to the two McHomeLab repos, the project memory dir and the scratchpad (rule 8)." ;;
esac
