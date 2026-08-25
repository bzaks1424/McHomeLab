#!/usr/bin/env bash
# Stop: (a) make validate green, (b) no open incident, (c) memory touched today.
# Each condition has its OWN once-per-day fail-open marker, so the memory
# reminder cannot consume the validate gate's marker (review M1).
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "stop_gate: jq missing" >&2; exit 2; }
REPO="$HOME/workspace/McHomeLab"; INV="$HOME/workspace/McHomeLab-Inventory"
MEMDIR="$HOME/.claude/projects/-home-mmcdonnell-workspace-McHomeLab/memory"
TODAY=$(date +%F); R=""
fired() { [ "$(cat "$MEMDIR/.stop-gate-$1" 2>/dev/null)" = "$TODAY" ]; }
mark()  { echo "$TODAY" > "$MEMDIR/.stop-gate-$1"; }

# validate and incidents are GATES: they block every time while red (review
# BL3). Only the memory reminder fails open once per day, because a reminder
# that can loop is a reminder that gets disabled — a gate is not a reminder.
if ! (cd "$REPO" && timeout 300 make validate >/tmp/mhl-validate.log 2>&1); then
  R="make validate is RED (rule 4):"$'\n'"$(grep -E 'FAIL|Failed|fatal|error|Error' /tmp/mhl-validate.log | head -8)"
fi
OPEN=$(grep -lE '^status:[[:space:]]*open' "$INV"/incidents/INCIDENT-*.md 2>/dev/null | xargs -r -n1 basename)
[ -n "$OPEN" ] && R="$R"$'\n'"open incident(s) (rule 2) — codify the parameter changes or close them: $OPEN"
if ! fired memory; then
  [ "$(cat "$MEMDIR/.last-validated" 2>/dev/null)" != "$TODAY" ] && { R="$R"$'\n'"memory not touched today (rule 10): write/update memory files + MEMORY.md, then: date +%F > $MEMDIR/.last-validated"; mark memory; }
fi
R=$(printf '%s' "$R" | sed '/^$/d')
[ -z "$R" ] && exit 0
jq -n --arg r "$R" '{decision:"block",reason:$r}'
