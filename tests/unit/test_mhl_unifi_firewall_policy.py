"""library/mhl_unifi_firewall_policy.plan() — the upsert decision, without Ansible."""
import sys
import types
import pytest
from conftest import load, ROOT

# The module imports ansible.module_utils.mhl_unifly; alias our file into that name.
mu = load("mhl_unifly", ROOT / "ansible" / "module_utils" / "mhl_unifly.py")
sys.modules["ansible.module_utils.mhl_unifly"] = mu
basic = types.ModuleType("ansible.module_utils.basic")
basic.AnsibleModule = object
sys.modules.setdefault("ansible", types.ModuleType("ansible"))
sys.modules.setdefault("ansible.module_utils", types.ModuleType("ansible.module_utils"))
sys.modules["ansible.module_utils.basic"] = basic
mod = load("mhl_unifi_firewall_policy", ROOT / "ansible" / "library" / "mhl_unifi_firewall_policy.py")

ZONES = [{"name": "Internal", "id": "i"}, {"name": "Dmz", "id": "d"}]
LIVE = {
    "id": "pid", "name": "P", "origin": "UserDefined", "action": "Block", "enabled": True, "logging_enabled": True,
    "source": {"zone_id": "i", "filter": None},
    "destination": {"zone_id": "d", "filter": {"kind": "port", "ports": {"kind": "values", "items": ["2376"], "match_opposite": False}}},
}


def params(**over):
    p = dict(name="P", action="block", source_zone="Internal", destination_zone="Dmz",
             destination_ports=["2376"], enabled=True, logging=True, description="x")
    p.update(over)
    return p


def test_absent_creates():
    p = mod.plan(params(), ZONES, [])
    assert p["state"] == "absent -> create" and p["desired"]["source_zone_id"] == "i"


def test_present_identical_is_in_sync():
    p = mod.plan(params(), ZONES, [LIVE])
    assert p["state"] == "in sync" and p["diff"] == [] and p["id"] == "pid"


def test_case_and_type_differences_do_not_cause_drift():
    p = mod.plan(params(action="BLOCK", destination_ports=[2376]), ZONES, [LIVE])
    assert p["state"] == "in sync"


def test_port_drift_is_an_update():
    p = mod.plan(params(destination_ports=["2376", "2377"]), ZONES, [LIVE])
    assert p["state"] == "update" and p["diff"] == ["destination_ports"] and p["id"] == "pid"


def test_action_drift_refuses():
    p = mod.plan(params(action="allow"), ZONES, [LIVE])
    assert "error" in p and "action" in p["error"] and "not done automatically" in p["error"]


@pytest.mark.parametrize("over,key", [(dict(enabled=False), "enabled"), (dict(logging=False), "logging")])
def test_enabled_logging_drift_is_a_patch_update(over, key):
    p = mod.plan(params(**over), ZONES, [LIVE])
    assert p["state"] == "update" and p["diff"] == [key]


def test_zone_change_is_a_different_policy_not_drift():
    # zones are part of the identity: a declared (name, zones) that does not exist is a create
    p = mod.plan(params(source_zone="Dmz", destination_zone="Internal"), ZONES, [LIVE])
    assert p["state"] == "absent -> create"


def test_clearing_ports_is_refused():
    p = mod.plan(params(destination_ports=[]), ZONES, [LIVE])
    assert "error" in p and "clearing the port filter" in p["error"]


def test_ip_address_filter_is_not_silently_treated_as_port_filter():
    ipf = dict(LIVE, destination={"zone_id": "d", "filter": {"kind": "ip_address", "ports": {"items": ["2376"]}}})
    p = mod.plan(params(), ZONES, [ipf])
    assert "error" in p and "destination_filter_kind" in p["error"]


def test_same_name_system_rule_is_ignored():
    sysrule = dict(LIVE, id="sys", origin="SystemDefined")
    assert mod.plan(params(), ZONES, [sysrule])["state"] == "absent -> create"


def test_duplicate_user_rules_error():
    p = mod.plan(params(), ZONES, [LIVE, dict(LIVE, id="pid2")])
    assert "error" in p and "2 user-defined" in p["error"]


def test_unknown_zone_is_an_error_not_a_create():
    p = mod.plan(params(destination_zone="Nope"), ZONES, [])
    assert "error" in p and "unknown zone" in p["error"]


def test_match_is_exact_name():
    other = dict(LIVE, name="P2")
    assert mod.plan(params(), ZONES, [other])["state"] == "absent -> create"
