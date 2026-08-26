VENV      := .venv/bin
INVENTORY := ansible/inventory/test.yml

.PHONY: ci deps lint yamllint ansible-lint syntax check render no-secrets no-secrets-all secrets-matrix unit restore-test validate test

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
	cd ansible && ../$(VENV)/ansible-lint roles/ tasks/ group_vars/ filter_plugins/ library/ module_utils/ tests/

check:
	cd ansible && ../$(VENV)/ansible-playbook site.yml -i ../$(INVENTORY) --check -v

syntax:
	cd ansible && ../$(VENV)/ansible-playbook tests/render.yml -i ../$(INVENTORY) --syntax-check

render:
	cd ansible && ../$(VENV)/ansible-playbook tests/render.yml -i ../$(INVENTORY)

no-secrets:
	scripts/mhl-no-secrets .

# Both repos (the inventory is vaulted; this is the cross-repo gate).
no-secrets-all:
	scripts/mhl-no-secrets

# CI subset (GitHub Actions): everything that needs no machine state.
ci: lint syntax no-secrets unit

# The green/red check. "Done" means this passed.
# Gate/tool agreement matrix. Exit 3 = SKIPPED (no venv/vault password) and is
# surfaced, not swallowed: validate stays red on a skip.
secrets-matrix:
	scripts/tests/secrets_matrix.sh

# Hook enforcement was retired 2026-08-25 (archive/governance-hooks); PR review + validate are the gate.
validate: lint syntax render no-secrets secrets-matrix unit

test: validate restore-test
