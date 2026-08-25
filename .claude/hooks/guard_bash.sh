#!/usr/bin/env bash
# PreToolUse[Bash]: deny the ad hoc mutation patterns that route around
# "no change without revision history" (CLAUDE.md rule 1). Deliberately narrow:
# a hook that denies too much gets worked around, and a worked-around hook
# enforces nothing. Reads are never blocked. Design: research/RESEARCH_SYSADMIN_AGENT.md §6.3
set -uo pipefail
PAYLOAD=$(cat)
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

deny() {
  jq -n --arg reason "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
}
ask() {
  jq -n --arg reason "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$reason}}'
  exit 0
}

LAB='(util|media|unifi|synology|printer|vc|ca\.util|esxi[0-9]*|idrac|xyz\.util|home\.util|wud\.util)(\.michaelpmcd\.com)?|192\.168\.(3|200|254|255)\.[0-9]+|172\.16\.[0-9]+\.[0-9]+'
MUTATE_VERBS='docker[[:space:]]+(exec|restart|stop|start|rm|kill|compose[[:space:]]+(up|down|restart|rm|pull))|sudo[[:space:]]+(rm|mv|cp|tee|systemctl[[:space:]]+(restart|stop|start|enable|disable)|apt|chmod|chown)|[^<>|]>>?[[:space:]]*/|sed[[:space:]]+-i|apt(-get)?[[:space:]]+(install|remove|purge|upgrade)|(^|[[:space:];&|])rm[[:space:]]|systemctl[[:space:]]+(restart|stop|start)'
INCIDENT_DIR="$HOME/workspace/McHomeLab-Inventory/incidents"
today_incident() { ls "$INCIDENT_DIR"/INCIDENT-"$(date +%F)"-*.md >/dev/null 2>&1; }

# 1. ad hoc ansible modules against a real host
if printf '%s' "$CMD" | grep -qE "(^|[[:space:];&|])ansible[[:space:]]+(-i[[:space:]]+[^[:space:]]+[[:space:]]+)?[^[:space:]]+([[:space:]]+-[^m][^[:space:]]*[[:space:]]+[^[:space:]]+)*[[:space:]]+-m[[:space:]]+(ansible\.builtin\.)?(shell|command|raw|script|uri|copy|file|template|lineinfile|blockinfile|systemd|service|apt)" \
   && ! printf '%s' "$CMD" | grep -qE "(^|[[:space:];&|])ansible[[:space:]]+(-i[[:space:]]+[^[:space:]]+[[:space:]]+)?localhost"; then
  deny "rule 1: ad hoc mutating module against a lab host. Declare it in a role/inventory and run site.yml (or --check). Read-only modules (setup, ping, debug) are fine."
fi
# 2. ssh to a lab host carrying a mutating command
if printf '%s' "$CMD" | grep -qE "(^|[[:space:];&|])ssh[[:space:]]+([^[:space:]]+[[:space:]]+)*([a-z]+@)?($LAB)" \
   && printf '%s' "$CMD" | grep -qE "$MUTATE_VERBS"; then
  today_incident && ask "emergency path: an incident record exists for today — confirm this manual action is recorded there (Q1: restarts allowed, parameter changes must be codified)."
  deny "rule 1: mutating command over ssh to a lab host. Codify it (role task + PR) or open incidents/INCIDENT-$(date +%F)-<slug>.md first (Q1)."
fi
# 3. docker --context / DOCKER_HOST against a managed host
if printf '%s' "$CMD" | grep -qE "docker[[:space:]]+(--context|-c)[[:space:]]+[^[:space:]]+[[:space:]]+(exec|restart|stop|start|rm|kill|compose[[:space:]]+(up|down|restart|rm|pull))|DOCKER_HOST=[^[:space:]]+[[:space:]]+docker[[:space:]]+(exec|restart|stop|start|rm|kill|compose)"; then
  today_incident && ask "emergency path: incident record exists for today — confirm this action is recorded there."
  deny "rule 1: mutating docker command against a managed host. Codify it, or open today's incident record first (Q1)."
