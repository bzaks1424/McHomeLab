# McHomeLab

Ansible-based homelab automation. Go from a minimum viable footprint to a fully declared and functional home environment.

## Vision

Define your entire infrastructure in a single inventory file and let Ansible build, configure, and maintain everything — reproducibly and sequentially.

The system assumes a small set of **Tier 0 appliances** already exist (a storage device, a hypervisor, a network controller). Everything else is built on top of them, one item at a time, in dependency order. Each inventory item is at most reliant on items above it — if a utility server needs storage, the storage appliance must already be running. If you need to PXE install a machine, the appropriate networking and software services must be fully configured and working first.

This sequential model means:

- **Each item completes its full lifecycle before the next begins.** You can't half-build storage or networking, so you don't half-build VMs or servers either. Every host goes through **Validate, Provision, Import, Configure, and Export (V/P/I/C/E)** as an atomic unit.
- **Imports happen immediately post-provision, before configuration.** A freshly provisioned host may need certs, URLs, or config from hosts built before it. The registry makes these available as soon as the earlier host exports them.
- **Exports are back-references.** An export declaration in inventory is a promise that after V/P/I/C/E, a value or file will be available in the registry for later hosts to import. The registry acts as a persistent store — values can be written at any point in the lifecycle.
- **Imports can be optional.** Not everything needs to exist up front. Appliances generate their own self-signed certs; a CA-signed cert is an upgrade, not a prerequisite. Optional imports (`required: false`) skip gracefully when the dependency isn't available yet.

This isn't limited to VMs. A NAS, a network controller, a BMC, a printer — anything with an API is a host with a `provision.type` and `provision.manager`. The Best Task File dispatch (BTF) routes to the right task files; API-driven hosts just set `ansible_connection: local` and make outbound calls instead of SSH. The framework doesn't change.

The inventory tells the full story: what exists, what depends on what, and in what order to build it. Someone else can fork this, write their own inventory, drop in task files for their hardware, and build their own lab from scratch.

## How It Works

**One file defines your entire lab.** `hosts.yml` is the single source of truth — every host, its hardware, its services, and how they connect. Run `ansible-playbook site.yml` and the system figures out the rest.

```
hosts.yml                       site.yml
┌──────────────────────┐        ┌──────────────────────────────────┐
│ controller (pri: 0)  │        │ Play 0: Initialize               │
│ util       (pri: 10) │───────►│ Play 1: Configure controller     │
│ media      (pri: 20) │        │ Play 2: Build (serial V/P/I/C/E) │
│ ...                  │        └──────────────────────────────────┘
└──────────────────────┘
```

Hosts are processed in priority order, one at a time (`serial: 1`). Lower priority number = earlier execution. This guarantees dependencies are ready — for example, a utility server's CA certificate and PXE service URLs exist in the registry before a media server tries to import them.

## The V/P/I/C/E Lifecycle

Every host in the Build play goes through five phases, in order:

| Phase | What happens | Connection |
|-------|-------------|------------|
| **Validate** | Can we reach the host? If not, does the VM exist? If not, create it, boot it, and wait for the OS install to finish. | Local (API calls to hypervisor) |
| **Provision** | Part of validate — only runs when the host is missing. Creates the VM, prepares the boot environment (ISO or PXE), installs the OS. | Local |
| **Import** | Pull values and files from the registry into this host. A CA cert, a service URL, a config file — whatever earlier hosts exported. | SSH to host |
| **Configure** | BTF dispatch runs the appropriate configure task file. SSH keys, OS hardening, NFS mounts, Docker services — everything that makes this host do its job. | SSH to host |
| **Export** | Push values and files from this host into the registry for later hosts to consume. | SSH to host (fetch to controller) |

```
site.yml
│
├── Play 0: Initialize (localhost)
│   ├── Sort hosts by priority ──► build_hosts: [util, media, ...]
│   └── Initialize registry ────► load registry.json, purge stale file entries
│
├── Play 1: Configure Controller
│   ├── controller role ── NFS mounts, tooling (p7zip, xorriso, etc.)
│   └── Export to registry ── e.g. iso_root path for ISO builds
│
└── Play 2: Build (serial: 1, one host at a time)
    │
    │   For each host in priority order:
    │
    ├── VALIDATE (local connection)
    │   ├── Can we reach the host? (wait_for port check)
    │   │   ├── YES ── skip provisioning
    │   │   └── NO ─── BTF dispatch ── e.g. validate_vm_vmware.yml
    │   │       ├── Check hypervisor — does VM exist?
    │   │       ├── Create VM, prepare boot env (ISO or PXE)
    │   │       ├── Power on, wait for install to complete
    │   │       └── Clean up boot environment
    │   └── Ensure host is reachable
    │
    ├── GATHER FACTS (SSH to host)
    │
    ├── IMPORT (registry → host)
    │   ├── Validate required imports exist in registry
    │   ├── Copy files from controller to host
    │   └── Set variables as host facts
    │
    ├── CONFIGURE (BTF dispatch)
    │   ├── SSH authorized key
    │   ├── OS role (e.g. ubuntu ── apt proxy, chrony, vim-tiny)
    │   ├── NFS mounts (if declared)
    │   ├── Deploy Docker services (if declared)
    │   └── Extra software roles (if declared)
    │
    └── EXPORT (host → registry)
        ├── Fetch files from host to controller
        ├── Record values directly in registry
        └── Save registry.json to disk
```

