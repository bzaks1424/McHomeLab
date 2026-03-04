# McHomeLab

Ansible-based homelab automation. Define your infrastructure in a single inventory file and let Ansible build, configure, and maintain everything.

## How It Works

**One file defines your entire lab.** `hosts.yml` is the single source of truth — every host, its hardware, its services, and how they connect. Run `ansible-playbook site.yml` and the system figures out the rest.

```
hosts.yml                       site.yml
┌──────────────────────┐        ┌──────────────────────────────────┐
│ controller (pri: 0)  │        │ Play 0: Build execution order    │
│ util       (pri: 10) │───────►│ Play 1: Configure controller     │
│ media      (pri: 20) │        │ Play 2: Validate & provision     │
│ ...                  │        │ Play 3: Configure                │
└──────────────────────┘        └──────────────────────────────────┘
```

Hosts are processed in priority order, one at a time (`serial: 1`). Lower priority number = earlier execution. This guarantees dependencies are ready — util's CA cert exists before media tries to import it.

## Playbook Flow

```
site.yml
│
├── PLAY 0: Build Execution Order (localhost)
│   ├── Sort hosts by priority ──► build_hosts: [util, media]
│   ├── Collect exports ──────────► scan all hosts for export: declarations
│   └── Build export registry ────► { root_ca_cert: util }
│
├── PLAY 1: Configure Controller
│   └── controller role ── NFS mounts, tooling (p7zip, xorriso, etc.)
│
├── PLAY 2: Validate & Provision (serial: 1, per host)
│   │
│   │   For each host, the validate step:
│   │
│   ├── Can we reach the host? (wait_for port check)
│   │   ├── YES ── skip provisioning
│   │   └── NO ─── BTF dispatch ── validate_vm_vmware.yml
│   │       ├── Check vCenter — does VM exist?
│   │       ├── Create VM (poweredoff)
│   │       ├── Get MAC address
│   │       ├── Prepare boot environment (ISO or PXE)
│   │       ├── Power on, wait for install
│   │       └── Cleanup boot environment
│   │
│   └── Ensure powered on, wait for SSH, add host key
│
└── PLAY 3: Configure (serial: 1, per host, gather_facts)
    │
    │   configure.yml — the "sandwich":
    │
    ├── IMPORT ── copy files from controller to host
    │   └── e.g. root_ca_cert ──► /opt/certs/root_ca.crt on media
    │
    ├── BTF CONFIGURE ── configure_all_all.yml (common path)
    │   ├── SSH authorized key
    │   ├── OS role (ubuntu ── apt proxy, chrony, vim-tiny)
    │   ├── NFS mounts (nfs-common + mount)
    │   ├── Deploy services (service role, if services: defined)
    │   └── Extra software (include_role loop)
    │
    └── EXPORT ── fetch files from host to controller
        └── e.g. root_ca.crt from util ──► ~/.mhl/util/root_ca_cert
```

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

This means you can add support for a new hypervisor (e.g. Proxmox) by dropping in `validate_vm_proxmox.yml` and `provision_vm_proxmox.yml` — no changes to existing code.

**Current task files:**

| File | What it does |
|------|-------------|
| `validate_vm_vmware.yml` | Check vCenter, provision if VM missing |
| `validate_all_all.yml` | No-op (containers, future API hosts) |
| `provision_vm_vmware.yml` | Create VM, boot env, install, cleanup |
| `configure_all_all.yml` | SSH, OS, NFS, services, software |
| `configure_container_docker.yml` | Docker container lifecycle |

## Import/Export System

Hosts share files through the controller as a hub. The flow is baked into `configure.yml` as a sandwich around the BTF configure step.

```
              Controller (~/.mhl/)
                    │
        ┌───────────┼───────────┐
        │           │           │
     EXPORT      storage     IMPORT
     (fetch)                  (copy)
        │           │           │
   ┌────┴────┐ ┌────┴────┐ ┌───┴─────┐
   │  util   │ │  .mhl/  │ │  media  │
   │         │ │  util/   │ │         │
   │ step-ca │ │   root_  │ │ traefik │
   │ exports │ │   ca_    │ │ imports │
   │ root_ca │ │   cert   │ │ root_ca │
   └─────────┘ └─────────┘ └─────────┘
```

In `hosts.yml`:
```yaml
# util exports a file
util:
  export:
    - name: root_ca_cert
      src: /opt/containers/step-ca/certs/root_ca.crt

# media imports it
media:
  import:
    - name: root_ca_cert
      dest: /opt/certs/root_ca.crt
      # from: util  ← optional, auto-resolved via export_registry
```

Priority ordering guarantees exports happen before imports — util (priority 10) fully configures and exports before media (priority 20) starts.

## Services

The `service` role turns `services:` definitions in inventory into a running Docker Compose stack. Services come in two flavors:

**Infrastructure services** — rendered from Jinja templates in the role (`traefik.yml.j2`, `gluetun.yml.j2`). These have complex config that benefits from template logic.

**Regular services** — rendered directly from inventory attributes. Traefik labels are auto-expanded from shorthand.

```yaml
# In hosts.yml — this is all you write:
services:
  radarr:
    priority: 20
    image: "lscr.io/linuxserver/radarr:latest"
    dns_name: radarr           # ← expands to traefik labels automatically
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
| `controller` | Controller-specific setup (NFS mounts, tooling) |
| `service` | Docker Compose generation and deployment from `services:` inventory |
| `ubuntu` | OS-level configuration (meta deps: apt, chrony, vim-tiny) |
| `docker` | Docker Engine installation and configuration |
| `iso` | ISO manipulation for autoinstall media |
| `apt` | APT proxy configuration (apt-cacher-ng) |
| `chrony` | NTP client configuration |
| `nfs-common` | NFS client packages |
| `vim-tiny` | Editor installation |
| `p7zip` / `xorriso` | ISO build tooling (controller only) |

## Project Structure

```
ansible/
├── site.yml                          # Main playbook — 4 plays
├── ansible.cfg                       # Ansible configuration
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
    │   │   ├── configure.yml         # Import → BTF configure → Export
    │   │   ├── validate_vm_vmware.yml
    │   │   ├── validate_all_all.yml
    │   │   ├── provision_vm_vmware.yml
    │   │   ├── configure_all_all.yml
    │   │   └── configure_container_docker.yml
    │   └── vars/main.yml             # Host variable derivations from inventory
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
ansible-playbook site.yml -i /path/to/hosts.yml -v

# Dry run — see what would change without touching anything
ansible-playbook site.yml -i /path/to/hosts.yml --check -v

# Limit to a single host (must include localhost for step 0)
ansible-playbook site.yml -i /path/to/hosts.yml --limit media,localhost -v
```

## Adding a New Host

1. Add the host to `hosts.yml` with a `priority`, `provision` block, and optionally `services`
2. Run `ansible-playbook site.yml` — BTF handles the rest
3. If it's a new hypervisor or OS, drop in the appropriate task files (e.g. `validate_vm_proxmox.yml`)

## Inventory Structure

Each host in `hosts.yml` follows this structure:

```yaml
hostname:
  priority: 20                    # Execution order (lower = first)
  ansible_host: hostname.domain   # How to reach it

  import:                         # Files to pull from controller before configure
    - name: root_ca_cert
      dest: /opt/certs/root_ca.crt

  export:                         # Files to push to controller after configure
    - name: some_artifact
      src: /path/on/host

  provision:                      # How this host gets created
    type: vm                      # vm | container | controller | (future: appliance, bmc, ...)
    manager: vmware               # vmware | (future: proxmox, libvirt, ...)
    method: pxe                   # iso | pxe
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
