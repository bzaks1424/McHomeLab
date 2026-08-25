#!/usr/bin/env bash
# PreToolUse[Write|Edit|NotebookEdit]: the rules a file path alone can decide.
# Everything else is judgement and stays with the model. Fails closed.
#
# Live enforcement runs from the INSTALLED copy (~/.mhl/hooks, populated from
# main by scripts/mhl-install-hooks), so editing the repo copies on a branch
# changes nothing until merged and installed. The two files that still take
# effect live — .claude/settings.json and CLAUDE.md — need Mike's approval
# per change (review M2).
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "guard_writes: jq missing — refusing to run unguarded" >&2; exit 2; }
REPO="$HOME/workspace/McHomeLab"; INV="$HOME/workspace/McHomeLab-Inventory"
MEM="$HOME/.claude/projects/-home-mmcdonnell-workspace-McHomeLab/memory"
RAW=$(cat | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""') || exit 2
[ -z "$RAW" ] && exit 0
P=$(realpath -m "$RAW")
deny() { jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
case "$P" in
  "$HOME"/.mhl/vault/*|"$HOME"/.mhl/bin/*|"$HOME"/.mhl/hooks/*) deny "~/.mhl/{vault,bin,hooks} are installed from the repo (scripts/mhl-install-hooks, controller role), never edited in place." ;;
  "$HOME"/.mhl/*) deny "~/.mhl is derived state (registry, exports, staging) — regenerate by running site.yml; never hand-edit." ;;
  /opt/docker/*|/opt/containers/*|/etc/*) deny "that is a managed host path. Declare the change in hosts.yml or a role." ;;
  "$REPO"/.claude/settings.json|"$REPO"/CLAUDE.md)
    # Mike approves by running:  touch ~/.mhl/approvals/<basename>   (valid 30 minutes, one-shot)
    T="$HOME/.mhl/approvals/$(basename "$P")"
    if [ -f "$T" ] && [ "$(( $(date +%s) - $(stat -c %Y "$T") ))" -lt 1800 ]; then rm -f "$T"; exit 0; fi
    deny "settings.json and CLAUDE.md take effect live: ask Mike to run  touch ~/.mhl/approvals/$(basename "$P")  (30-minute, one-shot approval), then retry (review M2)." ;;
  "$HOME"/.claude/settings.json|"$HOME"/.claude/settings.local.json|"$HOME"/.claude/CLAUDE.md|"$HOME"/.claude/agents/*|"$HOME"/.claude/skills/*|"$HOME"/.claude/hooks/*) deny "user-level Claude settings/agents/skills are not this project's to change (rule 8)." ;;
  "$REPO"/archive/*) deny "archive/ is read-only provenance; restore from it into a live path via a PR instead." ;;
  "$REPO"/ansible/collections/*) deny "ansible/collections is installed by make deps from requirements.yml." ;;
  "$REPO"/*|"$INV"/*|"$MEM"/*|/tmp/claude-*/*|/tmp/mhl-*) exit 0 ;;
  *) deny "writes are confined to the two McHomeLab repos, the project memory dir and the scratchpad (rule 8)." ;;
esac
