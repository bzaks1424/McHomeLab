VENV      := .venv/bin
INVENTORY := ansible/inventory/test.yml

.PHONY: ci deps lint yamllint ansible-lint syntax check render no-secrets no-secrets-all hooks hooks-installed secrets-matrix unit restore-test validate test

deps:
	cd ansible && ../$(VENV)/ansible-galaxy collection install -r requirements.yml -p ./collections --force
	$(VENV)/pip install -q -r requirements-dev.txt

# Restore rehearsal: decrypt + integrity-check every backup type from the live share
# (machine-dependent: needs /mnt/Backups and ~/.mhl/vault/backup.pass; not in validate).
restore-test:
	scripts/mhl-restore-test

# Unit tests: filter plugins and scripts modules, no Ansible runtime, no lab contact.
unit:
	$(VENV)/python -m pytest -q tests/unit

lint: yamllint ansible-lint

yamllint:
	$(VENV)/yamllint -c .yamllint ansible/

ansible-lint:
	cd ansible && ../$(VENV)/ansible-lint roles/ tasks/ group_vars/ filter_plugins/

check:
	cd ansible && ../$(VENV)/ansible-playbook site.yml -i ../$(INVENTORY) --check -v

syntax:
	cd ansible && ../$(VENV)/ansible-playbook tests/render.yml -i ../$(INVENTORY) --syntax-check

render:
	cd ansible && ../$(VENV)/ansible-playbook tests/render.yml -i ../$(INVENTORY)

no-secrets:
	scripts/mhl-no-secrets .

# Both repos — red until the inventory is vaulted (Phase 1).
no-secrets-all:
	scripts/mhl-no-secrets

hooks:
	scripts/hooks/test_hooks.sh

# Machine-dependent: installed copies present, wired from ~/.claude/settings.json, core.hooksPath set.
hooks-installed:
	MHL_HOOKS_INSTALLED=1 scripts/hooks/test_hooks.sh

# CI subset (GitHub Actions): everything that needs no machine state.
ci: lint syntax no-secrets hooks unit

# The green/red check. "Done" means this passed.
# Gate/tool agreement matrix. Exit 3 = SKIPPED (no venv/vault password) and is
# surfaced, not swallowed: validate stays red on a skip.
secrets-matrix:
	scripts/tests/secrets_matrix.sh

# Hook enforcement is disabled (Mike, 2026-08-25); `make hooks` / `make hooks-installed`
# remain runnable but are not part of validate.
validate: lint syntax render no-secrets secrets-matrix unit

test: validate restore-test
