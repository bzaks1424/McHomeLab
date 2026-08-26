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