fi
# 4. write-method HTTP calls to lab APIs
if printf '%s' "$CMD" | grep -qE "(^|[[:space:];&|])(curl|wget)[[:space:]]" \
   && printf '%s' "$CMD" | grep -qE "$LAB" \
   && printf '%s' "$CMD" | grep -qE -- "-X[[:space:]]*(POST|PUT|PATCH|DELETE)|--request[[:space:]]+(POST|PUT|PATCH|DELETE)|--post-data|--post-file|[[:space:]]-d[[:space:]]|--data|--form|[[:space:]]-F[[:space:]]"; then
  deny "rule 1: write-method HTTP call to a lab API. Use the idempotent api_setting task pattern (RESEARCH_SYSADMIN_AGENT.md §3 A2) in a role."
fi
# 5. cert issuance outside the step-ca-cert role
if printf '%s' "$CMD" | grep -qE "(^|[[:space:];&|])step[[:space:]]+ca[[:space:]]+(certificate|sign|renew|revoke)"; then
  deny "rule 1: certificate issuance happens only inside roles/step-ca-cert via site.yml."
fi
# 6. docker context create/rm on the controller (owned by the controller role)
if printf '%s' "$CMD" | grep -qE "docker[[:space:]]+context[[:space:]]+(create|rm|update)"; then
  deny "rule 1: docker CLI contexts are declared by the controller role, not created by hand."
fi
# 7. --limit with site.yml
if printf '%s' "$CMD" | grep -qE "ansible-playbook.*site\.yml" && printf '%s' "$CMD" | grep -qE -- "(^|[[:space:]])(--limit|-l)[[:space:]=]"; then
  deny "never --limit site.yml: hosts import from each other through the registry (memory: feedback_no_limit_flag)."
fi
# 8. applying site.yml from an uncommitted tree (Q9b: hard deny)
if printf '%s' "$CMD" | grep -qE "ansible-playbook.*site\.yml" && ! printf '%s' "$CMD" | grep -qE -- "--check"; then
  for repo in "$HOME/workspace/McHomeLab" "$HOME/workspace/McHomeLab-Inventory"; do
    if [ -n "$(git -C "$repo" status --porcelain -- ansible/ hosts.yml '*.yaml' '*.yml' 2>/dev/null)" ]; then
      deny "Q9b: site.yml apply from an uncommitted tree in $(basename "$repo"). Commit and open the PR first; --check runs are always allowed."
    fi
  done
fi
# 9. git: no commits/pushes to main, no history rewrite (PR workflow, Q5)
if printf '%s' "$CMD" | grep -qE "git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?push[[:space:]]" && printf '%s' "$CMD" | grep -qE "(--force|-f[[:space:]]|--force-with-lease|--delete[[:space:]]+main|[[:space:]]main([[:space:]]|$)|:main([[:space:]]|$))"; then
  deny "Q5: pushes go to a feature branch and land via PR; never to main, never forced."
fi
if printf '%s' "$CMD" | grep -qE "git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?commit" ; then
  for repo in "$HOME/workspace/McHomeLab" "$HOME/workspace/McHomeLab-Inventory"; do
    if printf '%s' "$CMD" | grep -q "$(basename "$repo")" || [ "$PWD" = "$repo" ] || [[ "$PWD" == "$repo"/* ]]; then
      [ "$(git -C "$repo" branch --show-current 2>/dev/null)" = "main" ] && deny "Q5: you are on main in $(basename "$repo"). Create a branch, commit there, open a PR."
    fi
  done
fi
# 10. recursive force delete
if printf '%s' "$CMD" | grep -qE '(^|[;&|]|\$\()[[:space:]]*rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*[rR])'; then
  deny "rule 4: no rm -rf without explicit confirmation — retire to archive/ instead."
fi
exit 0
