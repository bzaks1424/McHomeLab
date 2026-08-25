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
ROOT=$(realpath -m "${MHL_REPO:-$HOME/workspace/McHomeLab}")
INV=$(realpath -m "${MHL_INVENTORY:-$HOME/workspace/McHomeLab-Inventory}")
PAYLOAD=$(cat) || exit 2
# Scope: these hooks are wired from USER settings, so they run in every Claude
# session on this machine. They act only when the session is inside McHomeLab
# or the inventory; elsewhere they allow everything (review round-3 addendum).
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // ""')
case "$CWD" in "$ROOT"|"$ROOT"/*|"$INV"|"$INV"/*) ;; *) exit 0 ;; esac
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
# Every verb is anchored on the same boundary class as B (quotes included) so a
# verb at position 0 of a quoted remote command, or after && ; | is matched.
# A read-prefixed remote command that chains into any of these is denied too.
MV='(^|[[:space:];&|(`"'"'"'=])'
DOCKER_VERBS='exec|restart|stop|start|rm|rmi|kill|run|create|cp|build|update|load|import|commit|pause|unpause|rename|tag|push|(image|system|container|volume|network|builder)[[:space:]]+(prune|rm|remove|create)|compose([[:space:]]+-[-a-z]+[[:space:]]+[^[:space:]]+)*[[:space:]]+(up|down|restart|rm|pull|build|create|kill|stop|start|exec|run)'
SIMPLE_VERBS='rm|mv|cp|tee|dd|chmod|chown|chgrp|truncate|install|ln|touch|mkdir|rmdir|shred|reboot|shutdown|poweroff|halt|kill|pkill|killall|crontab|useradd|usermod|userdel|passwd|mount|umount|swapoff|swapon|ip|iptables|nft|ufw|patch|rsync|scp|make|python3?|bash|sh|eval|source|sed[[:space:]]+(-i|--in-place)|perl[[:space:]]+-pi|git[[:space:]]+(checkout|reset|clean|pull|push|commit)'
END='([[:space:];&|"'"'"')]|$)'
MUTATE="${MV}(sudo[[:space:]]+)?((docker[[:space:]]+([-a-z]+[[:space:]]+)*(${DOCKER_VERBS}))|(docker-compose[[:space:]]+([-a-z]+[[:space:]]+[^[:space:]]+[[:space:]]+)*(up|down|restart|rm|pull|build|create|kill|stop|start|exec|run))|(systemctl[[:space:]]+(restart|stop|start|enable|disable|mask|unmask|daemon-reload))|((apt|apt-get|dpkg|snap)[[:space:]]+(install|remove|purge|upgrade|dist-upgrade|autoremove))|((${SIMPLE_VERBS})${END}))|[^<>|]>>?[[:space:]]*[/~]"
today_incident() { ls "$INV"/incidents/INCIDENT-"$(date +%F)"-*.md >/dev/null 2>&1; }
has() { printf '%s' "$CMD" | grep -qE -- "$1"; }
remote_part() { printf '%s' "$CMD" | grep -oE "ssh[[:space:]]+[^\"']*(\"[^\"]*\"|'[^']*')" | sed -E "s/^ssh[^\"']*//"; }

# 0. vault password must never be read by a shell command
if has "\.mhl/vault"; then deny "rule 5: the vault password is read only by ~/.mhl/bin/mhl-vault-client via ansible; never by a command."; fi
# 0b. no Bash-route writes to governance paths (review round-3 B1/B2): the file
# guard only sees Write/Edit, so redirects, tee, cp/mv, sed -i, curl -o, python
# open(...,'w'), rm, chmod, install, ln against these paths are denied here.
GOV='(\.claude/|\.mhl/(hooks|bin|approvals|archive|pre-vault)|(^|[[:space:]/"'"'"'=])(CLAUDE(\.local)?\.md|Makefile|\.github/|\.yamllint|\.ansible-lint\.yml|scripts/(hooks|git-hooks|tests)/|scripts/(mhl-install-hooks|mhl-no-secrets|mhl_secrets\.py|mhl-vault-file|mhl-pr)))'
if has "$GOV"; then
  if has "(>>?[[:space:]]*[^[:space:]]*${GOV})|${B}(tee|cp|mv|install|ln|rm|chmod|chown|touch|truncate|dd|patch|rsync)[[:space:]]+([^;&|]*[[:space:]])?[^[:space:]]*${GOV}|sed[[:space:]]+(-[a-zA-Z]*i|--in-place)|(curl|wget)[[:space:]]+.*(-o|-O|--output|--output-dir|--remote-name)|python3?[[:space:]]+-c.*open\(|open\([^)]*['\"][wa]|shutil\.|os\.(remove|unlink|rename|replace|chmod)|git[[:space:]]+(checkout|restore|apply|stash[[:space:]]+pop)[^|]*${GOV}"; then
    deny "rule 8: governance paths (.claude/, ~/.mhl/{hooks,bin,approvals}, ~/.claude, CLAUDE.md, Makefile, .github, lint configs, scripts/{hooks,git-hooks,tests}, the gate and installer) are not written by shell commands — change them on a branch with the file tools and land via PR."
  fi
