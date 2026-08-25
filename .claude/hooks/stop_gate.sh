#!/usr/bin/env bash
# Stop: (a) make validate green, (b) no open incident with uncodified parameter
# changes, (c) memory touched today. Fails open once per day so a reminder
# can't loop — "a reminder that can loop is a reminder that gets disabled."
set -uo pipefail
ROOT="$HOME/workspace/McHomeLab"; INV="$HOME/workspace/McHomeLab-Inventory"
MEMDIR="$HOME/.claude/projects/-home-mmcdonnell-workspace-McHomeLab/memory"
TODAY=$(date +%F)
[ "$(cat "$MEMDIR/.stop-gate-fired" 2>/dev/null)" = "$TODAY" ] && exit 0
R=""
if ! (cd "$ROOT" && timeout 300 make validate >/tmp/mhl-validate.log 2>&1); then
  R="make validate is RED (rule 2):"$'\n'"$(grep -E 'FAIL|Failed|fatal|error' /tmp/mhl-validate.log | head -8)"
fi
OPEN=$(grep -lE '^status:[[:space:]]*open' "$INV"/incidents/INCIDENT-*.md 2>/dev/null | xargs -r -n1 basename)
[ -n "$OPEN" ] && R="$R"$'\n'"open incident(s) (Q1) — codify the parameter changes or close them: $OPEN"
[ "$(cat "$MEMDIR/.last-validated" 2>/dev/null)" != "$TODAY" ] && R="$R"$'\n'"memory not touched today (rule 5): write/update memory files + MEMORY.md, then: date +%F > $MEMDIR/.last-validated"
R=$(printf '%s' "$R" | sed '/^$/d')
[ -z "$R" ] && exit 0
echo "$TODAY" > "$MEMDIR/.stop-gate-fired"
jq -n --arg r "$R" '{decision:"block",reason:$r}'
