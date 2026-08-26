---
paths: ["**/hosts.yml", "**/McHomeLab-Inventory/**"]
---
# Editing the inventory
- Every string value double-quoted; `priority` is mandatory on every service.
- Secrets: never paste a plaintext value. Use `scripts/mhl-vault-file <file>`
  (vault-id `mhl`; the key stays plaintext so diffs show what changed). Afterwards: escrow the plaintext original in the password safe, then
  `scripts/mhl-vault-file --purge --dry-run <file>` / `--purge <file>`.
- Cross-host references go through the registry (`import`/`export`), never
  literal hostnames/IPs. DNS servers equal the VLAN gateway.
- After editing: `make render INVENTORY=../McHomeLab-Inventory/hosts.yml` and
  `scripts/mhl-no-secrets ../McHomeLab-Inventory` must both pass.
- Commit on a branch in the inventory repo and open its own PR.