fi

# 1. ad hoc mutating ansible module against a real host (localhost is fine)
MUT_MODULES='shell|command|raw|script|uri|copy|file|template|lineinfile|blockinfile|replace|unarchive|get_url|reboot|user|group|cron|pip|authorized_key|known_hosts|systemd|service|apt|apt_repository|dnf|yum|package|mount|docker_container|docker_compose(_v2)?|docker_image|docker_network|docker_volume|iptables|ufw|firewalld|hostname|timezone|sysctl|modprobe|lvol|filesystem|parted|synchronize|assemble|ini_file|xml|yedit|git|make'
# Any `ansible <pattern> … -m <mutating module>` where the pattern is not localhost.
# Flags before -m may or may not take values (-b, --become, -o, -v...), so the
# pattern is located independently: the first non-flag token after `ansible`.
if has "${B}ansible[[:space:]]+(.*[[:space:]])?-m[[:space:]]+([a-z_]+\.[a-z_]+\.)?(${MUT_MODULES})([[:space:]]|$)" \
   && ! has "${B}ansible[[:space:]]+((-[-a-zA-Z]+([[:space:]=]+[^[:space:]-][^[:space:]]*)?)[[:space:]]+)*localhost([[:space:]]|$)"; then
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
if has "${B}(bash|sh|zsh|eval|python3?|perl|ruby|node)[[:space:]]+(-c|-e|\"|')" && has "(^|[[:space:]/@\"'=:,\[(])(${HOSTS}|${NET})${TAIL}|(^|[[:space:]\"',\[(])(${HOSTS})[\"',)\]]" && has "$MUTATE"; then
  deny "rule 1: a wrapped shell/language one-liner that names a lab host and a mutating verb is denied outright — write the change as a role task instead."
fi
# 2b. file transfer onto a lab host (short names count here: `media:` is a target)
if has "${B}(scp|rsync|sftp)[[:space:]]" && has "(${NET})|(^|[[:space:]@])(${HOSTS})(:|[[:space:]]|$)"; then
  deny "rule 1: scp/rsync/sftp to a lab host is a write. Deliver files with a role task (template/copy/registry import) via site.yml."
fi
# 3. docker --context / DOCKER_HOST against a managed host
CTX_VERBS='(exec|restart|stop|start|rm|rmi|kill|run|create|cp|build|update|load|import|commit|pause|unpause|rename|tag|push|(image|system|container|volume|network|builder)[[:space:]]+(prune|rm|remove|create)|compose([[:space:]]+-[-a-z]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+(up|down|restart|rm|pull|build|create|kill|stop|start|exec|run))'
if has "docker[[:space:]]+(--context|-c|--host|-H)[[:space:]]+[^[:space:]]+([[:space:]]+-[-a-z]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+${CTX_VERBS}|DOCKER_HOST=[^[:space:]]+[[:space:]]+docker[[:space:]]+${CTX_VERBS}|DOCKER_CONTEXT=[^[:space:]]+[[:space:]]+docker[[:space:]]+${CTX_VERBS}"; then
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
if has "docker[[:space:]]+context[[:space:]]+(create|rm|update|use|import)"; then
  deny "rule 1: docker CLI contexts are declared by the controller role, not created, switched or imported by hand (use --context per command)."
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
