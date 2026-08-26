#!/usr/bin/env bash
# Gate/tool agreement matrix: for every YAML shape, what mhl-no-secrets says
# and what mhl-vault-file does must be one of:
#   gate PASS + tool exit 0 (nothing to vault / vaulted)
#   gate FAIL + tool vaults it (exit 0, file changed, gate then PASS)
#   gate FAIL + tool refuses (exit 1, file unchanged, remedy printed)
# The deadlock cell — gate FAIL + tool exit 0 with the file unchanged — is a FAIL.
# Needs the venv and the vault password (uses synthetic values only).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/scripts/mhl-vault-file"; GATE="$ROOT/scripts/mhl-no-secrets"
if ! [ -x "$ROOT/.venv/bin/ansible-vault" ] || ! [ -r "$HOME/.mhl/vault/mhl.pass" ]; then
  # Visible skip: exit 3 so `make validate` reports it as SKIPPED, not green.
  echo "SKIP  secrets matrix: needs the venv and the vault password (CI has a shim; a dev box must have both)"; exit 3
fi
# Sandboxed HOME for the tool's backups: the suite must never touch the real ~/.mhl/pre-vault.
T=$(mktemp -d "${TMPDIR:-/tmp}/mhl-matrix.XXXXXX"); SH=$(mktemp -d "${TMPDIR:-/tmp}/mhl-matrix-home.XXXXXX"); trap 'rm -r "$T" "$SH"' EXIT
# The sandbox HOME lives OUTSIDE the scanned tree: the tool's *.pre-vault backups
# land there, and the gate would (correctly) fail on them if they were inside $T.
mkdir -p "$SH/.mhl/vault" "$SH/.mhl/bin"; chmod 700 "$SH/.mhl/vault"
cp "$HOME/.mhl/vault/mhl.pass" "$SH/.mhl/vault/mhl.pass"; chmod 600 "$SH/.mhl/vault/mhl.pass"
cp "$HOME/.mhl/bin/mhl-vault-client" "$SH/.mhl/bin/mhl-vault-client" 2>/dev/null || cp "$ROOT/scripts/mhl-vault-client" "$SH/.mhl/bin/mhl-vault-client"; chmod 700 "$SH/.mhl/bin/mhl-vault-client"
export HOME="$SH"
PASS=0; FAIL=0
row() { # name expected_gate(PASS|FAIL) expected_tool(vault|skip|refuse) content
  local name="$1"; local eg="$2"; local et="$3"; local f="$T/matrix-$name.yml"
  local g t g2 rc changed
  printf '%b' "$4" > "$f"; cp "$f" "$f.orig"
  "$GATE" "$T" >/dev/null 2>&1 && g=PASS || g=FAIL
  "$TOOL" "$f" >"$T/out" 2>"$T/err"; rc=$?
  if cmp -s "$f" "$f.orig"; then changed=no; else changed=yes; fi
  case "$rc/$changed" in 0/yes) t=vault ;; 0/no) t=skip ;; *) t=refuse ;; esac
  "$GATE" "$T" >/dev/null 2>&1 && g2=PASS || g2=FAIL
  local ok=1
  [ "$g" = "$eg" ] && [ "$t" = "$et" ] || ok=0
  [ "$g" = FAIL ] && [ "$t" = skip ] && ok=0                     # the deadlock cell
  [ "$g" = PASS ] && [ "$t" = vault ] && ok=0                    # tool vaulted what the gate did not flag
  [ "$t" = vault ] && [ "$g2" = FAIL ] && ok=0                    # vaulted but gate still red
  # A refusal must be one of the tool's explicit refuse messages, each of which carries a remedy or reason.
  [ "$t" = refuse ] && ! grep -qE 'cannot be vaulted by this tool — |: not valid YAML \(line [0-9]+\); refusing|YAML documents; exactly one is supported|is not UTF-8; refusing|has CRLF line endings' "$T/err" && ok=0
  grep -q 'CANARY' "$T/out" "$T/err" && ok=0                      # never print a value
  if [ $ok -eq 1 ]; then PASS=$((PASS+1)); echo "ok    $name: gate=$g tool=$t after=$g2"; else FAIL=$((FAIL+1)); echo "FAIL  $name: gate=$g tool=$t after=$g2 (want gate=$eg tool=$et)"; fi
  rm -f "$f" "$f.orig"
}
row plain           FAIL vault  '---\na_password: CANARY1\n'
row quoted          FAIL vault  '---\na_password: "CANARY#2"  # keep\n'
row leadingzero     FAIL vault  '---\na_password: 004821\nb_password: CANARY0\n'
row listitem        FAIL vault  '---\nitems:\n  - a_password: CANARY3\n'
row vaulted         PASS skip   '---\na_password: !vault |\n  $ANSIBLE_VAULT;1.2;AES256;mhl\n  00\n'
row ref             PASS skip   '---\na_password: "{{ x }}"\n'
row empty           PASS skip   '---\na_password:\n'
row collection      PASS skip   '---\ncredentials:\n  user: bob\n'
row blockscalar_txt PASS skip   '---\nmotd: |  # no-secret: login banner prose\n  hi\n  password: CANARY4\n  bye\n'
row embedded_cred   FAIL refuse '---\nmariadb_compose: |\n  services:\n    db:\n      environment:\n        MYSQL_ROOT_PASSWORD: CANARY14\n'
row embedded_folded FAIL refuse '---\nsmb_conf: >\n  [global]\n  password: CANARY15\n'
row flowseq_value   FAIL refuse '---\nunifi_api_key: [CANARY16, CANARY17]\n'
row flowmap_value   FAIL refuse '---\nplex_token: {value: CANARY18}\n'
row block_collection PASS skip  '---\ncredentials:\n  - user: bob\n'
row nextline_quoted FAIL refuse '---\ndb_password:\n  "CANARY19"\n'
row nextline_plain  FAIL refuse '---\ndb_password:\n  CANARY20\n'
row duplicate_keys  FAIL vault  '---\nh1:\n  a_password: CANARY21\nh2:\n  a_password: CANARY22\n'
row crlf            FAIL refuse '---\r\na_password: CANARY23\r\n'
row nonutf8         FAIL refuse '---\na_password: CANARY24\xff\n'
row blockscalar     FAIL refuse '---\na_password: |\n  CANARY5\n'
row folded          FAIL refuse '---\na_password: >-\n  CANARY6\n'
row flow            FAIL refuse 'creds: {\n  password: CANARY7,\n  user: bob\n}\n'
row tag             FAIL refuse '---\na_password: !!str CANARY8\n'
row anchor          FAIL refuse '---\nbase: &b CANARY9\na_password: *b\n'
row complexkey      FAIL refuse '---\n? a_password\n: CANARY10\n'
row emptyquoted     FAIL refuse '---\na_password: ""\n'
row multiline       FAIL refuse '---\na_password: "CAN\n  ARY11"\n'
row invalid         FAIL refuse 'a_password: - CANARY12\n'
row multidoc        FAIL refuse '---\na_password: CANARY13\n---\nb: 1\n'
# Gate must FAIL CLOSED when the shared module is missing or broken (never exit 0).
printf -- '---\nclean: 1\n' > "$T/c.yml"
for mode in missing broken; do
  R2=$(mktemp -d "${TMPDIR:-/tmp}/mhl-gatecopy.XXXXXX"); mkdir -p "$R2/scripts"; cp "$GATE" "$R2/scripts/"; ln -s "$ROOT/.venv" "$R2/.venv"
  [ "$mode" = broken ] && printf 'def (\n' > "$R2/scripts/mhl_secrets.py"
  "$R2/scripts/mhl-no-secrets" "$T" >/dev/null 2>&1; rc=$?
  if [ "$rc" -ne 0 ]; then PASS=$((PASS+1)); echo "ok    gate fails closed with module $mode (rc=$rc)"; else FAIL=$((FAIL+1)); echo "FAIL  gate exit 0 with module $mode"; fi
  rm -r "$R2"