## The Registry

The registry is a persistent JSON file (`registry.json`) that acts as a key-value store shared across hosts. It replaces hardcoded cross-host references — instead of one host reaching into another's variables, hosts export values to the registry and other hosts import them by name.

```
              Controller (export_root/)
                    │
        ┌───────────┼───────────┐
        │           │           │
     EXPORT      registry    IMPORT
     (fetch)      .json      (copy)
        │           │           │
   ┌────┴────┐ ┌────┴────┐ ┌───┴─────┐
   │ Host A  │ │  keys:  │ │ Host B  │
   │         │ │  ca_cert │ │         │
   │ exports │ │  pxe_url │ │ imports │
   │ ca_cert │ │  iso_root│ │ ca_cert │
   └─────────┘ └─────────┘ └─────────┘
```

**Two export types:**

- **File** — fetched from the host to the controller, path stored in registry. Example: a CA root certificate.
- **Var** — value stored directly in registry. Example: a PXE boot URL, an ISO storage path.

**Import behavior:**

- `required: true` (default) — fails the play if the key is missing from the registry.
- `required: false` — skips gracefully if the key isn't available yet.
- File imports copy from controller to host. Var imports become host facts.

**Staleness protection:**

- On init, the registry checks that every file entry still exists on disk. Missing files are purged.
- On import, a missing source file fails (required) or is silently skipped (optional).

In `hosts.yml`:
```yaml
# A utility server exports a CA cert and a PXE URL
util:
  export:
    - name: root_ca_cert
      type: file
      src: /opt/containers/step-ca/certs/root_ca.crt
    - name: pxe_base_url
      type: var
      value: "http://xyz.{{ ansible_host }}"

# A media server imports the CA cert
media:
  import:
    - name: root_ca_cert
      dest: /opt/certs/root_ca.crt
```

Priority ordering guarantees the utility server fully completes V/P/I/C/E (including exports) before the media server begins.

## BTF — Best Task File Dispatch

The core routing mechanism. When a task calls `import_tasks: best_task_file.yml`, it resolves the most specific task file available using `first_found`:

```
Given: role=host, action=validate, type=vm, manager=vmware

Lookup order (first match wins):
  1. validate_vm_vmware.yml     ◄── most specific
  2. validate_vm_all.yml
  3. validate_all_vmware.yml
  4. validate_all_all.yml       ◄── catch-all
  5. validate.yml               ◄── fallback
```

This means you can add support for a new hypervisor (e.g. Proxmox) by dropping in `validate_vm_proxmox.yml` and `provision_vm_proxmox.yml` — no changes to existing code. The same pattern extends to non-VM host types: `validate_appliance_synology.yml`, `configure_ipmi_idrac.yml`, etc.

**Current task files:**

| File | What it does |
|------|-------------|
| `validate_vm_vmware.yml` | Check vCenter, provision if VM missing |
| `validate_all_all.yml` | No-op (future API hosts, pre-existing hosts) |
| `provision_vm_vmware.yml` | Create VM, boot env, install, cleanup |
| `configure_all_all.yml` | SSH, OS, NFS, services, software |
| `configure_container_docker.yml` | Docker container lifecycle |

## Services

The `service` role turns `services:` definitions in inventory into a running Docker Compose stack. Services come in two flavors:

**Infrastructure services** — rendered from Jinja templates in the role (e.g. `traefik.yml.j2`, `gluetun.yml.j2`). These have complex config that benefits from template logic.

**Regular services** — rendered directly from inventory attributes. Traefik labels are auto-expanded from shorthand.

```yaml
# In hosts.yml — this is all you write:
services:
  radarr:
    priority: 20
    image: "lscr.io/linuxserver/radarr:latest"
    dns_name: radarr           # expands to traefik routing labels
    volumes:
      - "/opt/containers/radarr:/config"
    traefik:
      port: 7878

# The service role generates docker-compose.yml with:
#   - traefik routing labels (Host rule, TLS, cert resolver)
#   - bind mount directories pre-created
#   - priority-based ordering in the compose file
```

**Implicit software resolution** — you don't need to declare dependencies:

```
hardware.os: ubuntu ──► ubuntu role (meta deps: apt proxy, chrony, vim-tiny)
mounts[].type: nfs  ──► nfs-common role
services: defined   ──► service role (meta dep: docker)
```

## Roles

| Role | Purpose |
|------|---------|
| `host` | Entry point for all managed hosts. Dispatches to validate/configure via BTF |
| `host_provision` | Boot environment prep (ISO build or PXE script templating) |
| `registry` | Persistent import/export system (init, import, export, save) |
| `controller` | Controller-specific setup (NFS mounts, tooling) |
| `service` | Docker Compose generation and deployment from `services:` inventory |
| `ubuntu` | OS-level configuration (meta deps: apt, chrony, vim-tiny) |
| `docker` | Docker Engine installation and configuration |
| `iso` | ISO manipulation for autoinstall media |
| `apt` | APT proxy configuration |
| `chrony` | NTP client configuration |
| `nfs-common` | NFS client packages |
| `vim-tiny` | Editor installation |
| `p7zip` / `xorriso` | ISO build tooling (controller only) |

