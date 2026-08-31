VENV      := .venv/bin
INVENTORY := ansible/inventory/test.yml
# The real fleet lives in the sibling repo. Kept RELATIVE to the repo root: the
# recipes below prefix `../` after `cd ansible`. INVENTORY_REPO is empty when the
# sibling is not checked out (CI), so `make ci` is unaffected.
INVENTORY_REPO := $(wildcard ../McHomeLab-Inventory)
INVENTORY_REAL := ../McHomeLab-Inventory/hosts.yml

.PHONY: ci deps lint yamllint ansible-lint syntax check render render-real no-secrets no-secrets-all secrets-matrix unit restore-test validate test

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
	$(VENV)/yamllint -c .yamllint ansible/ $(INVENTORY_REPO)

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

# Offline render against the REAL inventory - the only thing that exercises the
# unifi traefik external_routes template. Needs the vault password and the sibling
# checkout, so it belongs to `validate`, never to `ci`.
# NB: does NOT cover the synology/printer appliance cert paths - those live in
# roles/host and are reached only by site.yml (`make check`), not by render.yml.
render-real:
	cd ansible && ../$(VENV)/ansible-playbook tests/render.yml -i ../$(INVENTORY_REAL)

# CI subset (GitHub Actions): everything that needs no machine state.
ci: lint syntax no-secrets unit

# The green/red check. "Done" means this passed.
# Gate/tool agreement matrix. Exit 3 = SKIPPED (no venv/vault password) and is
# surfaced, not swallowed: validate stays red on a skip.
secrets-matrix:
	scripts/tests/secrets_matrix.sh

# Hook enforcement was retired 2026-08-25 (archive/governance-hooks); PR review + validate are the gate.
# no-secrets-all is a strict superset of no-secrets: it scans this repo AND the
# inventory, which is the one that actually holds the secrets. `ci` keeps the
# narrow form because it has no sibling checkout.
validate: lint syntax render render-real no-secrets-all secrets-matrix unit

test: validate restore-test
