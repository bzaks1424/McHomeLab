"""mhl_unifi_nat_rule: pure plan()/payload() logic, no Ansible runtime, no controller."""
import importlib.util
import pathlib
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def _load():
    """Load the module with a stubbed ansible.module_utils.basic so it imports offline,
    and with module_utils/ on the path so the real mhl_unifly helpers are exercised."""
    sys.path.insert(0, str(ROOT / "ansible" / "module_utils"))
    import types
    pkg = types.ModuleType("ansible"); pkg.__path__ = []
    mu = types.ModuleType("ansible.module_utils"); mu.__path__ = []
    basic = types.ModuleType("ansible.module_utils.basic")
    basic.AnsibleModule = object
    real = importlib.import_module("mhl_unifly")
    sys.modules.setdefault("ansible", pkg)
    sys.modules.setdefault("ansible.module_utils", mu)
    sys.modules["ansible.module_utils.basic"] = basic
    sys.modules["ansible.module_utils.mhl_unifly"] = real
    spec = importlib.util.spec_from_file_location(
        "mhl_unifi_nat_rule", ROOT / "ansible" / "library" / "mhl_unifi_nat_rule.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


mod = _load()

# Legacy Mongo ObjectIds, the id space NAT rules actually reference -- NOT the UUIDs
# that `unifly networks list` returns from the Integration API. Resolving against the
# wrong space matches nothing, which cost a live debugging round.
NETWORKS = [{"name": "IoT", "_id": "5f78b3d4b585e71b86d8fca0"},
            {"name": "Dmz", "_id": "6761cbadacbb3e2b114dc486"}]


def hijack(desc="DNAT IoT *:53|GW", iface="5f78b3d4b585e71b86d8fca0", address="192.168.3.1", _id="r1"):
    """A live per-VLAN DNS hijack rule as the controller actually returns it."""
    df = {"filter_type": "ADDRESS_AND_PORT", "firewall_group_ids": [],
          "invert_address": True, "invert_port": False, "port": "53"}
    if address is not None:
        df["address"] = address
    return {"_id": _id, "description": desc, "in_interface": iface, "type": "DNAT",
            "enabled": True, "protocol": "tcp_udp", "ip_address": "192.168.3.1",
            "ip_version": "IPV4", "logging": False, "exclude": False,
            "is_predefined": False, "rule_index": 0, "setting_preference": "manual",
            "destination_filter": df,
            "source_filter": {"filter_type": "NONE", "firewall_group_ids": [],
                              "invert_address": False, "invert_port": False}}


def params(**over):
    p = {"description": "DNAT IoT *:53|GW", "in_interface": "IoT", "type": "DNAT",
         "protocol": "tcp_udp", "ip_address": "192.168.3.1", "port": None,
         "destination_filter": {"filter_type": "ADDRESS_AND_PORT",
                                "address": "192.168.3.1", "port": "53",
                                "invert_address": True},
         "source_filter": {"filter_type": "NONE"}, "enabled": True, "logging": False,
         "exclude": False, "ip_version": "IPV4", "state": "present"}
    p.update(over)
    return p


def test_declared_hijack_rule_is_in_sync_with_the_live_one():
    p = mod.plan(params(), NETWORKS, [hijack()])
    assert p["state"] == "in sync", p.get("diff")


def test_inversion_is_a_compared_field_so_losing_it_is_drift():
    """The whole reason this module exists. unifly's typed NAT model drops
    invert_address on read and writes false on create; if that ever leaks in, the
    comparison must call it drift rather than 'in sync'."""
    live = hijack()
    live["destination_filter"]["invert_address"] = False
    p = mod.plan(params(), NETWORKS, [live])
    assert p["state"] == "update"
    assert "destination_filter" in p["diff"]


def test_absent_address_is_preserved_not_defaulted():
    """The DMZ hijack rule inverts against no address at all and works. Absent and
    empty must stay distinguishable, or reconciling it would rewrite the rule."""
    live = hijack(desc="DNAT DMZ *:53|GW", iface="6761cbadacbb3e2b114dc486", address=None, _id="r2")
    pr = params(description="DNAT DMZ *:53|GW", in_interface="Dmz",
                destination_filter={"filter_type": "ADDRESS_AND_PORT", "port": "53",
                                    "invert_address": True})
    p = mod.plan(pr, NETWORKS, [live])
    assert p["state"] == "in sync", p.get("diff")
    body = mod.payload(pr, dict(p, raw=live, iface="6761cbadacbb3e2b114dc486"))
    assert "address" not in body["destination_filter"]
    assert body["destination_filter"]["invert_address"] is True


def test_create_when_absent():
    p = mod.plan(params(), NETWORKS, [])
    assert p["state"] == "absent -> create"


def test_unknown_network_is_an_error_not_a_guess():
    p = mod.plan(params(in_interface="Nope"), NETWORKS, [])
    assert "error" in p and "unknown network" in p["error"]


def test_duplicate_descriptions_on_one_interface_are_an_error():
    p = mod.plan(params(), NETWORKS, [hijack(_id="a"), hijack(_id="b")])
    assert "error" in p and "NAT rules described" in p["error"]


def test_same_description_on_a_different_interface_is_not_a_match():
    other = hijack(iface="6761cbadacbb3e2b114dc486", _id="r9")
    p = mod.plan(params(), NETWORKS, [other])
    assert p["state"] == "absent -> create"


def test_predefined_rules_are_never_matched():
    live = hijack(); live["is_predefined"] = True
    p = mod.plan(params(), NETWORKS, [live])
    assert p["state"] == "absent -> create"


def test_absent_state_deletes_only_when_present():
    assert mod.plan(params(state="absent"), NETWORKS, [])["state"] == "in sync"
    p = mod.plan(params(state="absent"), NETWORKS, [hijack()])
    assert p["state"] == "present -> delete" and p["id"] == "r1"


def test_payload_carries_unmanaged_fields_through():
    """A PUT replaces the whole object, so fields this module does not manage must
    survive rather than being reset to controller defaults."""
    live = hijack(); live["rule_index"] = 7; live["setting_preference"] = "manual"
    p = mod.plan(params(enabled=False), NETWORKS, [live])
    body = mod.payload(params(enabled=False), p)
    assert body["rule_index"] == 7
    assert body["setting_preference"] == "manual"
    assert body["enabled"] is False
    assert "_id" not in body


def test_enabled_toggle_is_drift():
    live = hijack(); live["enabled"] = False
    p = mod.plan(params(), NETWORKS, [live])
    assert p["state"] == "update" and "enabled" in p["diff"]


def test_port_compares_as_string_not_int():
    live = hijack(); live["destination_filter"]["port"] = 53
    p = mod.plan(params(), NETWORKS, [live])
    assert p["state"] == "in sync", p.get("diff")


def test_network_ids_are_the_legacy_objectid_space():
    """Guards the bug found live: Integration-API UUIDs do not match in_interface."""
    from mhl_unifly import network_map
    m = network_map(NETWORKS)
    assert m["IoT"] == "5f78b3d4b585e71b86d8fca0"
    assert all(len(v) == 24 and "-" not in v for v in m.values())