## Project Structure

```
ansible/
├── site.yml                          # Main playbook — 3 plays
├── ansible.cfg                       # Ansible configuration
├── filter_plugins/
│   └── registry_filters.py          # registry_get filter for safe lookups
├── tasks/
│   └── best_task_file.yml            # BTF dispatcher (first_found logic)
├── group_vars/
│   └── all/
│       ├── main.yml                  # Loads BTF variable definitions
│       └── best_task_file.yml        # BTF path patterns
└── roles/
    ├── host/
    │   ├── tasks/
    │   │   ├── main.yml              # Dispatches to validate.yml or configure.yml
    │   │   ├── validate.yml          # Port check → rescue → BTF provision
    │   │   ├── configure.yml         # BTF configure dispatch
    │   │   ├── validate_vm_vmware.yml
    │   │   ├── validate_all_all.yml
    │   │   ├── provision_vm_vmware.yml
    │   │   ├── configure_all_all.yml
    │   │   └── configure_container_docker.yml
    │   └── vars/main.yml             # Host variable derivations from inventory
    ├── registry/
    │   ├── tasks/
    │   │   ├── init.yml              # Load registry, purge stale file entries
    │   │   ├── import.yml            # Pull files + vars from registry to host
    │   │   ├── export.yml            # Push files + vars from host to registry
    │   │   └── save.yml              # Persist registry.json to disk
    │   └── vars/main.yml             # Registry path configuration
    ├── service/                      # Docker Compose generation
    │   ├── tasks/main.yml
    │   ├── vars/main.yml             # Service filtering (infra vs regular vs tunneled)
    │   ├── defaults/main.yml         # Paths and file modes
    │   ├── meta/main.yml             # Depends on: docker
    │   └── templates/
    │       ├── docker-compose.yml.j2 # Main compose template
    │       ├── traefik.yml.j2        # Traefik infrastructure template
    │       └── gluetun.yml.j2        # Gluetun VPN infrastructure template
    ├── host_provision/               # ISO and PXE boot environment
    ├── controller/                   # Controller-specific tasks
    ├── ubuntu/                       # OS config (deps: apt, chrony, vim-tiny)
    ├── docker/                       # Docker Engine install
    └── ...                           # apt, chrony, nfs-common, etc.
```

## Usage

```bash
# Full run — validates, provisions if needed, configures everything
ansible-playbook ansible/site.yml -i /path/to/hosts.yml -v

# Dry run — see what would change without touching anything
ansible-playbook ansible/site.yml -i /path/to/hosts.yml --check -v

# Limit to a single host (must include localhost for initialization)
ansible-playbook ansible/site.yml -i /path/to/hosts.yml --limit myhost,localhost -v
```

## Adding a New Host

1. Add the host to `hosts.yml` with a `priority`, `provision` block, and optionally `services`
2. Run `ansible-playbook site.yml` — BTF handles the rest
3. If it's a new hypervisor or host type, drop in the appropriate task files (e.g. `validate_vm_proxmox.yml`, `configure_appliance_synology.yml`)

## Inventory Structure

Each host in `hosts.yml` follows this structure:

```yaml
hostname:
  priority: 20                    # Execution order (lower = first)
  ansible_host: hostname.domain   # How to reach it

  import:                         # Values/files to pull from registry before configure
    - name: root_ca_cert
      dest: /opt/certs/root_ca.crt
    - name: some_url              # Var imports don't need a dest — they become facts
      required: false             # Optional — skip if not in registry

  export:                         # Values/files to push to registry after configure
    - name: my_cert
      type: file
      src: /path/on/host
    - name: my_url
      type: var
      value: "http://{{ ansible_host }}:8080"

  provision:                      # How this host gets created
    type: vm                      # vm | controller | (future: appliance, ipmi, ...)
    manager: vmware               # vmware | (future: proxmox, libvirt, ...)
    method: iso                   # iso | pxe
    reprovision: true
    validate:
      port: 22
    hardware:
      os: ubuntu
      cpus: 2
      ram_mb: 8192
      disks: [...]
      networks: [...]
    manager_infra:                # Manager-specific settings (ignored by other managers)
      datacenter: "HomeLab"
      cluster: "ClusterNuc"
    mounts:                       # NFS shares to mount
      - src: nas:/volume1/share
        path: /mnt/share
        type: nfs
        options: defaults,vers=4.1

  services:                       # Docker Compose services (optional)
    traefik:
      priority: 0
      type: infrastructure
      config: { ... }
    my-app:
      priority: 10
      image: "myimage:latest"
      dns_name: app
      traefik:
        port: 8080

  software:                       # Extra roles beyond implicit resolution (optional)
    custom-role: {}
```
