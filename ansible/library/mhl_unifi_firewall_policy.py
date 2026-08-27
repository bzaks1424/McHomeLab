#!/usr/bin/python
# -*- coding: utf-8 -*-
"""Ansible module: reconcile ONE UniFi Network firewall policy by name via unifly.

Upsert semantics (Phase 5 decision): absent -> create; present -> converge the
compared fields. In place, unifly can change the destination ports (`update`) and
toggle enabled/logging (`patch`); a drift in action, zones or filter kind fails
loudly rather than deleting and recreating behind the operator's back. Policies
are matched on (name, source zone, destination zone) among user-defined rules —
names alone are not unique on a controller. Description and index are set at
create time only and never compared. Check mode reports what would happen.
Zones are given by NAME; ids never appear in the inventory."""
from __future__ import absolute_import, division, print_function

__metaclass__ = type

DOCUMENTATION = r"""
---
module: mhl_unifi_firewall_policy
short_description: Reconcile a UniFi Network firewall policy (by name) through the unifly CLI
options:
  name: {type: str, required: true}
  action: {type: str, required: true, choices: [allow, block, reject]}
  source_zone: {type: str, required: true, description: Zone NAME}
  destination_zone: {type: str, required: true, description: Zone NAME}
  destination_ports: {type: list, elements: str, default: []}
  enabled: {type: bool, default: true}
  logging: {type: bool, default: false}
  description: {type: str, default: "managed by McHomeLab"}
  unifly_bin: {type: path, default: unifly}
  state: {type: str, default: present, choices: [present, absent], description: absent deletes the matched user-defined policy}
"""

EXAMPLES = r"""
- mhl_unifi_firewall_policy:
    name: "ANSIBLE-Block-Internal-Docker-to-DMZ"
    action: "block"
    source_zone: "Internal"
    destination_zone: "Dmz"
    destination_ports: ["2376"]
    logging: true
"""

RETURN = r"""
state: {description: "absent -> create | update | in sync", type: str}
diff_keys: {description: compared fields that differ, type: list}
"""

from ansible.module_utils.basic import AnsibleModule  # noqa: E402
from ansible.module_utils.mhl_unifly import (  # noqa: E402
    PATCHABLE, UPDATE_ONLY, AmbiguousMatch, Unifly, UniflyError, create_args, diff_keys, find_policy,
    patch_args, policy_shape, update_args, zone_map,
)


def plan(params, zones, policies):
    """Pure decision logic (unit-tested): returns dict(state, diff, desired, current, error)."""
    zmap = zone_map(zones)
    for z in ("source_zone", "destination_zone"):
        if params[z] not in zmap:
            return {"error": "unknown zone %r (known: %s)" % (params[z], sorted(zmap))}
    desired = {
        "action": params["action"].lower(),
        "enabled": bool(params["enabled"]),
        "source_zone_id": zmap[params["source_zone"]],
        "destination_zone_id": zmap[params["destination_zone"]],
        "destination_filter_kind": "port" if params["destination_ports"] else "",
        "destination_ports": sorted(str(p) for p in (params["destination_ports"] or [])),
        "logging": bool(params["logging"]),
    }
    try:
        current_raw = find_policy(policies, params["name"], desired["source_zone_id"], desired["destination_zone_id"])
    except AmbiguousMatch as e:
        return {"error": str(e)}
    if params.get("state", "present") == "absent":
        if current_raw is None:
            return {"state": "in sync", "diff": [], "desired": desired, "current": None}
        return {"state": "present -> delete", "diff": ["state"], "desired": desired, "current": policy_shape(current_raw), "id": current_raw.get("id")}
    if current_raw is None:
        return {"state": "absent -> create", "diff": list(desired), "desired": desired, "current": None}
    current = policy_shape(current_raw)
    diff = diff_keys(desired, current)
    if not diff:
        return {"state": "in sync", "diff": [], "desired": desired, "current": current, "id": current_raw.get("id")}
    blocked = [k for k in diff if k not in UPDATE_ONLY + PATCHABLE]
    if "destination_ports" in diff and not desired["destination_ports"]:
        blocked.append("destination_ports (clearing the port filter has no unifly flag)")
    if blocked:
        return {"error": "policy %r differs in %s, which unifly cannot change in place; delete it in the "
                         "controller (or rename the declaration) and re-apply — not done automatically"
                         % (params["name"], ", ".join(blocked)), "diff": diff}
    return {"state": "update", "diff": diff, "desired": desired, "current": current, "id": current_raw.get("id")}


def main():
    module = AnsibleModule(
        argument_spec=dict(
            name=dict(type="str", required=True),
            action=dict(type="str", required=True, choices=["allow", "block", "reject"]),
            source_zone=dict(type="str", required=True),
            destination_zone=dict(type="str", required=True),
            destination_ports=dict(type="list", elements="str", default=[]),
            enabled=dict(type="bool", default=True),
            logging=dict(type="bool", default=False),
            description=dict(type="str", default="managed by McHomeLab"),
            unifly_bin=dict(type="path", default="unifly"),
            state=dict(type="str", default="present", choices=["present", "absent"]),
        ),
        supports_check_mode=True,
    )
    u = Unifly(module.params["unifly_bin"])
    try:
        zones = u.list_json("firewall", "zones", "list")
        policies = u.list_json("firewall", "policies", "list")
    except UniflyError as e:
        module.fail_json(msg=str(e))
    p = plan(module.params, zones, policies)
    if "error" in p:
        module.fail_json(msg=p["error"], diff_keys=p.get("diff", []))
    result = dict(changed=p["state"] != "in sync", state=p["state"], diff_keys=p["diff"], name=module.params["name"])
    if result["changed"] and not module.check_mode:
        mutated = False
        try:
            if p["state"] == "absent -> create":
                u.write("firewall", "policies", "create", *create_args(module.params["name"], p["desired"], module.params["description"]))
                mutated = True
            elif p["state"] == "present -> delete":
                u.write("firewall", "policies", "delete", p["id"])
                mutated = True
            else:
                if "destination_ports" in p["diff"]:
                    u.write("firewall", "policies", "update", p["id"], *update_args(p["desired"]))
                    mutated = True
                patch = [k for k in p["diff"] if k in PATCHABLE]
                if patch:
                    u.write("firewall", "policies", "patch", p["id"], *patch_args(p["desired"], patch))
                    mutated = True
        except (UniflyError, ValueError) as e:
            # `changed` must say whether the controller was touched, not whether we finished.
            result["changed"] = mutated
            module.fail_json(msg=("%s (controller partially updated)" % e) if mutated else str(e), **result)
    module.exit_json(**result)


if __name__ == "__main__":
    main()
