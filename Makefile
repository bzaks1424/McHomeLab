VENV      := .venv/bin
INVENTORY := ansible/inventory/test.yml

.PHONY: ci deps lint yamllint ansible-lint syntax check render no-secrets no-secrets-all hooks hooks-installed validate test

deps:
	cd ansible && ../$(VENV)/ansible-galaxy collection install -r requirements.yml -p ./collections --force

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
ci: lint syntax no-secrets hooks

# The green/red check. "Done" means this passed.
validate: lint syntax render no-secrets hooks-installed

test: validate
