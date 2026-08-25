# R-C — UniFi as Ansible-declarable config (research, 2026-08-25)

Scope: find the best Ansible path to declare UniFi Network config idempotently
against controller 10.1.84 (Integration API v1 at `/proxy/network/integration/v1`,
`X-API-KEY` auth, plus legacy Session API for what Integration doesn't cover) —
networks/VLANs, firewall zones + policies (+ ordering), DNS policies/records,
traffic matching lists, ACL rules, DHCP reservations (legacy API only), WiFi.

Inputs read first: `RESEARCH_SYSADMIN_AGENT.md` §5 (UniFi rows), §9 Q7/Q8, §11 R-C;
`~/.claude/skills/unifly/SKILL.md`; `unifly --help` and per-command `--help` output
(read-only, no controller contact). No live-controller calls were made beyond
`--help`, per the task constraint — the object-type coverage claims below rely on
the parent research doc's §5 findings (already verified against 10.1.84 on
2026-08-24) plus this session's library/collection source reading, not a fresh
live read.

---

## 1. Ranked shortlist

| Rank | Candidate | Type | API used | Maintenance | Idempotent / check_mode | License |
|---|---|---|---|---|---|---|
| 1 | **`hellqvio86.unifi`** (Ansible Galaxy collection) | Real Ansible collection, typed modules | Legacy Session API only (username/password + cookie), "v2" controller endpoints (`/proxy/network/v2/api/site/...`) for firewall zone/policy, `rest/` for groups | Active — created 2026-05-14, latest `0.0.26` pushed 2026-08-24, CI+unit tests, 1077 downloads. **Marked "Alpha Status" by the author**: "APIs and module arguments are subject to breaking changes" | Yes for what it covers — verified by reading `plugins/modules/unifi_firewall_policy.py`: real GET→compare→PUT logic, `supports_check_mode=True`, `changed` computed from a diff, not blind re-apply | MIT |
| 2 | **unifly (current tool) driven from `command`/`shell` tasks** | Not an Ansible module — a Rust CLI, called from Ansible | Both: Integration API v1 (`X-API-KEY`) primary, Session API fallback (documented in `unifly --help` banner: "Uses the official Integration API (v10.1.84) as primary interface, with session API fallback") | Actively used in this project (already deployed, `unifly 0.9.0`) | Not idempotent out of the box — **no create-or-update endpoint exists** (confirmed by parent doc §5); idempotency has to be hand-built as a pre-GET + `changed_when` in the playbook, same pattern §5 already recommends | Unverified (not checked this session) |
| 3 | **Official Ubiquiti `ubiquiti.unifi_api` collection** | Vendor-provided, distributed off `developer.ui.com`'s own Ansible quick-start page | Integration API only — confirmed by reading `plugins/module_utils/base_module.py`: base URL is built as `{base_url}/proxy/{app}/integration`, auth is `X-API-KEY` (or `token`) | Vendor-shipped tarball at `https://apidoc-cdn.ui.com/ansible-module/ubiquiti-unifi_api-latest.tar.gz`; version `1.0.0`, tarball timestamp 2026-01-23. No public repo found (not on GitHub under that name), so no issue tracker/commit history to gauge cadence | **Not idempotent.** It is a single generic OpenAPI-driven passthrough module per app (`network`, `protect`) taking `path`/`method`/`body`/`query` — functionally a typed `uri` wrapper generated from the OpenAPI spec, no per-object GET-compare-PUT logic. Independently confirmed by [engyak.co, Apr 2026](https://blog.engyak.co/2026/04/ubnt-ansible/): *"Idempotency isn't achieved by the API itself... it will blindly apply the same change over itself without determining if any change is necessary."* `check_mode` flag exists on the module but has no diff semantics behind it | MIT (per tarball `LICENSE` file — not deeply inspected) |
| 4 | **`aiounifi` (Python lib) as a backing library for a hand-written `mhl.unifi`** | Not Ansible — async Python client, used to *build* modules | Session API v2 (`/proxy/network/v2/api/site/{site}/...`) for `firewall_policies`/`firewall_zones`/`wlans`/`object_oriented_network_configs` (networks) — confirmed by reading `aiounifi/models/api.py` (`ApiRequestV2.full_path`) and `aiounifi/models/firewall_policy.py`, which has both a `FirewallPolicyListRequest` (GET) and `FirewallPolicyUpdateRequest` (PUT), i.e. genuine write support, not read-only | Very active — this is the library behind Home Assistant's UniFi integration; PyPI version `93` (calendar-style), released 2026-08-19; repo pushed as recently as today (2026-08-25) | Would have to be added — the library itself has no reconcile/diff logic, just typed request/response objects | MIT |
| 5 | **pyunifi / unificontrol** | Python libs | Legacy `/api/s/{site}/rest/...` only — predate the zone-based firewall, v2 API, and Integration API entirely | `unificontrol` (nickovs) **archived 2025-08-13**, read-only. `pyunifi` (finish06 fork) nominally alive but no evidence of covering firewall zones/policies, DNS policies, ACL, or traffic lists (features that didn't exist when these libs were written) | N/A — wrong API surface for our object types | Unverified |
| — | `buzz-tee/ansible-galaxy-unifi-collection` | Ansible collection | Legacy Session `rest/` endpoints (`networkconf`, `wlanconf`, `port`, `portconf`, `setting`) | **Dead** — last push 2022-12-23, predates zone-based firewall (2023+) entirely; no firewall/DNS/ACL/traffic-list modules at all | Unknown, moot | GPL-3.0 |
| — | `stratokumulus/unifi-firewall-config` | Ansible playbook (not a collection) | Legacy **ruleset-based** firewall (`rest/firewallrule`, `LAN_IN`/`LAN_OUT`/`WAN_IN`/`WAN_OUT`) — despite reading `X-API-KEY` off the env, its troubleshooting section hits `proxy/network/api/s/default/rest/firewallrule`, the pre-zone legacy rule table, not the Policy Engine our C5 assertion targets | Minimal — 1 star, 2 commits, last push 2025-11-01 | Author claims idempotent via delete-and-recreate of `ANSIBLE-`-prefixed rules | MIT |
| — | `erwanclx/UnifiAnsibleModule` | Single generic module | **Site Manager cloud API** (`api.ui.com/v1`), not the local controller Integration API — wrong surface for local network config | Minimal — 3 stars, last push 2025-06-06 | No (generic passthrough, `changed=False` always) | None declared |
| — | `ajanis/ansible-unifi`, `bsmeding/ansible_collection_unifi` | Ansible role / near-empty collection | N/A | Stale (2020-08 and 2025-01 respectively) / effectively unpopulated | N/A | N/A |
| — | Terraform (`paultyng/unifi`, `filipowm/unifi`, `badgerops/unifi`) | Not Ansible | Integration API | Already assessed and rejected in the parent doc §5 (`paultyng` archived 2026-04-30, others churning); consistent with this session's findings, not re-litigated | check_mode-equivalent via `terraform plan` | Mixed |

### Coverage table (object type × candidate)

| Object type | `hellqvio86.unifi` | unifly | `ubiquiti.unifi_api` | `aiounifi` (as a library) |
|---|---|---|---|---|
| Networks / VLANs | **No module** | `networks {list,get,create,update,delete,refs}` | Generic passthrough (any Integration path) | `object_oriented_network_configs` interface (read+write) |
| Firewall zones | `unifi_firewall_zone` (present, idempotent) | `firewall zones {list,get,create,update,delete}` | Generic passthrough | `firewall_zones` interface |
| Firewall policies + ordering | `unifi_firewall_policy` (present, idempotent, no ordering support seen) | `firewall policies {..., reorder --get/--set}` — **only tool surveyed with an ordering primitive** | Generic passthrough (no ordering primitive; would be hand-coded against whatever reorder endpoint exists) | `firewall_policies` interface (no ordering-specific request class seen) |
| DNS policies/records | **No module** | `dns {list,get,create,update,delete}` | Generic passthrough | No dedicated interface found in the tree |
| Traffic matching lists | **No module** | `traffic-lists {list,get,create,update,delete}` | Generic passthrough | `traffic_rules`/`traffic_routes` interfaces exist but are not a 1:1 match to "traffic matching lists" — not verified as the same object |
| ACL rules | **No module** | `acl {list,get,create,update,delete,reorder}` | Generic passthrough | No dedicated interface found |
| DHCP reservations (legacy only) | `unifi_dhcp_reservation` (present) | `clients set-ip` / `clients reservations` (session API) | Generic passthrough | No dedicated interface found (client/device interfaces might expose it; not verified) |
| WiFi | `unifi_wlan` (present, idempotent) | `wifi {list,get,create,update,delete}` | Generic passthrough | `wlans` interface (read+write) |

**Bottom line on the survey**: no single Ansible-native collection covers the
full object set. `hellqvio86.unifi` is the only one with genuine idempotent,
check_mode-aware, per-object modules, but it is alpha-status, Session-API-only
(no `X-API-KEY` path in its module_utils — grepped, zero hits), and is missing
exactly the objects the parent doc flagged as most valuable to declare:
networks/VLANs, DNS policies, ACL rules, traffic matching lists. This matches
and confirms the parent doc's §11 note: *"this session found none (only
installer roles and an inventory plugin)"* — this session's deeper pass found
one real (but partial, alpha) collection, one vendor-shipped non-idempotent
generic module, and one strong backing library (`aiounifi`), none of which
closes the gap alone.

