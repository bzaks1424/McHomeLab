---
name: apply-site
description: Apply site.yml to the fleet from a committed tree. Human-invoked only.
disable-model-invocation: true
argument-hint: "[extra ansible-playbook args, e.g. -e service_pull_policy=always]"
---
Apply the declared state to the whole fleet. Preconditions you MUST verify and
show before running (stop if any fails):
1. Both repos clean and on a committed ref: `git -C ~/workspace/McHomeLab status --porcelain` and the same for `McHomeLab-Inventory` are empty; report each branch.
2. `make validate` green (quote the last line).
3. A `--check --diff` run first, summarised per host (changed/failed counts and every task name that would change). Show it and wait for Mike's explicit "apply".
Then run, from `ansible/`:
`../.venv/bin/ansible-playbook site.yml -i ../../McHomeLab-Inventory/hosts.yml -v $ARGUMENTS`
Never add `--limit`. Afterwards: verify the changed services with read-only checks
(`docker --context <host> ps`, health endpoints) and report verbatim. Record
anything unexpected as a finding.
