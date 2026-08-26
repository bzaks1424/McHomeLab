#!/usr/bin/python
# -*- coding: utf-8 -*-
"""Ansible module: reconcile ONE UniFi Network firewall policy by name via unifly.

Upsert semantics (Phase 5 decision): absent -> create; present -> converge the
compared fields. unifly `update` can only change the destination ports; a drift
in action / zones / enabled / logging fails loudly rather than deleting and
recreating behind the operator's back. Check mode reports what would happen.
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
    UPDATE_ONLY, Unifly, UniflyError, by_name, create_args, diff_keys, policy_shape, update_args, zone_map,
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
        "destination_ports": sorted(str(p) for p in (params["destination_ports"] or [])),
        "logging": bool(params["logging"]),
    }
    current_raw = by_name(policies, params["name"])
    if current_raw is None:
        return {"state": "absent -> create", "diff": list(desired), "desired": desired, "current": None}
    current = policy_shape(current_raw)
    diff = diff_keys(desired, current)
    if not diff:
        return {"state": "in sync", "diff": [], "desired": desired, "current": current, "id": current_raw.get("id")}
    blocked = [k for k in diff if k not in UPDATE_ONLY]
    if blocked:
        return {"error": "policy %r differs in %s, which unifly update cannot change; delete it in the "
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
        try:
            if p["state"] == "absent -> create":
                u.call("firewall", "policies", "create", *create_args(module.params["name"], p["desired"], module.params["description"]))
            else:
                u.call("firewall", "policies", "update", p["id"], *update_args(p["desired"]))
        except UniflyError as e:
            module.fail_json(msg=str(e), **result)
    module.exit_json(**result)


if __name__ == "__main__":
    main()
