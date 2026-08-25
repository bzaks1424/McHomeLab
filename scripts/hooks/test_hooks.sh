#!/usr/bin/env bash
# Tests for .claude/hooks/*. Payloads live here, not in Bash tool calls, so
# testing a guard never trips it. Prints ok/FAIL rows; exits 1 on any failure.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
H="$ROOT/.claude/hooks"
PASS=0; FAIL=0
# expect <name> <hook> <allow|deny|ask|block|error> <payload>
#   allow : hook exited 0 and emitted NO decision (an absent or crashing hook is a FAIL, not an allow)
#   deny/ask/block : hook exited 0 and emitted that decision
#   error : hook exited 2 (fail-closed path)
expect() {
  local out rc got
  [ -f "$H/$2" ] || { FAIL=$((FAIL+1)); echo "FAIL  $1 (hook $2 missing)"; return; }
  out=$(printf '%s' "$4" | bash "$H/$2" 2>/dev/null); rc=$?
  if [ "$rc" -eq 2 ]; then got=error
  elif [ "$rc" -ne 0 ]; then got="exit$rc"
  elif [ -z "$out" ]; then got=allow
  else got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // .decision // "malformed"' 2>/dev/null || echo malformed); fi
  if [ "$got" = "$3" ]; then PASS=$((PASS+1)); echo "ok    $1"; else FAIL=$((FAIL+1)); echo "FAIL  $1 (want $3, got $got)"; fi
}
b() { jq -nc --arg c "$1" '{tool_input:{command:$c}}'; }
w() { jq -nc --arg p "$1" '{tool_input:{file_path:$p}}'; }
G=guard_bash.sh
expect "docker ps over ssh is a read"            $G allow "$(b 'ssh media.michaelpmcd.com "docker ps"')"
expect "docker logs over ssh is a read"          $G allow "$(b 'ssh util.michaelpmcd.com "docker logs compose-wud-1 --tail 50"')"
expect "docker restart over ssh denied"          $G deny  "$(b 'ssh media.michaelpmcd.com "docker restart compose-plex-1"')"
expect "sudo rm over ssh denied"                 $G deny  "$(b 'ssh media.michaelpmcd.com "sudo rm -f /opt/docker/compose/x.bak"')"
expect "redirect over ssh denied"                $G deny  "$(b 'ssh util.michaelpmcd.com "echo x > /etc/foo"')"
expect "docker --context exec denied"            $G deny  "$(b 'docker --context media exec compose-recyclarr-1 recyclarr sync')"
expect "docker --context ps allowed"             $G allow "$(b 'docker --context media ps')"
expect "ansible uri against host denied"         $G deny  "$(b 'ansible media -i ../McHomeLab-Inventory/hosts.yml -m uri -a "url=http://x method=POST"')"
expect "ansible shell against host denied"       $G deny  "$(b 'ansible util -m shell -a "id"')"
expect "ansible setup allowed"                   $G allow "$(b 'ansible media -i hosts.yml -m setup')"
expect "ansible localhost uri allowed"           $G allow "$(b 'ansible localhost -m uri -a "url=https://ha.michaelpmcd.com/api/"')"
expect "curl GET to lab allowed"                 $G allow "$(b 'curl -sk https://sonarr.media.michaelpmcd.com/api/v3/health')"
expect "curl POST to lab denied"                 $G deny  "$(b 'curl -sk -X POST https://wud.util.michaelpmcd.com/api/containers/watch')"
expect "wget --post-data to lab denied"          $G deny  "$(b 'wget -qO- --post-data "" http://192.168.254.3:3000/api/containers/watch')"
expect "curl POST to github allowed"             $G allow "$(b 'curl -X POST https://api.github.com/repos/x/y/pulls')"
expect "step ca certificate denied"              $G deny  "$(b 'step ca certificate foo foo.crt foo.key --provisioner ansible')"
expect "step ca health allowed"                  $G allow "$(b 'step ca health --ca-url https://ca.util.michaelpmcd.com')"
expect "docker context create denied"            $G deny  "$(b 'docker context create media --docker host=tcp://media:2376')"
expect "site.yml --limit denied"                 $G deny  "$(b 'ansible-playbook ansible/site.yml -i hosts.yml --limit media')"
expect "site.yml --check allowed"                $G allow "$(b 'ansible-playbook ansible/site.yml -i ../McHomeLab-Inventory/hosts.yml --check --diff')"
expect "git push main denied"                    $G deny  "$(b 'git push origin main')"
expect "git push --force denied"                 $G deny  "$(b 'git push --force origin feature/x')"
expect "git push branch allowed"                 $G allow "$(b 'git push -u origin phase2/governance')"
expect "rm -rf denied"                           $G deny  "$(b 'rm -rf /tmp/mhl-render')"
expect "plain rm allowed"                        $G allow "$(b 'rm /tmp/x.log')"
expect "make validate allowed"                   $G allow "$(b 'make validate')"
expect "bash -c wrapper carrying docker restart denied" $G deny  "$(b "bash -c 'ssh media.michaelpmcd.com \"docker restart compose-plex-1\"'")"
expect "python3 -c subprocess ssh restart denied"    $G deny  "$(b "python3 -c \"import subprocess;subprocess.run(['ssh','media.michaelpmcd.com','docker restart x'])\"")"
expect "eval wrapper denied"                         $G deny  "$(b "eval \"ssh util.michaelpmcd.com 'sudo systemctl restart docker'\"")"
expect "scp to lab host denied"                      $G deny  "$(b 'scp ./x.sh media.michaelpmcd.com:/opt/docker/x.sh')"
expect "rsync to lab host denied"                    $G deny  "$(b 'rsync -a ./x/ mmcdonnell@192.168.255.34:/opt/docker/')"
expect "sudo rm -rf denied"                          $G deny  "$(b 'sudo rm -rf /tmp/x')"
expect "rm -r -f denied"                             $G deny  "$(b 'rm -r -f /tmp/x')"
expect "rm -r allowed (no force)"                    $G allow "$(b 'rm -r /tmp/x')"
expect "cat vault password denied"                   $G deny  "$(b 'cat ~/.mhl/vault/mhl.pass')"
expect "sed -n vault password denied"                $G deny  "$(b 'sed -n 1p /home/mmcdonnell/.mhl/vault/mhl.pass')"
expect "local redirect after remote read allowed"    $G allow "$(b 'ssh util.michaelpmcd.com "docker ps" > /tmp/out.txt')"
expect "curl POST to example.com/media allowed"      $G allow "$(b 'curl -X POST https://api.example.com/media/upload')"
expect "curl -T upload to lab denied"                $G deny  "$(b 'curl -T file.txt https://util.michaelpmcd.com/upload')"
expect "git push --mirror denied"                    $G deny  "$(b 'git push --mirror origin')"
expect "rm at start of remote command denied"        $G deny  "$(b 'ssh media.michaelpmcd.com "rm /opt/docker/compose.yml"')"
expect "read then chained docker run denied"         $G deny  "$(b 'ssh media.michaelpmcd.com "ls /opt && docker run -d --name probe nginx"')"
expect "read then chained chmod denied"              $G deny  "$(b 'ssh media.michaelpmcd.com "ls /opt; chmod 777 /opt/docker"')"
expect "read piped to tee on host denied"            $G deny  "$(b 'ssh util.michaelpmcd.com "journalctl -u docker | tee /opt/docker/log"')"
expect "docker-compose hyphen form denied"           $G deny  "$(b 'ssh media.michaelpmcd.com "docker-compose up -d"')"
expect "mv over ssh denied"                          $G deny  "$(b 'ssh media.michaelpmcd.com "mv /opt/a /opt/b"')"
expect "truncate over ssh denied"                    $G deny  "$(b 'ssh media.michaelpmcd.com "truncate -s 0 /opt/x"')"
expect "reboot over ssh denied"                      $G deny  "$(b 'ssh media.michaelpmcd.com "sudo reboot"')"
expect "docker system prune over ssh denied"         $G deny  "$(b 'ssh media.michaelpmcd.com "docker system prune -af"')"
expect "crontab over ssh denied"                     $G deny  "$(b 'ssh media.michaelpmcd.com "crontab -"')"
expect "docker --context compose -f up denied"       $G deny  "$(b 'docker --context media compose -f x.yml up -d')"
expect "docker --context run denied"                 $G deny  "$(b 'docker --context media run -d nginx')"
expect "docker --context volume rm denied"           $G deny  "$(b 'docker --context media volume rm data')"
expect "scp to short-name lab host denied"           $G deny  "$(b 'scp x.sh media:/opt/x.sh')"
expect "docker ps --format braces allowed"           $G allow "$(b 'ssh media.michaelpmcd.com "docker ps -a --format '"'"'{{.Names}}'"'"'"')"
expect "grep for docker restart in roles allowed"    $G allow "$(b 'grep -rn "docker restart" ansible/roles/')"
expect "empty allowed"                           $G allow "$(b '')"
W=guard_writes.sh
expect "write role file allowed"                 $W allow "$(w "$HOME/workspace/McHomeLab/ansible/roles/service/tasks/main.yml")"
expect "write hosts.yml allowed"                 $W allow "$(w "$HOME/workspace/McHomeLab-Inventory/hosts.yml")"
expect "write registry.json denied"              $W deny  "$(w "$HOME/.mhl/registry.json")"
expect "write vault pass denied"                 $W deny  "$(w "$HOME/.mhl/vault/mhl.pass")"
expect "write archive denied"                    $W deny  "$(w "$HOME/workspace/McHomeLab/archive/roles/uisp/tasks/main.yml")"
expect "write /etc denied"                       $W deny  "$(w "/etc/hosts")"
expect "write /opt/docker denied"                $W deny  "$(w "/opt/docker/compose/docker-compose.yml")"
expect "write installed hook denied"             $W deny  "$(w "$HOME/.mhl/hooks/guard_bash.sh")"
expect "write settings.json denied"              $W deny  "$(w "$HOME/workspace/McHomeLab/.claude/settings.json")"
expect "write CLAUDE.md denied"                  $W deny  "$(w "$HOME/workspace/McHomeLab/CLAUDE.md")"
expect "write repo hook copy allowed"            $W allow "$(w "$HOME/workspace/McHomeLab/.claude/hooks/guard_bash.sh")"
expect "write user settings denied"              $W deny  "$(w "$HOME/.claude/settings.json")"
expect "traversal into /etc denied"              $W deny  "$(w "$HOME/workspace/McHomeLab/../../../../etc/hosts")"
expect "write other ~/.claude path denied"       $W deny  "$(w "$HOME/.claude/agents/x.md")"
expect "write settings.local.json denied"        $W deny  "$(w "$HOME/workspace/McHomeLab/.claude/settings.local.json")"
expect "write project agent denied"              $W deny  "$(w "$HOME/workspace/McHomeLab/.claude/agents/drift-checker.md")"
expect "write project skill denied"              $W deny  "$(w "$HOME/workspace/McHomeLab/.claude/skills/drift/SKILL.md")"
expect "write project rule denied"               $W deny  "$(w "$HOME/workspace/McHomeLab/.claude/rules/inventory.md")"
expect "write Makefile denied"                   $W deny  "$(w "$HOME/workspace/McHomeLab/Makefile")"
expect "write test_hooks denied"                 $W deny  "$(w "$HOME/workspace/McHomeLab/scripts/hooks/test_hooks.sh")"
expect "write pre-push denied"                   $W deny  "$(w "$HOME/workspace/McHomeLab/scripts/git-hooks/pre-push")"
expect "write .mcp.json denied"                  $W deny  "$(w "$HOME/workspace/McHomeLab/.mcp.json")"
expect "write CLAUDE.local.md denied"            $W deny  "$(w "$HOME/workspace/McHomeLab/CLAUDE.local.md")"
expect "write mhl-install-hooks denied"          $W deny  "$(w "$HOME/workspace/McHomeLab/scripts/mhl-install-hooks")"
expect "write memory allowed"                    $W allow "$(w "$HOME/.claude/projects/-home-mmcdonnell-workspace-McHomeLab/memory/x.md")"
expect "write scratchpad allowed"                $W allow "$(w "/tmp/claude-1000/x/scratchpad/y")"
expect "write other repo denied"                 $W deny  "$(w "$HOME/workspace/claude/todo.md")"
# Fail-closed paths: every guard must exit 2 (not allow) when jq is missing
# or the payload is unreadable. Run with an empty PATH so jq cannot be found.
for hook in guard_bash.sh guard_writes.sh check_edit.sh stop_gate.sh session_context.sh; do
  rc=$(printf '{}' | PATH=/nonexistent /bin/bash "$H/$hook" >/dev/null 2>&1; echo $?)
  if [ "$rc" -eq 2 ]; then PASS=$((PASS+1)); echo "ok    $hook fails closed without jq"; else FAIL=$((FAIL+1)); echo "FAIL  $hook without jq: exit $rc (want 2)"; fi
