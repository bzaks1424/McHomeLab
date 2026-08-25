#!/usr/bin/env bash
# Tests for .claude/hooks/*. Payloads live here, not in Bash tool calls, so
# testing a guard never trips it. Prints ok/FAIL rows; exits 1 on any failure.
set -uo pipefail
H="$(cd "$(dirname "$0")/../.." && pwd)/.claude/hooks"
PASS=0; FAIL=0
expect() { # name hook want payload
  local got; got=$(printf '%s' "$4" | bash "$H/$2" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // .decision // "allow"' 2>/dev/null); got=${got:-allow}
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
expect "empty allowed"                           $G allow "$(b '')"
W=guard_writes.sh
expect "write role file allowed"                 $W allow "$(w "$HOME/workspace/McHomeLab/ansible/roles/service/tasks/main.yml")"
expect "write hosts.yml allowed"                 $W allow "$(w "$HOME/workspace/McHomeLab-Inventory/hosts.yml")"
expect "write registry.json denied"              $W deny  "$(w "$HOME/.mhl/registry.json")"
expect "write vault pass denied"                 $W deny  "$(w "$HOME/.mhl/vault/mhl.pass")"
expect "write archive denied"                    $W deny  "$(w "$HOME/workspace/McHomeLab/archive/roles/uisp/tasks/main.yml")"
expect "write /etc denied"                       $W deny  "$(w "/etc/hosts")"
expect "write /opt/docker denied"                $W deny  "$(w "/opt/docker/compose/docker-compose.yml")"
expect "write memory allowed"                    $W allow "$(w "$HOME/.claude/projects/-home-mmcdonnell-workspace-McHomeLab/memory/x.md")"
expect "write scratchpad allowed"                $W allow "$(w "/tmp/claude-1000/x/scratchpad/y")"
expect "write other repo denied"                 $W deny  "$(w "$HOME/workspace/claude/todo.md")"
C=check_edit.sh
T=$(mktemp -d "$HOME/workspace/McHomeLab/.hooktest.XXXXXX"); trap 'rm -rf "$T"' EXIT
printf 'key: [\n' > "$T/bad.yml"; printf -- '---\nkey: "v"\n' > "$T/ok.yml"; printf 'if [\n' > "$T/bad.sh"; printf 'echo hi\n' > "$T/ok.sh"
expect "check bad yaml blocks"                   $C block "$(w "$T/bad.yml")"
expect "check ok yaml passes"                    $C allow "$(w "$T/ok.yml")"
expect "check bad sh blocks"                     $C block "$(w "$T/bad.sh")"
expect "check ok sh passes"                      $C allow "$(w "$T/ok.sh")"
expect "check nonexistent passes"                $C allow "$(w "$T/nope.yml")"
S=$(printf '{}' | bash "$H/session_context.sh" | jq -r '.hookSpecificOutput.additionalContext'); if printf '%s' "$S" | grep -q 'Binding: CLAUDE.md'; then PASS=$((PASS+1)); echo "ok    session_context injects rules"; else FAIL=$((FAIL+1)); echo "FAIL  session_context"; fi
echo "HOOKS: $PASS passed, $FAIL failed"; [ $FAIL -eq 0 ]
