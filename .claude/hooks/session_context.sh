#!/usr/bin/env bash
# SessionStart: inject the state a fresh session needs before it acts.
set -uo pipefail
ROOT="$HOME/workspace/McHomeLab"; INV="$HOME/workspace/McHomeLab-Inventory"
ctx() { for repo in "$ROOT" "$INV"; do
  n=$(basename "$repo"); b=$(git -C "$repo" branch --show-current 2>/dev/null); d=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l)
  echo "$n: branch=$b dirty_files=$d"
done
prs=$(timeout 10 gh pr list --repo bzaks1424/McHomeLab --state open --json number,title -q '.[]|"#\(.number) \(.title)"' 2>/dev/null); [ -n "$prs" ] && echo "open PRs (McHomeLab): $prs"
prs=$(timeout 10 gh pr list --repo bzaks1424/McHomeLab-Inventory --state open --json number,title -q '.[]|"#\(.number) \(.title)"' 2>/dev/null); [ -n "$prs" ] && echo "open PRs (Inventory): $prs"
op=$(grep -lE '^status:[[:space:]]*open' "$INV"/incidents/INCIDENT-*.md 2>/dev/null | wc -l); echo "open incidents: $op"
[ -r "$HOME/.mhl/vault/mhl.pass" ] && echo "vault: password file present" || echo "vault: MISSING ~/.mhl/vault/mhl.pass — restore from Mike's password safe"
echo "Binding: CLAUDE.md — no change to the lab without a committed role/inventory change landed via PR; reads are free; site.yml applies only from a committed tree; emergencies need incidents/INCIDENT-<date>-<slug>.md; make validate must be green before you stop."
}
jq -n --arg c "$(ctx 2>/dev/null)" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
