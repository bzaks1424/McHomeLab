#!/usr/bin/env bash
# SessionStart: inject the state a fresh session needs before it acts.
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "session_context: jq missing" >&2; exit 2; }
REPO=$(realpath -m "${MHL_REPO:-$HOME/workspace/McHomeLab}"); INV=$(realpath -m "${MHL_INVENTORY:-$HOME/workspace/McHomeLab-Inventory}")
PAYLOAD=$(cat 2>/dev/null || true)
ROOT="$REPO"
# Scope: these hooks are wired from USER settings, so they run in every Claude
# session on this machine. They act only when the session is inside McHomeLab
# or the inventory; elsewhere they allow everything (review round-3 addendum).
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // ""')
case "$CWD" in "$ROOT"|"$ROOT"/*|"$INV"|"$INV"/*) ;; *) exit 0 ;; esac
ctx() {
  for repo in "$REPO" "$INV"; do
    n=$(basename "$repo"); b=$(git -C "$repo" branch --show-current 2>/dev/null); d=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l)
    h=$(git -C "$repo" config core.hooksPath 2>/dev/null); echo "$n: branch=$b dirty_files=$d hooksPath=${h:-UNSET (run scripts/mhl-install-hooks)}"
  done
  # Guards are active only if BOTH the installed copies exist AND user-scope settings wire them.
  missing=""
  for f in "$REPO"/.claude/hooks/*.sh; do
    n=$(basename "$f"); [ -x "$HOME/.mhl/hooks/$n" ] || missing="$missing $n"
    jq -e --arg c "bash \$HOME/.mhl/hooks/$n" '[.hooks // {} | to_entries[] | .value[] | .hooks[]?.command] | index($c) != null' "$HOME/.claude/settings.json" >/dev/null 2>&1 || missing="$missing $n(not-wired)"
    [ -x "$HOME/.mhl/hooks/$n" ] && ! cmp -s "$f" "$HOME/.mhl/hooks/$n" && echo "installed hook differs from repo: $n (expected while a governance branch is unmerged)"
  done
  # Any scope can carry disableAllHooks (project-local outranks user scope on 2.1.245): check them all.
  for sf in "$REPO/.claude/settings.local.json" "$REPO/.claude/settings.json" "$HOME/.claude/settings.local.json" "$HOME/.claude/settings.json"; do
    [ -f "$sf" ] && jq -e '.disableAllHooks == true' "$sf" >/dev/null 2>&1 && missing="$missing disableAllHooks-in-$(basename "$(dirname "$sf")")/$(basename "$sf")"
  done
  if [ -x "$REPO/scripts/mhl-manifest" ]; then
    if mo=$("$REPO/scripts/mhl-manifest" check 2>&1); then echo "governance integrity: $mo"; else echo "GOVERNANCE INTEGRITY VIOLATION ($("$REPO/scripts/mhl-manifest" mode 2>/dev/null)): $(printf '%s' "$mo" | head -3 | tr '\n' ' ') — stop_gate will block until reinstalled from main"; fi
  else echo "governance integrity checker missing — cannot verify the enforcement set"; fi
  if [ -n "$missing" ]; then echo "GUARDS NOT ACTIVE on this machine:$missing — run scripts/mhl-install-hooks from main and paste scripts/hooks/user-settings-hooks.json into ~/.claude/settings.json; remove any disableAllHooks (make hooks-installed verifies)"; else echo "guards: active (installed copies wired from user settings, no disableAllHooks)"; fi
  op=$(grep -lE '^status:[[:space:]]*open' "$INV"/incidents/INCIDENT-*.md 2>/dev/null | wc -l); echo "open incidents: $op"
  [ -r "$HOME/.mhl/vault/mhl.pass" ] && echo "vault: password file present" || echo "vault: MISSING ~/.mhl/vault/mhl.pass — restore from Mike's password safe"
  pv=$(ls "$HOME/.mhl/pre-vault" 2>/dev/null | wc -l); [ "$pv" -gt 0 ] && echo "pre-vault: $pv plaintext backup(s) pending — escrow, verify, then scripts/mhl-vault-file --purge <inventory>"
  echo "share inbox: re-arm the 15-minute Monitor on /media/Backups/claude/tools/check-inbox.sh mchomelab (see memory)."
  echo "Binding: CLAUDE.md — no change to the lab without a committed role/inventory change landed via PR; reads are free; site.yml applies only from a committed tree; emergencies need incidents/INCIDENT-<date>-<slug>.md; make validate must be green before you stop."
}
jq -n --arg c "$(ctx 2>/dev/null)" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
