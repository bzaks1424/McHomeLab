#!/usr/bin/env bash
# INBOX-073: the secrets gate must see a secret that lives ONLY in an earlier commit.
#
# The directory scan excludes .git, so it sees the working tree and nothing else. A
# secret committed and then removed later on the same branch passes that scan and is
# still published on push. `--range` closes that; this proves it, and proves the plain
# tree scan really does miss it, so the fix is not guarding against an imaginary hole.
#
# Synthetic fixtures only. No real credential is ever created, read, or printed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; GATE="$ROOT/scripts/mhl-no-secrets"
T=$(mktemp -d "${TMPDIR:-/tmp}/mhl-range.XXXXXX"); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ck() { if [ "$2" = "$3" ]; then printf '  ok    %-52s %s\n' "$1" "$3"; PASS=$((PASS+1));
       else printf '  FAIL  %-52s want=%s got=%s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi; }

git -C "$T" init -q 2>/dev/null
git -C "$T" config user.email t@t; git -C "$T" config user.name t
git -C "$T" commit -q --allow-empty -m base
BASE=$(git -C "$T" rev-parse HEAD)

# Commit 1: a synthetic PEM private key. Value-shaped, matches SHAPE_RE.
printf -- '-----BEGIN RSA PRIVATE KEY-----\nTOTALLYFAKEFIXTUREKEYNOTREAL\n-----END RSA PRIVATE KEY-----\n' > "$T/leak.conf"  # no-secret: synthetic fixture, no key material
git -C "$T" add leak.conf; git -C "$T" commit -q -m "oops"
# Commit 2: remove it, exactly as a person would after noticing.
git -C "$T" rm -q leak.conf; git -C "$T" commit -q -m "remove it"

# grep exits 1 when NOT found, which is what "clean" means here.
ck "working tree is clean of the secret"   1 "$(grep -rqF 'BEGIN RSA PRIVATE KEY' "$T" --exclude-dir=.git 2>/dev/null; echo $?)"
# The gap, asserted rather than assumed: the tree scan PASSES on this branch.
"$GATE" "$T" >/dev/null 2>&1; ck "tree scan MISSES it (this is the gap)" 0 "$?"
# The fix: the range scan FAILS.
out=$("$GATE" --range "$BASE..HEAD" "$T" 2>&1); rc=$?
ck "range scan CATCHES it"                 1 "$rc"
# reported once per commit version that carried it, so assert presence, not a count.
ck "and says value-shaped"                 0 "$(printf '%s' "$out" | grep -q 'value-shaped'; echo $?)"
ck "never prints the value"                0 "$(printf '%s' "$out" | grep -c 'TOTALLYFAKEFIXTUREKEY')"

# A clean range must still pass, or the gate is useless noise.
git -C "$T" commit -q --allow-empty -m clean
ck "clean range passes"                    0 "$("$GATE" --range 'HEAD~1..HEAD' "$T" >/dev/null 2>&1; echo $?)"
# Bad input fails closed rather than silently passing.
ck "bad range fails closed"                1 "$("$GATE" --range 'nope..nope' "$T" >/dev/null 2>&1; echo $?)"
ck "non-repo fails closed"                 1 "$("$GATE" --range 'a..b' /tmp >/dev/null 2>&1; echo $?)"

printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
