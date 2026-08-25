#!/usr/bin/env bash
# Stop: (a) make validate green, (b) no open incident, (c) memory touched today.
# Each condition has its OWN once-per-day fail-open marker, so the memory
# reminder cannot consume the validate gate's marker (review M1).
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "stop_gate: jq missing" >&2; exit 2; }
REPO=$(realpath -m "${MHL_REPO:-$HOME/workspace/McHomeLab}"); INV=$(realpath -m "${MHL_INVENTORY:-$HOME/workspace/McHomeLab-Inventory}")
MEMDIR="$HOME/.claude/projects/-home-mmcdonnell-workspace-McHomeLab/memory"
PAYLOAD=$(cat 2>/dev/null || true)
ROOT="$REPO"
# Scope: these hooks are wired from USER settings, so they run in every Claude
# session on this machine. They act only when the session is inside McHomeLab
# or the inventory; elsewhere they allow everything (review round-3 addendum).
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // ""')
case "$CWD" in "$ROOT"|"$ROOT"/*|"$INV"|"$INV"/*) ;; *) exit 0 ;; esac
TODAY=$(date +%F); R=""
fired() { [ "$(cat "$MEMDIR/.stop-gate-$1" 2>/dev/null)" = "$TODAY" ]; }
mark()  { echo "$TODAY" > "$MEMDIR/.stop-gate-$1"; }

# validate and incidents are GATES: they block every time while red (review
# BL3). Only the memory reminder fails open once per day, because a reminder
# that can loop is a reminder that gets disabled — a gate is not a reminder.
if ! (cd "$REPO" && timeout 300 make validate >/tmp/mhl-validate.log 2>&1); then
  R="make validate is RED (rule 4):"$'\n'"$(grep -E 'FAIL|Failed|fatal|error|Error' /tmp/mhl-validate.log | head -8)"
fi
for sf in "$REPO/.claude/settings.local.json" "$REPO/.claude/settings.json" "$HOME/.claude/settings.local.json" "$HOME/.claude/settings.json"; do
  [ -f "$sf" ] && jq -e '.disableAllHooks == true' "$sf" >/dev/null 2>&1 && R="$R"$'\n'"disableAllHooks is set in $sf — guards are off; remove it (rule 1)"
done
# Integrity of the live enforcement set. The checker itself failing to run is a block
# (fail closed), never a skipped check.
if [ -x "$REPO/scripts/mhl-manifest" ]; then
  MOUT=$("$REPO/scripts/mhl-manifest" check 2>&1); MRC=$?
  [ "$MRC" -ne 0 ] && R="$R"$'\n'"governance integrity ($("$REPO/scripts/mhl-manifest" mode 2>/dev/null)): $(printf '%s' "$MOUT" | head -4)"
else
  R="$R"$'\n'"governance integrity checker missing ($REPO/scripts/mhl-manifest) — cannot verify the enforcement set"
fi
OPEN=$(grep -lE '^status:[[:space:]]*open' "$INV"/incidents/INCIDENT-*.md 2>/dev/null | xargs -r -n1 basename)
[ -n "$OPEN" ] && R="$R"$'\n'"open incident(s) (rule 2) — codify the parameter changes or close them: $OPEN"
if ! fired memory; then
  [ "$(cat "$MEMDIR/.last-validated" 2>/dev/null)" != "$TODAY" ] && { R="$R"$'\n'"memory not touched today (rule 10): write/update memory files + MEMORY.md, then: date +%F > $MEMDIR/.last-validated"; mark memory; }
fi
R=$(printf '%s' "$R" | sed '/^$/d')
[ -z "$R" ] && exit 0
jq -n --arg r "$R" '{decision:"block",reason:$r}'
