#!/usr/bin/env bash
# PreToolUse[Bash]: deny the ad hoc mutation patterns that route around
# "no change without revision history" (CLAUDE.md rule 1). Deliberately narrow:
# a hook that denies too much gets worked around, and a worked-around hook
# enforces nothing. Reads are never blocked. Design: research/RESEARCH_SYSADMIN_AGENT.md §6.3
# Fail CLOSED: a missing dependency or unreadable payload is exit 2 (blocking error).
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "guard_bash: jq missing — refusing to run unguarded" >&2; exit 2; }
# Fixed repo paths: this script runs from the INSTALLED copy (~/.mhl/hooks),
# so its own location says nothing about where the repos are.
ROOT="$HOME/workspace/McHomeLab"
INV="$HOME/workspace/McHomeLab-Inventory"
PAYLOAD=$(cat) || exit 2
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""') || exit 2
[ -z "$CMD" ] && exit 0

deny() { jq -n --arg reason "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'; exit 0; }
ask()  { jq -n --arg reason "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$reason}}'; exit 0; }

# Word boundary that also covers shell wrappers and language strings: start,
# separators, quotes, parens, backticks, '=' (env prefix), so `bash -c 'ssh …'`,
# `python3 -c "…subprocess…ssh…"` and `eval "…"` are seen the same as bare forms.
B='(^|[[:space:];&|(`"'"'"'=])'
# Lab host names. HOSTS matches a bare short name or FQDN (ssh / docker context
# targets); NET matches only FQDN-or-IP forms (URLs, scp/rsync), so a URL path
# like api.example.com/media/upload is not mistaken for the media host.
HOSTS='(util|media|unifi|synology|printer|vc|ca\.util|xyz\.util|home\.util|wud\.util|esxi0[0-9]|idrac|ha)(\.michaelpmcd\.com)?'
NET='([a-z0-9.-]+\.)?(util|media|unifi|synology|printer|vc|esxi0[0-9]|idrac|ha)\.michaelpmcd\.com|192\.168\.(3|200|254|255)\.[0-9]+|172\.16\.[0-9]+\.[0-9]+'
TAIL='([[:space:]/:"'"'"']|$)'
# Mutating verbs INSIDE a quoted remote command (so a local `> /tmp/out` after the
# closing quote is not a hit). We extract the quoted remote part first.
MUTATE='docker[[:space:]]+(exec|restart|stop|start|rm|kill|compose[[:space:]]+(up|down|restart|rm|pull))|sudo[[:space:]]+(rm|mv|cp|tee|systemctl[[:space:]]+(restart|stop|start|enable|disable)|apt|chmod|chown)|[^<>|]>>?[[:space:]]*/|sed[[:space:]]+-i|apt(-get)?[[:space:]]+(install|remove|purge|upgrade)|(^|[[:space:];&|])rm[[:space:]]|systemctl[[:space:]]+(restart|stop|start)'
today_incident() { ls "$INV"/incidents/INCIDENT-"$(date +%F)"-*.md >/dev/null 2>&1; }
has() { printf '%s' "$CMD" | grep -qE -- "$1"; }
remote_part() { printf '%s' "$CMD" | grep -oE "ssh[[:space:]]+[^\"']*(\"[^\"]*\"|'[^']*')" | sed -E "s/^ssh[^\"']*//"; }

# 0. vault password must never be read by a shell command
if has "\.mhl/vault"; then deny "rule 5: the vault password is read only by ~/.mhl/bin/mhl-vault-client via ansible; never by a command."; fi

# 1. ad hoc mutating ansible module against a real host (localhost is fine)
if has "${B}ansible[[:space:]]+(-i[[:space:]]+[^[:space:]]+[[:space:]]+)?[^[:space:]-]+([[:space:]]+-[^m][^[:space:]]*[[:space:]]+[^[:space:]]+)*[[:space:]]+-m[[:space:]]+(ansible\.builtin\.)?(shell|command|raw|script|uri|copy|file|template|lineinfile|blockinfile|systemd|service|apt)" \
   && ! has "${B}ansible[[:space:]]+(-i[[:space:]]+[^[:space:]]+[[:space:]]+)?localhost"; then
  deny "rule 1: ad hoc mutating module against a lab host. Declare it in a role/inventory and run site.yml (or --check). Read-only modules (setup, ping, debug) are fine."
fi
# 2. ssh to a lab host carrying a mutating command (checked inside the quoted remote part)
if has "${B}ssh[[:space:]]+([^[:space:]]+[[:space:]]+)*([a-z]+@)?(${HOSTS}|${NET})${TAIL}"; then
  R=$(remote_part); [ -z "$R" ] && R=$(printf '%s' "$CMD" | sed -E 's/^.*ssh[[:space:]]+[^[:space:]]+[[:space:]]+//')
  if printf '%s' "$R" | grep -qE "$MUTATE"; then
    today_incident && ask "emergency path: an incident record exists for today — confirm this manual action is recorded there (Q1: restarts allowed, parameter changes must be codified)."
    deny "rule 1: mutating command over ssh to a lab host. Codify it (role task + PR) or open incidents/INCIDENT-$(date +%F)-<slug>.md first (Q1)."
  fi
fi
# 2c. wrapped shells / language one-liners carrying a lab host and a mutating
# verb (bash -c, sh -c, eval, python3 -c, perl -e ...) — the wrapper hides the
# structure, so any such combination is denied outright (review M4/M5).
if has "${B}(bash|sh|zsh|eval|python3?|perl|ruby|node)[[:space:]]+(-c|-e|\"|')" && has "(${HOSTS}|${NET})" && has "$MUTATE|docker[[:space:]]+(exec|restart|stop|start|rm|kill)|restart|systemctl"; then
  deny "rule 1: a wrapped shell/language one-liner that names a lab host and a mutating verb is denied outright — write the change as a role task instead."
fi
# 2b. file transfer onto a lab host
if has "${B}(scp|rsync|sftp)[[:space:]]" && has "(${NET})"; then
  deny "rule 1: scp/rsync/sftp to a lab host is a write. Deliver files with a role task (template/copy/registry import) via site.yml."
fi
# 3. docker --context / DOCKER_HOST against a managed host
if has "docker[[:space:]]+(--context|-c)[[:space:]]+[^[:space:]]+[[:space:]]+(exec|restart|stop|start|rm|kill|compose[[:space:]]+(up|down|restart|rm|pull))|DOCKER_HOST=[^[:space:]]+[[:space:]]+docker[[:space:]]+(exec|restart|stop|start|rm|kill|compose)"; then
  today_incident && ask "emergency path: incident record exists for today — confirm this action is recorded there."
  deny "rule 1: mutating docker command against a managed host. Codify it, or open today's incident record first (Q1)."
fi
# 4. write-method HTTP calls to lab APIs
if has "${B}(curl|wget)[[:space:]]" && has "(${NET})" \
   && has "-X[[:space:]]*(POST|PUT|PATCH|DELETE)|--request[[:space:]]+(POST|PUT|PATCH|DELETE)|--post-data|--post-file|[[:space:]]-d[[:space:]]|--data|--form|[[:space:]]-F[[:space:]]|--upload-file|[[:space:]]-T[[:space:]]"; then
  deny "rule 1: write-method HTTP call to a lab API. Use the idempotent api_setting task pattern (RESEARCH_SYSADMIN_AGENT.md §3 A2) in a role."
fi
# 5. cert issuance outside the step-ca-cert role
if has "${B}step[[:space:]]+ca[[:space:]]+(certificate|sign|renew|revoke)"; then
  deny "rule 1: certificate issuance happens only inside roles/step-ca-cert via site.yml."
fi
# 6. docker context create/rm on the controller (owned by the controller role)
if has "docker[[:space:]]+context[[:space:]]+(create|rm|update)"; then
  deny "rule 1: docker CLI contexts are declared by the controller role, not created by hand."
fi
# 7. --limit with site.yml
if has "ansible-playbook.*site\.yml" && has "(^|[[:space:]])(--limit|-l)[[:space:]=]"; then
  deny "never --limit site.yml: hosts import from each other through the registry (memory: feedback_no_limit_flag)."
fi
# 8. applying site.yml from an uncommitted tree (Q9b: hard deny); --check is always allowed
if has "ansible-playbook.*site\.yml" && ! has "--check"; then
  for repo in "$ROOT" "$INV"; do
    if [ -n "$(git -C "$repo" status --porcelain -- ansible/ hosts.yml '*.yaml' '*.yml' 2>/dev/null)" ]; then
      deny "Q9b: site.yml apply from an uncommitted tree in $(basename "$(cd "$repo" && pwd)"). Commit and open the PR first; --check runs are always allowed."
    fi
  done
fi
# 9. git: no pushes to the default branch (explicit or bare while on it), no history rewrite
if has "${B}git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?push"; then
  if has "(--force|[[:space:]]-f[[:space:]]|--force-with-lease|--delete[[:space:]]+main|[[:space:]]main([[:space:]]|$)|:main([[:space:]]|$)|--mirror)"; then
    deny "Q5: pushes go to a feature branch and land via PR; never to main, never forced."
  fi
  for repo in "$ROOT" "$INV"; do
    if [[ "$PWD" == "$repo"* ]] || has "$(basename "$(cd "$repo" 2>/dev/null && pwd)")"; then
      [ "$(git -C "$repo" branch --show-current 2>/dev/null)" = "main" ] && deny "Q5: bare git push while on main. Create a branch, commit there, open a PR."
    fi
  done
fi
if has "${B}git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?commit"; then
  for repo in "$ROOT" "$INV"; do
    if [[ "$PWD" == "$repo"* ]] || has "$(basename "$(cd "$repo" 2>/dev/null && pwd)")"; then
      [ "$(git -C "$repo" branch --show-current 2>/dev/null)" = "main" ] && deny "Q5: you are on main in $(basename "$(cd "$repo" && pwd)"). Create a branch, commit there, open a PR."
    fi
  done
fi
# 10. recursive force delete in any spelling (rm -rf, rm -fr, rm -r -f, sudo rm -rf, --recursive --force)
if has "${B}(sudo[[:space:]]+)?rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*[rR]|-[rR][[:space:]]+-f|-f[[:space:]]+-[rR]|--recursive[[:space:]]+--force|--force[[:space:]]+--recursive)"; then
  deny "rule 4: no rm -rf without explicit confirmation — retire to archive/ instead."
fi
exit 0
