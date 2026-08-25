#!/usr/bin/env bash
# PostToolUse[Write|Edit]: the tight half of the validation loop — lint the
# touched file now; the full `make validate` runs at Stop.
set -uo pipefail
ROOT="$HOME/workspace/McHomeLab"; INV="$HOME/workspace/McHomeLab-Inventory"
P=$(cat | jq -r '.tool_input.file_path // .tool_response.filePath // ""' 2>/dev/null)
[ -f "$P" ] || exit 0
OUT=""
case "$P" in
  *.sh) OUT=$(bash -n "$P" 2>&1) ;;
  *.py) OUT=$(python3 -m py_compile "$P" 2>&1) ;;
  *.json) OUT=$(python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$P" 2>&1) ;;
  *.yml|*.yaml)
    [[ "$P" == "$ROOT"/* || "$P" == "$INV"/* ]] || exit 0
    OUT=$("$ROOT/.venv/bin/yamllint" -c "$ROOT/.yamllint" -f parsable "$P" 2>&1 | grep -v ': \[warning\]' || true)
    if [[ "$P" == "$INV"/* ]]; then S=$("$ROOT/scripts/mhl-no-secrets" "$INV" 2>&1 | grep -v PASS || true); [ -n "$S" ] && OUT="$OUT"$'\n'"$S"; fi ;;
esac
OUT=$(printf '%s' "$OUT" | sed '/^$/d')
[ -z "$OUT" ] && exit 0
jq -n --arg r "validation loop: findings in ${P#$HOME/}:"$'\n'"$OUT" '{decision:"block",reason:$r}'
