#!/usr/bin/env bash
# PreToolUse[Write|Edit|NotebookEdit]: the rules a file path alone can decide.
# Everything else is judgement and stays with the model.
set -uo pipefail
P=$(cat | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)
[ -z "$P" ] && exit 0
deny() { jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
case "$P" in
  "$HOME"/.mhl/vault/*|"$HOME"/.mhl/bin/*) deny "controller secrets/tools under ~/.mhl/{vault,bin} are created by the controller role from scripts/, not edited in place." ;;
  "$HOME"/.mhl/*) deny "~/.mhl is derived state (registry, exports, staging) — regenerate by running site.yml; never hand-edit." ;;
  /opt/docker/*|/opt/containers/*|/etc/*) deny "that is a managed host path. Declare the change in hosts.yml or a role." ;;
  "$HOME"/workspace/McHomeLab/archive/*) deny "archive/ is read-only provenance; restore from it into a live path via a PR instead." ;;
  "$HOME"/workspace/McHomeLab/ansible/collections/*) deny "ansible/collections is installed by make deps from requirements.yml." ;;
  "$HOME"/workspace/McHomeLab/*|"$HOME"/workspace/McHomeLab-Inventory/*|"$HOME"/.claude/*|/tmp/claude-*/*|/tmp/mhl-*) exit 0 ;;
  *) deny "writes are confined to the two McHomeLab repos, ~/.claude and the scratchpad (rule 4)." ;;
esac
