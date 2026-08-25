#!/usr/bin/env bash
# PostToolUse[Write|Edit]: the tight half of the validation loop — lint the
# touched file now; the full `make validate` runs at Stop. Findings block.
# A missing linter also blocks (fails CLOSED, deliberately): an unlinted YAML
# edit must not pass silently just because the venv is absent.
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "check_edit: jq missing" >&2; exit 2; }
REPO="$HOME/workspace/McHomeLab"; INV="$HOME/workspace/McHomeLab-Inventory"
P=$(cat | jq -r '.tool_input.file_path // .tool_response.filePath // ""') || exit 2
[ -f "$P" ] || exit 0
P=$(realpath -m "$P")
YAMLLINT="$REPO/.venv/bin/yamllint"; [ -x "$YAMLLINT" ] || YAMLLINT=$(command -v yamllint || true)
OUT=""
case "$P" in
  *.sh) OUT=$(bash -n "$P" 2>&1) ;;
  *.py) OUT=$(python3 -m py_compile "$P" 2>&1) ;;
  *.json) OUT=$(python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$P" 2>&1) ;;
  *.yml|*.yaml)
    [[ "$P" == "$REPO"/* || "$P" == "$INV"/* ]] || exit 0
    if [ -n "$YAMLLINT" ] && [ -x "$YAMLLINT" ]; then
      OUT=$("$YAMLLINT" -c "$REPO/.yamllint" -f parsable "$P" 2>&1 | grep -v ': \[warning\]' || true)
    else
      OUT="yamllint not found ($REPO/.venv missing?) — run poetry install; file not linted"
    fi
    if [[ "$P" == "$INV"/* ]]; then S=$("$REPO/scripts/mhl-no-secrets" "$INV" 2>&1 | grep -v PASS || true); [ -n "$S" ] && OUT="$OUT"$'\n'"$S"; fi ;;
esac
OUT=$(printf '%s' "$OUT" | sed '/^$/d')
[ -z "$OUT" ] && exit 0
jq -n --arg r "validation loop: findings in ${P#"$HOME"/}:"$'\n'"$OUT" '{decision:"block",reason:$r}'
