---
name: drift
description: Read-only drift check — what would site.yml change, plus compose config-hash comparison per host.
argument-hint: "[host]"
context: fork
agent: drift-checker
---
Report drift between the declared state (committed `hosts.yml` + roles) and the
live fleet. Read-only; never apply anything.
1. Run exactly (two commands; both are allow-listed verbatim in `.claude/settings.json`, so do not vary the form):
   `cd /home/mmcdonnell/workspace/McHomeLab/ansible`
   `../.venv/bin/ansible-playbook site.yml -i ../../McHomeLab-Inventory/hosts.yml --check --diff`
   Summarise per host: tasks that would change, with the diff for templated files (redact any secret values).
2. For each docker host (util, media, unifi): render via `make render INVENTORY=../McHomeLab-Inventory/hosts.yml`, then compare `docker compose -f /tmp/mhl-render/<host>/docker-compose.yml config --hash '*'` against `docker --context <host> inspect -f '{{index .Config.Labels "com.docker.compose.config-hash"}}' <container>` for every service; list mismatches.
3. Output a findings list (severity, host, what, evidence, proposed codified fix). If nothing drifted, say so plainly.