done
# Gate standalone invocations that must keep working: from /, relative path, symlink, no args, tool absent.
( cd / && "$GATE" "$T" >/dev/null 2>&1 ) && { PASS=$((PASS+1)); echo "ok    gate from /"; } || { FAIL=$((FAIL+1)); echo "FAIL  gate from /"; }
( cd "$ROOT" && scripts/mhl-no-secrets "$T" >/dev/null 2>&1 ) && { PASS=$((PASS+1)); echo "ok    gate relative path"; } || { FAIL=$((FAIL+1)); echo "FAIL  gate relative"; }
ln -s "$GATE" "$T/gate-link"; ( cd /tmp && "$T/gate-link" "$T" >/dev/null 2>&1 ) && { PASS=$((PASS+1)); echo "ok    gate via symlink"; } || { FAIL=$((FAIL+1)); echo "FAIL  gate via symlink"; }; rm -f "$T/gate-link"
( cd "$ROOT" && scripts/mhl-no-secrets >/dev/null 2>&1; [ $? -ne 2 ] ) && { PASS=$((PASS+1)); echo "ok    gate no-args runs"; } || { FAIL=$((FAIL+1)); echo "FAIL  gate no-args"; }
( "$GATE" /nonexistent-dir >/dev/null 2>&1; [ $? -eq 1 ] ) && { PASS=$((PASS+1)); echo "ok    gate FAILs on a typo'd path"; } || { FAIL=$((FAIL+1)); echo "FAIL  gate passed a nonexistent dir"; }
( "$GATE" --help >/dev/null 2>&1; [ $? -eq 2 ] ) && { PASS=$((PASS+1)); echo "ok    gate rejects --help as usage"; } || { FAIL=$((FAIL+1)); echo "FAIL  gate treated --help as a dir"; }
R3=$(mktemp -d "${TMPDIR:-/tmp}/mhl-gatecopy.XXXXXX"); mkdir -p "$R3/scripts"; cp "$GATE" "$ROOT/scripts/mhl_secrets.py" "$R3/scripts/"; ln -s "$ROOT/.venv" "$R3/.venv"
( "$R3/scripts/mhl-no-secrets" "$T" >/dev/null 2>&1 ) && { PASS=$((PASS+1)); echo "ok    gate works with mhl-vault-file absent"; } || { FAIL=$((FAIL+1)); echo "FAIL  gate with tool absent"; }; rm -r "$R3"
echo "MATRIX: $PASS passed, $FAIL failed"; [ $FAIL -eq 0 ]
