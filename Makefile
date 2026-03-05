VENV      := .venv/bin
INVENTORY := ansible/inventory/test.yml

.PHONY: lint yamllint ansible-lint check test

lint: yamllint ansible-lint

yamllint:
	$(VENV)/yamllint -c .yamllint ansible/

ansible-lint:
	cd ansible && ../$(VENV)/ansible-lint roles/ tasks/ group_vars/ filter_plugins/

check:
	cd ansible && ../$(VENV)/ansible-playbook site.yml -i ../$(INVENTORY) --check -v

test: lint
