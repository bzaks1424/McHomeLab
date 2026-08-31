#!/usr/bin/python
# -*- coding: utf-8 -*-
"""Ansible module: reconcile ONE UniFi Network NAT rule by description, via the raw API.

Why raw and not `unifly nat policies`: unifly v0.10.0 does not deserialise
`destination_filter.invert_address` on read and hardcodes it `false` on create
(crates/unifly-api/src/controller/commands/policy/nat.rs:235,243). The six per-VLAN DNS
hijack rules on this network depend on that inversion -- they redirect port 53 headed
ANYWHERE EXCEPT the VLAN gateway TO that gateway. Reading one through the typed
subcommand and writing it back would not merely lose the inversion, it would write its
opposite: a rule matching only DNS already bound for the gateway, i.e. nothing. NextDNS
enforcement would end estate-wide while the rule still showed green in the UI. So this
module round-trips raw JSON through `unifly api`, which preserves it.

Upsert semantics mirror mhl_unifi_firewall_policy: absent -> create; present -> converge
the compared fields with a PUT of the full object. Rules are matched on (description,
in_interface) among non-predefined rules; descriptions are not unique on a controller.
Networks are named in the inventory, never id'd. Check mode reports what would happen.
"""
from __future__ import absolute_import, division, print_function

__metaclass__ = type

DOCUMENTATION = r"""
---
module: mhl_unifi_nat_rule
short_description: Reconcile a UniFi Network NAT rule (by description) through the raw API
options:
  description: {type: str, required: true, description: Matches on (description, in_interface)}
  in_interface: {type: str, required: true, description: Network NAME, resolved to an id}
  type: {type: str, default: DNAT, choices: [DNAT, SNAT, MASQUERADE]}
  protocol: {type: str, default: tcp_udp}
  ip_address: {type: str, description: Translation target address}
  port: {type: str, description: Translation target port}
  destination_filter: {type: dict, description: filter_type/address/port/invert_address/invert_port}
  source_filter: {type: dict}
  enabled: {type: bool, default: true}
  logging: {type: bool, default: false}
  exclude: {type: bool, default: false}
  ip_version: {type: str, default: IPV4}
  unifly_bin: {type: path, default: unifly}
  site: {type: str, default: default}
  state: {type: str, default: present, choices: [present, absent]}
"""

EXAMPLES = r"""
- mhl_unifi_nat_rule:
    description: "DNAT IoT *:53|GW"
    in_interface: "IoT"
    type: "DNAT"
    protocol: "tcp_udp"
    ip_address: "192.168.3.1"
    destination_filter:
      filter_type: "ADDRESS_AND_PORT"
      address: "192.168.3.1"
      port: "53"
      invert_address: true
"""

RETURN = r"""
state: {description: "absent -> create | update | in sync | present -> delete", type: str}
diff_keys: {description: compared fields that differ, type: list}
"""

from ansible.module_utils.basic import AnsibleModule  # noqa: E402
from ansible.module_utils.mhl_unifly import (  # noqa: E402
    AmbiguousMatch, Unifly, UniflyError, api_get, api_write, diff_keys,
    find_nat_rule, nat_filter_shape, nat_rule_shape, network_map,
)

NAT_PATH = "v2/api/site/%s/nat"
# NAT rules reference networks by their LEGACY Mongo ObjectId (in_interface), which is a
# different id space from the UUIDs `unifly networks list` returns via the Integration
# API. Resolving names against the wrong space silently matches nothing, so names come
# from the session endpoint that shares the NAT rules' id space.
NETWORK_PATH = "api/s/%s/rest/networkconf"


def desired_shape(params, netmap):
    return {
        "type": params["type"].upper(),
        "enabled": bool(params["enabled"]),
        "protocol": params["protocol"],
        "ip_address": params.get("ip_address"),
        "port": str(params["port"]) if params.get("port") not in (None, "") else None,
        "logging": bool(params["logging"]),
        "exclude": bool(params["exclude"]),
        "ip_version": params["ip_version"],
        "destination_filter": nat_filter_shape(params.get("destination_filter")),
        "source_filter": nat_filter_shape(params.get("source_filter")),
    }