### Citations (URL, last commit/release actually seen, license, API generation)

| Candidate | URL | Last commit/release seen (this session) | License | API generation |
|---|---|---|---|---|
| `hellqvio86.unifi` | [github.com/hellqvio86/ansible-collection-unifi](https://github.com/hellqvio86/ansible-collection-unifi) · [galaxy.ansible.com/.../hellqvio86/unifi](https://galaxy.ansible.com/ui/repo/published/hellqvio86/unifi/) | Pushed 2026-08-24T18:31:14Z, `galaxy.yml` version `0.0.26` | MIT (`galaxy.yml`) | Hand-written modules, not spec-generated; targets legacy Session API `v2` endpoints (`/proxy/network/v2/api/site/...`), no `X-API-KEY`/Integration path in `module_utils` |
| unifly (this project's tool) | [github.com/hyperb1iss/unifly](https://github.com/hyperb1iss/unifly) (per `~/.claude/skills/unifly/SKILL.md` install instructions) | Pushed 2026-08-07T07:13:03Z | Apache-2.0 | Hand-written Rust client; wraps Integration API v1 (`X-API-KEY`) as primary with Session API fallback, per `unifly --help` banner |
| Official `ubiquiti.unifi_api` | Tarball: [apidoc-cdn.ui.com/ansible-module/ubiquiti-unifi_api-latest.tar.gz](https://apidoc-cdn.ui.com/ansible-module/ubiquiti-unifi_api-latest.tar.gz), linked from [developer.ui.com/network/v9.1.120/quick_start.ansible](https://developer.ui.com/network/v9.1.120/quick_start.ansible) | Tarball internal timestamp 2026-01-23, `pyproject.toml`/`MANIFEST.json` version `1.0.0` (no public git repo found to date by commit) | MIT (tarball `LICENSE` file) | **Generated from the OpenAPI spec** — confirmed by reading `plugins/module_utils/openapi_runtime.py`/`base_module.py`: builds requests from `{base_url}/proxy/{app}/integration`, fetches the versioned spec itself at runtime. Non-idempotent: independently confirmed by [engyak.co, "Idempotently Manage Ubiquiti Unifi resources with Ansible," Apr 2026](https://blog.engyak.co/2026/04/ubnt-ansible/) — *"Idempotency isn't achieved by the API itself... it will blindly apply the same change over itself without determining if any change is necessary"* — and by this session's own reading of `base_module.py`, which has no GET-compare step |
| `aiounifi` | [github.com/Kane610/aiounifi](https://github.com/Kane610/aiounifi) · [pypi.org/project/aiounifi](https://pypi.org/project/aiounifi/) | Repo pushed 2026-08-25T06:22:35Z; PyPI version `93` released 2026-08-19T05:18:42 | MIT | Hand-written async Python client, not spec-generated; targets legacy Session API `v2` endpoints (`ApiRequestV2.full_path` → `/proxy/network/v2/api/site/{site}/...`), same surface as `hellqvio86.unifi`, not the documented Integration API v1 |
| `pyunifi` | [github.com/finish06/pyunifi](https://github.com/finish06/pyunifi) · [pypi.org/project/pyunifi](https://pypi.org/project/pyunifi/) | Repo pushed 2024-05-02T16:32:00Z; PyPI version `2.21` released 2021-04-18T20:51:15 | MIT | Hand-written, targets only the legacy `/api/s/{site}/rest/...` surface that predates the zone-based firewall, v2 API, and Integration API |
| `unificontrol` | [github.com/nickovs/unificontrol](https://github.com/nickovs/unificontrol) | **Archived 2025-08-13** (last push 2025-08-13T22:02:20Z) | Apache-2.0 | Hand-written, legacy REST surface only, same vintage as `pyunifi` |
| `buzz-tee/ansible-galaxy-unifi-collection` | [github.com/buzz-tee/ansible-galaxy-unifi-collection](https://github.com/buzz-tee/ansible-galaxy-unifi-collection) | Pushed 2022-12-23T11:38:00Z | GPL-3.0 | Hand-written Ansible collection (`networkconf`, `wlanconf`, `port`, `portconf`, `setting` modules) against legacy Session `rest/` endpoints — predates the zone-based firewall entirely |
| `erwanclx/UnifiAnsibleModule` | [github.com/erwanclx/UnifiAnsibleModule](https://github.com/erwanclx/UnifiAnsibleModule) | Pushed 2025-06-06T07:21:02Z | None declared (no `LICENSE` file, GitHub reports no license) | Hand-written, single generic module (`unifi_api.py`) against the **Site Manager cloud API** (`api.ui.com/v1`), not the local controller's Integration or Session API |
| `stratokumulus/unifi-firewall-config` | [github.com/stratokumulus/unifi-firewall-config](https://github.com/stratokumulus/unifi-firewall-config) | Pushed 2025-11-01T07:50:13Z | MIT | Hand-written playbook against the legacy **ruleset-based** firewall (`rest/firewallrule`, `LAN_IN`/`LAN_OUT`/`WAN_IN`/`WAN_OUT`), not the zone-based Policy Engine |
| `ajanis/ansible-unifi` | [github.com/ajanis/ansible-unifi](https://github.com/ajanis/ansible-unifi) | Pushed 2020-08-17T08:19:32Z | None declared | Hand-written role that deploys the UniFi controller container itself (plus Prometheus/Telegraf monitoring); does not touch network config at all |
| developer.ui.com OpenAPI spec | [developer.ui.com](https://developer.ui.com/) (per-controller: `https://<controller>/proxy/network/api-docs/integration.json`); community mirrors: [github.com/beezly/unifi-apis](https://github.com/beezly/unifi-apis), [github.com/opastorello/unifi-api-docs](https://github.com/opastorello/unifi-api-docs) | Official spec has no single repo/release date (versioned per Network application version, e.g. `v9.1.120`, not per commit); `beezly/unifi-apis` mirror pushed 2026-08-20T05:00:18Z; `opastorello/unifi-api-docs` mirror pushed 2026-08-25T06:53:38Z (CI-refreshed daily per its own description) | Official spec's license not inspected this session; `beezly/unifi-apis` and `opastorello/unifi-api-docs` mirrors declare no license on GitHub | This **is** the spec, not a client. Two downstream consumers seen this session: the official `ubiquiti.unifi_api` module (row above, generated from it) and [github.com/ubiquiti-community/unifi-api](https://github.com/ubiquiti-community/unifi-api) (pushed 2026-08-24T10:22:26Z, MPL-2.0), which codegens a **Terraform** provider from it via `tfplugingen-framework`, not an Ansible artifact |

---

## 2. Recommendation

**Build `mhl.unifi` as a thin Ansible collection whose modules shell out to
the already-deployed `unifly` CLI**, rather than adopting `hellqvio86.unifi` as
a dependency or hand-rolling a new HTTP client (via `aiounifi` or raw
`requests`).

Reasoning:

1. **Reuse beats a second client.** `unifly` is already the project's chosen
   interface to this controller (skill installed, auth modes configured,
   Integration API v1 primary with Session fallback already wired). Standing
   up `aiounifi` or a hand-written client means a second credential path, a
   second auth-mode decision, and a second place for the Integration-vs-Session
   API split to go stale — directly against the project's
   `feedback_reuse_existing_systems.md` rule.
2. **`unifly` already covers every object type in scope**, including the two
   nothing else in the survey has: DNS policies and ACL rules/traffic lists.
   `hellqvio86.unifi` cannot reach those without upstream contribution; the
   vendor module and `aiounifi` can reach them only as raw/generic calls with
   no typing.
3. **The idempotency gap is the same size no matter which foundation is
   chosen.** Every candidate except `hellqvio86.unifi`'s narrow object set
   needs a hand-built GET→compare→PUT loop — confirmed independently for the
   vendor module (engyak.co) and by inspection for `unifly` (`--from-file` has
   create/update but no create-or-update) and for raw `aiounifi` (typed
   requests, no diff logic). So building that reconcile loop is unavoidable
   work regardless; the only question is what it sits on top of, and `unifly`
   is the option that avoids adding a second API client.
4. **`hellqvio86.unifi` should be watched, not adopted**, for two reasons
   beyond the coverage gap: it explicitly warns of breaking changes
   pre-1.0, and its Session-only auth (no API key) doesn't match this
   project's Integration API v1 / `X-API-KEY` primary path, so adopting it
   would reopen the secrets-and-auth-mode question R-A is meant to close once,
   not per-tool.

### Proposed module set and effort

A thin `mhl.unifi` collection, one module per object type, each following the
same shape: GET the current list from `unifly <cmd> list -o json --all`,
match the desired item by `name`, then either no-op, `unifly <cmd> update
<id> --from-file`, or `unifly <cmd> create --from-file`. `changed_when` (or,
for a real `AnsibleModule`, the `changed` return value) is computed from the
pre-GET diff, not from the exit code of the write call.

| Module | Backing unifly command | Notes |
|---|---|---|
| `mhl_unifi_network` | `networks {list,create,update,delete}` | VLANs |
| `mhl_unifi_firewall_zone` | `firewall zones {list,create,update,delete}` | |
| `mhl_unifi_firewall_policy` | `firewall policies {list,create,update,delete}` | |
| `mhl_unifi_firewall_order` | `firewall policies reorder --get/--set` | Separate module — ordering is a distinct idempotency problem (a set, not a record) from the policies themselves |
| `mhl_unifi_dns_record` | `dns {list,create,update,delete}` | |
| `mhl_unifi_traffic_list` | `traffic-lists {list,create,update,delete}` | |
| `mhl_unifi_acl_rule` | `acl {list,create,update,delete,reorder}` | Same ordering split as firewall policies applies here too |
| `mhl_unifi_dhcp_reservation` | `clients set-ip` / `clients reservations` | Legacy Session API only, per parent doc |
| `mhl_unifi_wifi` | `wifi {list,create,update,delete}` | |

Effort estimate: 8 object modules + 1 shared `module_utils` helper
(subprocess wrapper around `unifly`, JSON parse, name-match, diff) is roughly
**2–3 focused days** — most of the code is the same 40-line reconcile
skeleton repeated per object type; the actual bespoke logic per module is just
the create/update payload shape. A minimal viable slice for Phase 5 would be
just `mhl_unifi_firewall_zone` + `mhl_unifi_firewall_policy` +
`mhl_unifi_firewall_order` (enough to codify C5) at roughly **half a day**.

### The `--from-file` + `list -o json` + `command`-task alternative

The task also asked to assess driving `unifly` directly from Ansible
`command` tasks (no custom module at all): `list -o json` into a `register`,
Jinja logic in a `set_fact` to decide desired vs. actual, then a conditional
`command` running `create --from-file` or `update <id> --from-file`, with
`changed_when` set from the pre-GET comparison. This works and needs no
Python module code, but:

- The reconcile logic ends up as repeated Jinja/`when:` boilerplate in every
  playbook that touches UniFi, instead of being centralized once per object
  type in a module.
- `--from-file` payloads become raw JSON files rendered by `template`, losing
  Ansible's native YAML-in-`hosts.yml` ergonomics that the rest of the project
  uses (the project's whole `service:` generator pattern is "write it once in
  `hosts.yml`, let a role turn it into config").
- It is a reasonable **bridge**: usable immediately, with zero new code,
  while the `mhl.unifi` modules are written — and the `mhl.unifi` module_utils
  layer is exactly this same `command`-wrapping logic, just centralized.

Recommendation: use the `command`-task pattern as the Phase 5 bring-up
mechanism for the very first object (C5's zones/policies), then fold the
proven logic into `mhl_unifi_firewall_zone`/`_policy`/`_order` modules rather
than letting the `command`-task pattern spread to every object type.

---

## 3. C5 assertion — read-only calls and assert logic

C5 (§9 Q8): **no firewall policy allows TCP 2376 from a non-MGMT zone to the
DMZ zone.**

This was not run against the live controller this session (task restricted
live contact to `--help`); the calls below are what the `governance` role
(§6, Phase 3) should run, and the field names come from `aiounifi`'s
`FirewallPolicy`/`FirewallPolicyEndpoint` model — **flagged unverified against
this controller's actual JSON** (see §5).

### Read-only calls

```bash
# 1. Resolve zone name -> id (need the DMZ id and every non-MGMT zone id)
unifly firewall zones list -o json --all \
  -c "{{ unifi_controller_url }}" -s "{{ unifi_site }}" --api-key "{{ unifi_api_key }}"

# 2. Fetch every firewall policy
unifly firewall policies list -o json --all \
  -c "{{ unifi_controller_url }}" -s "{{ unifi_site }}" --api-key "{{ unifi_api_key }}"
```

Raw-HTTP equivalents (Integration API v1, if bypassing unifly):

```
GET https://<controller>/proxy/network/integration/v1/firewall-zones
GET https://<controller>/proxy/network/integration/v1/firewall-policies
Header: X-API-KEY: <key>
```

### Assert logic (Ansible)

```yaml
- name: "governance C5 — resolve firewall zone ids"
  ansible.builtin.command:
    cmd: >
      unifly firewall zones list -o json --all
      -c "{{ unifi_controller_url }}" -s "{{ unifi_site }}"
      --api-key "{{ unifi_api_key }}"
  register: "unifi_zones_raw"
  changed_when: false
  check_mode: false

- name: "governance C5 — build zone name -> id map"
  ansible.builtin.set_fact:
    unifi_zone_id_by_name: "{{ dict(_zones | map(attribute='name') | zip(_zones | map(attribute='_id'))) }}"
  vars:
    _zones: "{{ unifi_zones_raw.stdout | from_json }}"

- name: "governance C5 — fetch all firewall policies"
  ansible.builtin.command:
    cmd: >
      unifly firewall policies list -o json --all
      -c "{{ unifi_controller_url }}" -s "{{ unifi_site }}"
      --api-key "{{ unifi_api_key }}"
  register: "unifi_policies_raw"
  changed_when: false
  check_mode: false

- name: "governance C5 — no policy allows TCP/2376 from non-MGMT to DMZ"
  ansible.builtin.assert:
    that:
      - >-
        (unifi_policies_raw.stdout | from_json
          | selectattr('enabled', 'equalto', true)
          | selectattr('action', 'equalto', 'ALLOW')
          | selectattr('destination.zone_id', 'equalto', unifi_zone_id_by_name["DMZ"])
          | rejectattr('source.zone_id', 'equalto', unifi_zone_id_by_name["MGMT"])
          | selectattr('protocol', 'in', ['tcp', 'tcp_udp', 'all'])
          | selectattr('destination.port', 'defined')
          | selectattr('destination.port', 'search', '(^|,)2376($|-|,)')
          | list | length) == 0
    fail_msg: >-
      Governance C5 violated: at least one enabled ALLOW firewall policy
      permits TCP/2376 from a non-MGMT zone to the DMZ zone.
    success_msg: "C5 holds: no non-MGMT -> DMZ policy allows TCP/2376."
```

`changed_when: false` on both `list` calls makes this assertion pure read;
nothing here mutates the controller. This should live in the `governance`
role per §6.2/§9 Q8, one `assert` block per decision-record entry, run every
`site.yml` pass (or on its own `/drift`-style invocation) rather than only at
provisioning time, since a firewall policy can drift outside of MHL.

**Caveat**: the exact JSON field for the destination port
(`destination.port` above) is inferred from `aiounifi`'s `FirewallPolicyEndpoint`
TypedDict, which did **not** show a `port` key in the slice this session read
(it showed `match_opposite_ports`, `matching_target`, `port_matching_type`,
`zone_id`, `client_macs` — the actual port value's field name/format was
truncated out of what was fetched). **Before shipping this assertion, run
`unifly firewall policies get <id> -o json` on one real 2376-adjacent policy
and adjust `destination.port` to the confirmed field name** — this is exactly
the kind of live-system check normally required, deferred here only because
the task scoped this session to `--help`-only controller contact.

---

## 4. Proposed `hosts.yml` schema fragment (name-keyed)

Follows the project's existing conventions read from
`McHomeLab-Inventory/hosts.yml`: double-quoted string values, named vars in
`all.vars` (not inline computation), and the existing `provider: unifi` tag
already used on VM network entries (e.g. `MGMT-V`) to mark a vNIC as living on
a UniFi-managed VLAN.

```yaml
all:
  vars:
    # --- UniFi controller (R-C) ---
    unifi_controller_url: "https://10.1.84.1"
    unifi_site: "default"
    unifi_api_key: "{{ vault_unifi_api_key }}"      # R-A decides custody

  hosts:
    unifi:
      # ... existing provision/software/services sections (Phase 3) ...

      # Name-keyed UniFi Network objects — reconciled by mhl.unifi modules
      # (GET list -> match by "name" -> create/update). Each list entry's
      # "name" is the reconcile key; nothing here is positional.
      unifi_networks:
        - name: "Media"
          vlan_id: 20
          management: "gateway"        # gateway | switch | unmanaged
          subnet: "10.1.20.0/24"
          gateway_ip: "10.1.20.1"
          dhcp_enabled: true
          purpose: "corporate"

      unifi_firewall_zones:
        - name: "DMZ"
          networks: ["Media"]
        - name: "MGMT"
          networks: ["MGMT-V"]

      unifi_firewall_policies:
        - name: "ANSIBLE-Deny-NonMGMT-Docker-to-DMZ"
          action: "BLOCK"
          enabled: true
          index: 19000
          protocol: "tcp"
          logging: true
          source:
            zone: "Internal"
          destination:
            zone: "DMZ"
            port: "2376"

      unifi_dns_records:
        - name: "unifi.michaelpmcd.com"
          record_type: "A"
          value: "10.1.84.1"
          enabled: true

      unifi_traffic_lists:
        - name: "streaming-domains"
          list_type: "DOMAIN"
          members:
            - "netflix.com"
            - "hulu.com"

      unifi_acl_rules: []

      unifi_dhcp_reservations:
        - name: "media-server"
          mac: "aa:bb:cc:dd:ee:ff"
          ip: "10.1.20.30"
          network: "Media"

      unifi_wifi:
        - name: "HomeWiFi"
          network: "Default"
          passphrase: "{{ vault_home_wifi_passphrase }}"
          enabled: true
          band_steering: true
```

Notes on the fragment:

- `unifi_api_key` and any WiFi passphrase are placeholders pointing at vault
  variables — actual custody is R-A's call, not decided here.
- `unifi_firewall_policies[].source`/`destination` use zone **names**, not
  ids — the `mhl_unifi_firewall_policy` module is responsible for resolving
  name → id via the same zone list call shown in §3, keeping `hosts.yml`
  free of UniFi-internal UUIDs (consistent with the project's "no hardcoded
  cross-host IDs, go through a lookup" convention used for the registry).
- `unifi_firewall_policies` ordering in this list is **not** assumed to be
  the enforced order — actual ordering is a separate reconcile
  (`mhl_unifi_firewall_order`, §2) against `firewall policies reorder`,
  matching the coverage-table note that ordering is its own idempotency
  problem.

---

## 5. Unverified

- `destination.port` field name/format for a firewall policy under the
  Integration API v1 — inferred from a partial read of `aiounifi`'s
  `FirewallPolicyEndpoint` TypedDict, not confirmed against a live GET on
  10.1.84 (task scoped this session to `--help`-only controller contact).
  **Must be confirmed with `unifly firewall policies get <id> -o json`
  before the C5 assert ships.**
- Whether the Integration API v1 on **this specific controller** actually
  serves `firewall-zones`/`firewall-policies`/DNS/traffic-lists/ACL at
  `/proxy/network/integration/v1/...` as opposed to only via the v2 Session
  API — this session relied on the parent research doc's §5 claim (verified
  there on 2026-08-24) rather than re-querying live.
- `hellqvio86.unifi`'s exhaustive module list was read from its GitHub tree
  and `meta/runtime.yml` action group (18 modules); each module's full
  argument spec was not read individually except `unifi_firewall_policy.py` —
  it's possible another module (e.g. `unifi_info`) can gather network/DNS/ACL
  facts even though no dedicated create/update module exists for them; not
  checked.
- `aiounifi`'s `object_oriented_network_configs.py` (networks/VLANs) and
  `traffic_rules.py`/`traffic_routes.py` were seen only in the file tree
  listing, not opened — their write-support and exact object-type match to
  "traffic matching lists" is inferred, not confirmed the way
  `firewall_policy.py` was.
- `unifly`'s own license was not checked this session.
- The official `ubiquiti.unifi_api` tarball's `README.md` only pointed back
  to `developer.ui.com`; the developer.ui.com Ansible quick-start page itself
  is a client-rendered SPA that neither `WebFetch` nor a plain `curl` could
  extract prose from — only the download URL and module structure (verified
  by actually downloading and extracting the tarball) are confirmed; any
  additional written guidance on that page (dependency list, more examples)
  was not read.
- DHCP-reservation coverage in `aiounifi` — no dedicated interface file was
  found in the tree listing, but client/device interfaces were not opened to
  rule out reservation support living there instead.
- Whether `hellqvio86.unifi`'s Session-API auth could be pointed at this
  controller's existing session credentials without conflicting with the
  Integration API key already in use — not tested (would require live
  contact beyond `--help`).
