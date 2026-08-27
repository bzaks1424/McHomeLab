"""governance_list / governance_port_match — the C5 assertion's engine."""
from conftest import plugin

g = plugin("governance")


def pol(name, ports=None, match_opposite=False, filter_kind="port", no_filter=False):
    if no_filter:
        dest = {"zone_id": "dmz", "filter": None}
    else:
        f = {"kind": filter_kind}
        if ports is not None:
            f["ports"] = {"kind": "values", "items": ports, "match_opposite": match_opposite}
        dest = {"zone_id": "dmz", "filter": f}
    return {"name": name, "destination": dest}


def names(policies):
    return [p["name"] for p in policies]


def test_list_normalises_bare_list_and_data_wrapper():
    assert g.governance_list([1, 2]) == [1, 2]
    assert g.governance_list({"data": [3]}) == [3]
    assert g.governance_list({"other": 1}) == []
    assert g.governance_list(None) == []


def test_exact_port_matches():
    assert names(g.governance_port_match([pol("a", ["2376"])], "2376")) == ["a"]
    assert names(g.governance_port_match([pol("a", ["2377"])], "2376")) == []


def test_integer_items_and_port_are_compared_as_strings():
    assert names(g.governance_port_match([pol("a", [2376])], 2376)) == ["a"]


def test_range_matches_inclusive_bounds():
    assert names(g.governance_port_match([pol("r", ["2000-2376"])], "2376")) == ["r"]
    assert names(g.governance_port_match([pol("r", ["2376-3000"])], "2376")) == ["r"]
    assert names(g.governance_port_match([pol("r", ["2377-3000"])], "2376")) == []


def test_malformed_range_is_ignored_not_fatal():
    assert names(g.governance_port_match([pol("r", ["abc-def"])], "2376")) == []


def test_match_opposite_inverts():
    assert names(g.governance_port_match([pol("o", ["2376"], match_opposite=True)], "2376")) == []
    assert names(g.governance_port_match([pol("o", ["22"], match_opposite=True)], "2376")) == ["o"]


def test_filter_without_ports_reaches_every_port():
    # ip_address filters without a ports block, or an empty ports block, reach all ports.
    assert names(g.governance_port_match([pol("ip", filter_kind="ip_address")], "2376")) == ["ip"]


def test_null_filter_reaches_every_port():
    assert names(g.governance_port_match([pol("all", no_filter=True)], "2376")) == ["all"]


def test_missing_destination_is_treated_as_all_ports():
    assert names(g.governance_port_match([{"name": "bare"}], "2376")) == ["bare"]


def test_mixed_list_keeps_order():
    ps = [pol("a", ["80"]), pol("b", ["2376"]), pol("c", ["1-65535"])]
    assert names(g.governance_port_match(ps, "2376")) == ["b", "c"]


def test_allowing_is_case_insensitive_and_enabled_only():
    ps = [{"name": "a", "action": "Allow", "enabled": True}, {"name": "b", "action": "ALLOW", "enabled": True},
          {"name": "c", "action": "allow", "enabled": False}, {"name": "d", "action": "Block", "enabled": True},
          {"name": "e", "action": "ALLOW", "enabled": "true"}]
    assert names(g.governance_allowing(ps)) == ["a", "b", "e"]


def test_allowing_rejects_unknown_action_enum():
    import pytest
    with pytest.raises(ValueError, match="unexpected firewall action"):
        g.governance_allowing([{"name": "x", "action": "DROP", "enabled": True}])


def zp(name, src, dst, action, index, ports=None, enabled=True):
    p = pol(name, ports) if ports is not None else pol(name, no_filter=True)
    p.update({"action": action, "index": index, "enabled": enabled, "source": {"zone_id": src}})
    p["destination"]["zone_id"] = dst
    return p


def test_unshadowed_keeps_allow_without_preceding_block():
    allow = zp("Allow All", "vpn", "dmz", "Allow", 2147483647)
    assert names(g.governance_unshadowed([allow], [allow], "2376")) == ["Allow All"]