def plan(params, networks, rules):
    """Pure decision logic (unit-tested): dict(state, diff, desired, current, id, error)."""
    netmap = network_map(networks)
    if params["in_interface"] not in netmap:
        return {"error": "unknown network %r (known: %s)"
                         % (params["in_interface"], sorted(netmap))}
    iface = netmap[params["in_interface"]]
    try:
        current_raw = find_nat_rule(rules, params["description"], iface)
    except AmbiguousMatch as e:
        return {"error": str(e)}

    if params.get("state", "present") == "absent":
        if current_raw is None:
            return {"state": "in sync", "diff": [], "current": None}
        return {"state": "present -> delete", "diff": ["state"],
                "current": nat_rule_shape(current_raw), "id": current_raw.get("_id")}

    desired = desired_shape(params, netmap)
    if current_raw is None:
        return {"state": "absent -> create", "diff": sorted(desired),
                "desired": desired, "current": None, "iface": iface}
    current = nat_rule_shape(current_raw)
    diff = diff_keys(desired, current)
    if not diff:
        return {"state": "in sync", "diff": [], "desired": desired,
                "current": current, "id": current_raw.get("_id"), "iface": iface}
    return {"state": "update", "diff": diff, "desired": desired, "current": current,
            "id": current_raw.get("_id"), "iface": iface, "raw": current_raw}


def payload(params, p):
    """Full object for create/update. UniFi's v2 NAT endpoint replaces the whole rule,
    so an update sends the live object with the compared fields overwritten -- fields
    this module does not manage (rule_index, setting_preference, …) are carried over
    rather than silently reset to defaults."""
    body = dict(p.get("raw") or {})
    body.pop("_id", None)
    d = p["desired"]
    body.update({
        "description": params["description"],
        "in_interface": p["iface"],
        "type": d["type"],
        "enabled": d["enabled"],
        "protocol": d["protocol"],
        "logging": d["logging"],
        "exclude": d["exclude"],
        "ip_version": d["ip_version"],
    })
    if d["ip_address"] is not None:
        body["ip_address"] = d["ip_address"]
    if d["port"] is not None:
        body["port"] = d["port"]
    for side in ("destination_filter", "source_filter"):
        f = dict(body.get(side) or {})
        s = d[side]
        f["filter_type"] = s["filter_type"]
        f["invert_address"] = s["invert_address"]
        f["invert_port"] = s["invert_port"]
        f.setdefault("firewall_group_ids", [])
        # absent address stays absent: the DMZ hijack rule inverts against nothing
        if s["address"] is None:
            f.pop("address", None)
        else:
            f["address"] = s["address"]
        if s["port"] is None:
            f.pop("port", None)
        else:
            f["port"] = s["port"]
        body[side] = f
    return body


def main():
    module = AnsibleModule(
        argument_spec=dict(
            description=dict(type="str", required=True),
            in_interface=dict(type="str", required=True),
            type=dict(type="str", default="DNAT", choices=["DNAT", "SNAT", "MASQUERADE"]),
            protocol=dict(type="str", default="tcp_udp"),
            ip_address=dict(type="str"),
            port=dict(type="str"),
            destination_filter=dict(type="dict"),
            source_filter=dict(type="dict"),
            enabled=dict(type="bool", default=True),
            logging=dict(type="bool", default=False),
            exclude=dict(type="bool", default=False),
            ip_version=dict(type="str", default="IPV4"),
            unifly_bin=dict(type="path", default="unifly"),
            site=dict(type="str", default="default"),
            state=dict(type="str", default="present", choices=["present", "absent"]),
        ),
        supports_check_mode=True,
    )
    u = Unifly(module.params["unifly_bin"])
    path = NAT_PATH % module.params["site"]
    try:
        networks = api_get(u, NETWORK_PATH % module.params["site"])
        rules = api_get(u, path)
    except UniflyError as e:
        module.fail_json(msg=str(e))

    p = plan(module.params, networks, rules)
    if "error" in p:
        module.fail_json(msg=p["error"], diff_keys=p.get("diff", []))

    result = dict(changed=p["state"] != "in sync", state=p["state"],
                  diff_keys=p["diff"], description=module.params["description"])
    if result["changed"] and not module.check_mode:
        try:
            if p["state"] == "present -> delete":
                api_write(u, "delete", "%s/%s" % (path, p["id"]), {})
            elif p["state"] == "absent -> create":
                api_write(u, "post", path, payload(module.params, p))
            else:
                api_write(u, "put", "%s/%s" % (path, p["id"]), payload(module.params, p))
        except (UniflyError, ValueError) as e:
            module.fail_json(msg=str(e), **result)
    module.exit_json(**result)


if __name__ == "__main__":
    main()
