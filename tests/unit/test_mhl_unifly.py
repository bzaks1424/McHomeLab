"""module_utils/mhl_unifly — unifly wrapper + pure helpers used by the mhl_unifi_* modules."""
import json
import pytest
from conftest import load, ROOT

mu = load("mhl_unifly", ROOT / "ansible" / "module_utils" / "mhl_unifly.py")


def fake_runner(table):
    """table: {tuple(args after binary): (rc, stdout, stderr)}; records calls."""
    calls = []

    def run(argv):
        calls.append(argv[1:])
        return table.get(tuple(argv[1:]), (127, "", "no such command"))
    run.calls = calls
    return run


def test_list_json_normalises_bare_and_wrapped():
    r = fake_runner({("x", "list", "--all", "-o", "json"): (0, json.dumps({"data": [{"a": 1}]}), "")})
    assert mu.Unifly("unifly", r).list_json("x", "list") == [{"a": 1}]
    r = fake_runner({("x", "list", "--all", "-o", "json"): (0, "[]", "")})
    assert mu.Unifly("unifly", r).list_json("x", "list") == []


def test_call_raises_with_stderr_on_failure():
    r = fake_runner({("firewall", "policies", "create"): (1, "", "API error: Invalid $.action.type value 'DROP'")})
    with pytest.raises(mu.UniflyError, match="DROP"):
        mu.Unifly("unifly", r).call("firewall", "policies", "create")


def test_list_json_rejects_non_json():
    r = fake_runner({("x", "list", "--all", "-o", "json"): (0, "<html>", "")})
    with pytest.raises(mu.UniflyError, match="not JSON"):
        mu.Unifly("unifly", r).list_json("x", "list")


def test_zone_map_and_by_name():
    zones = [{"name": "Dmz", "id": "d"}, {"name": "Internal", "id": "i"}, {"bogus": 1}]
    assert mu.zone_map(zones) == {"Dmz": "d", "Internal": "i"}
    assert mu.by_name(zones, "Dmz") == {"name": "Dmz", "id": "d"}
    assert mu.by_name(zones, "nope") is None


def test_diff_keys_missing_counts_as_different():
    assert mu.diff_keys({"a": 1, "b": 2}, {"a": 1}) == ["b"]
    assert mu.diff_keys({"a": 1}, {"a": 1, "z": 9}) == []


LIVE = {
    "id": "pid", "name": "P", "action": "Block", "enabled": True, "logging_enabled": True,
    "source": {"zone_id": "i", "filter": None},
    "destination": {"zone_id": "d", "filter": {"kind": "port", "ports": {"kind": "values", "items": [2376, "22"], "match_opposite": False}}},
}


def test_policy_shape_canonicalises_live_json():
    assert mu.policy_shape(LIVE) == {
        "action": "block", "enabled": True, "source_zone_id": "i", "destination_zone_id": "d",
        "destination_filter_kind": "port", "destination_ports": ["22", "2376"], "logging": True,
    }


def test_policy_shape_records_filter_kind():
    ipf = dict(LIVE, destination={"zone_id": "d", "filter": {"kind": "ip_address", "ports": {"items": ["445"]}}})
    assert mu.policy_shape(ipf)["destination_filter_kind"] == "ip_address"
    assert mu.policy_shape({"destination": {"zone_id": "d", "filter": None}})["destination_filter_kind"] == ""


def test_policy_shape_tolerates_null_filter_and_missing_keys():
    assert mu.policy_shape({"name": "x"})["destination_ports"] == []
    assert mu.policy_shape({"destination": {"zone_id": "d", "filter": None}})["destination_ports"] == []


def test_create_and_update_args():
    d = {"action": "block", "enabled": True, "source_zone_id": "i", "destination_zone_id": "d", "destination_ports": ["2376"], "logging": True}
    a = mu.create_args("P", d, "desc")
    assert a[:2] == ["--name", "P"] and "--logging" in a and a[a.index("--dst-port") + 1] == "2376" and a[a.index("--enabled") + 1] == "true"
    assert mu.update_args(d) == ["--dst-port", "2376"]
    d2 = dict(d, destination_ports=[], logging=False, enabled=False)
    a2 = mu.create_args("P", d2, "desc")
    assert "--dst-port" not in a2 and "--logging" not in a2 and a2[a2.index("--enabled") + 1] == "false"


def test_update_args_refuses_to_clear_ports():
    with pytest.raises(ValueError):
        mu.update_args({"destination_ports": []})


def test_patch_args_only_requested_keys():
    d = {"enabled": False, "logging": True}
    assert mu.patch_args(d, ["enabled"]) == ["--enabled", "false"]
    assert mu.patch_args(d, ["logging", "enabled"]) == ["--enabled", "false", "--logging", "true"]
    assert mu.patch_args(d, []) == []


def test_write_appends_yes_and_stdin_is_closed_by_default_runner():
    r = fake_runner({("firewall", "policies", "create", "--name", "P", "--yes"): (0, "", "")})
    mu.Unifly("unifly", r).write("firewall", "policies", "create", "--name", "P")
    assert r.calls[-1][-1] == "--yes"


def test_list_json_refuses_empty_output():
    r = fake_runner({("x", "list", "--all", "-o", "json"): (0, "", "")})
    with pytest.raises(mu.UniflyError, match="empty output"):
        mu.Unifly("unifly", r).list_json("x", "list")


def mk(name, src, dst, origin="UserDefined", pid="p"):
    return {"id": pid, "name": name, "origin": origin, "source": {"zone_id": src}, "destination": {"zone_id": dst}}


def test_find_policy_matches_on_name_and_zones_user_defined_only():
    pols = [mk("Allow All Traffic", "a", "b", "SystemDefined", "sys"), mk("Allow All Traffic", "i", "iot", pid="user"),
            mk("X (Return)", "i", "iot", origin=None, pid="ret")]
    assert mu.find_policy(pols, "Allow All Traffic", "i", "iot")["id"] == "user"
    assert mu.find_policy(pols, "Allow All Traffic", "a", "b") is None      # system rule is never adopted
    assert mu.find_policy(pols, "X (Return)", "i", "iot") is None            # auto companion (origin None)


def test_find_policy_ambiguous_is_an_error():
    pols = [mk("Dup", "i", "d", pid="1"), mk("Dup", "i", "d", pid="2")]
    with pytest.raises(mu.AmbiguousMatch, match="2 user-defined"):
        mu.find_policy(pols, "Dup", "i", "d")
