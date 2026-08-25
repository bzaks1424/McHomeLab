#!/usr/bin/env bash
# SessionStart: inject the state a fresh session needs before it acts.
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "session_context: jq missing" >&2; exit 2; }
REPO="$HOME/workspace/McHomeLab"; INV="$HOME/workspace/McHomeLab-Inventory"
ctx() {
  for repo in "$REPO" "$INV"; do
    n=$(basename "$repo"); b=$(git -C "$repo" branch --show-current 2>/dev/null); d=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l)
    h=$(git -C "$repo" config core.hooksPath 2>/dev/null); echo "$n: branch=$b dirty_files=$d hooksPath=${h:-UNSET (run scripts/mhl-install-hooks)}"
  done
  if [ -d "$HOME/.mhl/hooks" ]; then
    for f in "$REPO"/.claude/hooks/*.sh; do cmp -s "$f" "$HOME/.mhl/hooks/$(basename "$f")" || echo "installed hook differs from repo: $(basename "$f") (expected while a governance branch is unmerged)"; done
  else echo "installed hooks MISSING (~/.mhl/hooks) — governance is not active; run scripts/mhl-install-hooks from main"; fi
  op=$(grep -lE '^status:[[:space:]]*open' "$INV"/incidents/INCIDENT-*.md 2>/dev/null | wc -l); echo "open incidents: $op"
  [ -r "$HOME/.mhl/vault/mhl.pass" ] && echo "vault: password file present" || echo "vault: MISSING ~/.mhl/vault/mhl.pass — restore from Mike's password safe"
  pv=$(ls "$HOME/.mhl/pre-vault" 2>/dev/null | wc -l); [ "$pv" -gt 0 ] && echo "pre-vault: $pv plaintext backup(s) pending — escrow, verify, then scripts/mhl-vault-file --purge <inventory>"
  echo "share inbox: re-arm the 15-minute Monitor on /media/Backups/claude/tools/check-inbox.sh mchomelab (see memory)."
  echo "Binding: CLAUDE.md — no change to the lab without a committed role/inventory change landed via PR; reads are free; site.yml applies only from a committed tree; emergencies need incidents/INCIDENT-<date>-<slug>.md; make validate must be green before you stop."
}
jq -n --arg c "$(ctx 2>/dev/null)" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