def test_unshadowed_drops_allow_behind_matching_block():
    allow = zp("Allow All", "vpn", "dmz", "Allow", 2147483647)
    block = zp("Block 2376", "vpn", "dmz", "Block", 10000, ports=["2376"])
    assert names(g.governance_unshadowed([allow], [allow, block], "2376")) == []


def test_unshadowed_ignores_blocks_for_other_zone_pairs_ports_or_later_index_or_disabled():
    allow = zp("Allow All", "vpn", "dmz", "Allow", 20000)
    other_pair = zp("b1", "iot", "dmz", "Block", 10000, ports=["2376"])
    other_port = zp("b2", "vpn", "dmz", "Block", 10000, ports=["22"])
    later = zp("b3", "vpn", "dmz", "Block", 30000, ports=["2376"])
    disabled = zp("b4", "vpn", "dmz", "Block", 10000, ports=["2376"], enabled=False)
    assert names(g.governance_unshadowed([allow], [allow, other_pair, other_port, later, disabled], "2376")) == ["Allow All"]


def test_unshadowed_reject_counts_as_block_and_range_blocks_match():
    allow = zp("Allow All", "vpn", "dmz", "Allow", 20000)
    rej = zp("r", "vpn", "dmz", "Reject", 10000, ports=["2000-3000"])
    assert names(g.governance_unshadowed([allow], [allow, rej], "2376")) == []


def test_allowing_excludes_reply_only_allows_but_not_new_or_unrestricted():
    ps = [{"name": "ret", "action": "Allow", "enabled": True, "connection_states": ["ESTABLISHED", "RELATED"]},
          {"name": "new", "action": "Allow", "enabled": True, "connection_states": ["NEW", "ESTABLISHED"]},
          {"name": "any", "action": "Allow", "enabled": True, "connection_states": []},
          {"name": "inv", "action": "Allow", "enabled": True, "connection_states": ["INVALID"]}]
    assert names(g.governance_allowing(ps)) == ["new", "any", "inv"]


def test_unshadowed_narrow_block_does_not_excuse_broad_allow():
    allow = zp("Allow All", "vpn", "dmz", "Allow", 20000)
    narrow = zp("one host", "vpn", "dmz", "Block", 10000, ports=["2376"])
    narrow["destination"]["filter"] = {"kind": "ip_address", "ips": ["10.0.0.5"], "ports": {"items": ["2376"]}}
    src_filtered = zp("one src", "vpn", "dmz", "Block", 10000, ports=["2376"])
    src_filtered["source"]["filter"] = {"kind": "ip_address", "ips": ["10.9.9.9"]}
    scheduled = zp("nights", "vpn", "dmz", "Block", 10000, ports=["2376"])
    scheduled["schedule"] = {"mode": "EVERY_DAY"}
    assert names(g.governance_unshadowed([allow], [allow, narrow, src_filtered, scheduled], "2376")) == ["Allow All"]


def test_unshadowed_invalid_only_block_does_not_excuse():
    allow = zp("Allow All", "vpn", "dmz", "Allow", 20000)
    inv = zp("Block Invalid", "vpn", "dmz", "Block", 10000, ports=["2376"])
    inv["connection_states"] = ["INVALID"]
    assert names(g.governance_unshadowed([allow], [allow, inv], "2376")) == ["Allow All"]


def test_unshadowed_string_false_enabled_is_disabled():
    allow = zp("Allow All", "vpn", "dmz", "Allow", 20000)
    b = zp("b", "vpn", "dmz", "Block", 10000, ports=["2376"])
    b["enabled"] = "false"
    assert names(g.governance_unshadowed([allow], [allow, b], "2376")) == ["Allow All"]


def test_unshadowed_state_superset_block_covers():
    allow = zp("new only", "vpn", "dmz", "Allow", 20000)
    allow["connection_states"] = ["NEW"]
    b = zp("b", "vpn", "dmz", "Block", 10000, ports=["2376"])
    b["connection_states"] = ["NEW", "ESTABLISHED"]
    assert names(g.governance_unshadowed([allow], [allow, b], "2376")) == []