done
# Harness self-test: a missing hook and a hook that exits non-zero must both score FAIL, never allow.
selftest=$( (PASS=0; FAIL=0; expect x does_not_exist.sh allow "$(b 'ls')"; echo "F=$FAIL") | tail -1 )
[ "$selftest" = "F=1" ] && { PASS=$((PASS+1)); echo "ok    harness: missing hook scores FAIL"; } || { FAIL=$((FAIL+1)); echo "FAIL  harness: missing hook did not score FAIL ($selftest)"; }
printf '#!/usr/bin/env bash\nexit 1\n' > "$H/.selftest_dying.sh"
selftest=$( (PASS=0; FAIL=0; expect x .selftest_dying.sh allow "$(b 'ls')"; echo "F=$FAIL") | tail -1 ); rm -f "$H/.selftest_dying.sh"
[ "$selftest" = "F=1" ] && { PASS=$((PASS+1)); echo "ok    harness: dying hook scores FAIL"; } || { FAIL=$((FAIL+1)); echo "FAIL  harness: dying hook did not score FAIL ($selftest)"; }
C=check_edit.sh
T=$(mktemp -d "$ROOT/.hooktest.XXXXXX"); trap 'rm -r "$T"' EXIT
printf 'key: [\n' > "$T/bad.yml"; printf -- '---\nkey: "v"\n' > "$T/ok.yml"; printf 'if [\n' > "$T/bad.sh"; printf 'echo hi\n' > "$T/ok.sh"
expect "check bad yaml blocks"                   $C block "$(w "$T/bad.yml")"
expect "check ok yaml passes"                    $C allow "$(w "$T/ok.yml")"
expect "check bad sh blocks"                     $C block "$(w "$T/bad.sh")"
expect "check ok sh passes"                      $C allow "$(w "$T/ok.sh")"
expect "check nonexistent passes"                $C allow "$(w "$T/nope.yml")"
S=$(printf '{}' | bash "$H/session_context.sh" | jq -r '.hookSpecificOutput.additionalContext'); if printf '%s' "$S" | grep -q 'Binding: CLAUDE.md'; then PASS=$((PASS+1)); echo "ok    session_context injects rules"; else FAIL=$((FAIL+1)); echo "FAIL  session_context"; fi
# Portable structural checks (run in CI too):
# The repo's settings.json defines NO hooks (Mike's decision, 2026-08-25: hook
# definitions live in user scope, ~/.claude/settings.json, so a project-local
# settings.local.json cannot disable them). The reviewable source of truth for
# what runs is .claude/hooks/*.sh + scripts/hooks/user-settings-hooks.json.
SETTINGS="$ROOT/.claude/settings.json"
nh=$(jq -r '.hooks // {} | length' "$SETTINGS")
if [ "$nh" = "0" ]; then PASS=$((PASS+1)); echo "ok    project settings.json defines no hooks"; else FAIL=$((FAIL+1)); echo "FAIL  project settings.json must not define hooks (user scope is the enforcement point)"; fi
# The reference user-scope block must wire exactly the repo's hooks, each as `bash $HOME/.mhl/hooks/<name>.sh`.
REF="$ROOT/scripts/hooks/user-settings-hooks.json"
if [ -f "$REF" ]; then
  while IFS= read -r c; do
    n=$(printf '%s' "$c" | sed -nE 's|^bash \$HOME/\.mhl/hooks/([a-z_]+\.sh)$|\1|p')
    if [ -n "$n" ] && [ -f "$H/$n" ]; then PASS=$((PASS+1)); echo "ok    reference wiring $c"; else FAIL=$((FAIL+1)); echo "FAIL  reference wiring: '$c' must be 'bash \$HOME/.mhl/hooks/<repo hook>.sh'"; fi
  done < <(jq -r '.hooks | to_entries[] | .value[] | .hooks[]?.command' "$REF")
  for f in "$H"/*.sh; do
    if jq -e --arg c "bash \$HOME/.mhl/hooks/$(basename "$f")" '[.hooks | to_entries[] | .value[] | .hooks[]?.command] | index($c) != null' "$REF" >/dev/null; then PASS=$((PASS+1)); echo "ok    reference wires $(basename "$f")"; else FAIL=$((FAIL+1)); echo "FAIL  reference block does not wire $(basename "$f")"; fi
  done
else FAIL=$((FAIL+1)); echo "FAIL  missing $REF"; fi
# A real pre-vault backup produced by the tool must be caught by the gate when it is inside a tree.
if [ -x "$ROOT/.venv/bin/ansible-vault" ] && [ -r "$HOME/.mhl/vault/mhl.pass" ] && [ -x "$ROOT/scripts/mhl-vault-file" ]; then
  printf -- '---\nx:\n  t_password: harness-fixture\n' > "$T/g.yml"
  before=$(ls "$HOME/.mhl/pre-vault" 2>/dev/null | wc -l)
  if "$ROOT/scripts/mhl-vault-file" "$T/g.yml" >/dev/null 2>&1; then
    b=$(ls -t "$HOME/.mhl/pre-vault"/g.yml.*.pre-vault 2>/dev/null | head -1)
    cp "$b" "$T/leak.pre-vault"
    if "$ROOT/scripts/mhl-no-secrets" "$T" 2>/dev/null | grep -q '^FAIL: plaintext pre-vault'; then PASS=$((PASS+1)); echo "ok    gate FAILs on a real in-tree pre-vault backup"; else FAIL=$((FAIL+1)); echo "FAIL  gate passed a real in-tree pre-vault backup"; fi
    rm -f "$T/leak.pre-vault" "$b" "$b.meta"
  else FAIL=$((FAIL+1)); echo "FAIL  mhl-vault-file could not vault the harness fixture"; fi
  after=$(ls "$HOME/.mhl/pre-vault" 2>/dev/null | wc -l); [ "$after" -eq "$before" ] || echo "note: pre-vault dir count changed $before -> $after"
else echo "skip  real-backup gate test (needs .venv, vault password, mhl-vault-file)"; fi

# Machine-dependent checks: only with MHL_HOOKS_INSTALLED=1 (make hooks-installed).
if [ "${MHL_HOOKS_INSTALLED:-0}" = "1" ]; then
  for f in "$H"/*.sh; do
    i="$HOME/.mhl/hooks/$(basename "$f")"
    if [ -x "$i" ]; then PASS=$((PASS+1)); echo "ok    installed $(basename "$f")"; else FAIL=$((FAIL+1)); echo "FAIL  installed hook missing/not executable: $i (run scripts/mhl-install-hooks from main)"; fi
    if [ "$(git -C "$ROOT" branch --show-current 2>/dev/null)" = "main" ] && [ -x "$i" ]; then
      if cmp -s "$f" "$i"; then PASS=$((PASS+1)); echo "ok    installed == repo $(basename "$f")"; else FAIL=$((FAIL+1)); echo "FAIL  installed differs from repo on main: $(basename "$f")"; fi
    fi
  done
  for repo in "$ROOT" "$ROOT/../McHomeLab-Inventory"; do
    hp=$(git -C "$repo" config core.hooksPath 2>/dev/null)
    if [ -n "$hp" ] && [ -x "$hp/pre-push" ]; then PASS=$((PASS+1)); echo "ok    core.hooksPath $(basename "$(cd "$repo" && pwd)")"; else FAIL=$((FAIL+1)); echo "FAIL  core.hooksPath unset in $(basename "$(cd "$repo" && pwd)") — run scripts/mhl-install-hooks"; fi
  done
  # The LIVE enforcement point is user scope: its hook commands must point at the installed copies.
  US="$HOME/.claude/settings.json"
  for f in "$H"/*.sh; do
    if [ -f "$US" ] && jq -e --arg c "bash \$HOME/.mhl/hooks/$(basename "$f")" '[.hooks // {} | to_entries[] | .value[] | .hooks[]?.command] | index($c) != null' "$US" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok    user settings wire $(basename "$f")"; else FAIL=$((FAIL+1)); echo "FAIL  ~/.claude/settings.json does not wire $(basename "$f") — GUARDS NOT ACTIVE on this machine (paste scripts/hooks/user-settings-hooks.json)"; fi
  done
fi
echo "HOOKS: $PASS passed, $FAIL failed"; [ $FAIL -eq 0 ]
