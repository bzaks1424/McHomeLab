"""unifi_diff — decides create/update/in-sync for the unifi role."""
from conftest import plugin

u = plugin("unifi")


def test_identical_is_empty():
    d = {"action": "Block", "ports": ["2376"], "enabled": True}
    assert u.unifi_diff(d, dict(d)) == []


def test_changed_value_is_reported_by_key():
    assert u.unifi_diff({"action": "Block"}, {"action": "Allow"}) == ["action"]


def test_missing_key_in_current_counts_as_different():
    assert u.unifi_diff({"action": "Block", "logging": True}, {"action": "Block"}) == ["logging"]


def test_extra_keys_in_current_are_ignored():
    assert u.unifi_diff({"action": "Block"}, {"action": "Block", "id": "x"}) == []


def test_order_of_reported_keys_follows_desired():
    desired = {"a": 1, "b": 2, "c": 3}
    assert u.unifi_diff(desired, {"a": 0, "b": 2, "c": 0}) == ["a", "c"]


def test_lists_compare_by_value_not_identity():
    assert u.unifi_diff({"ports": ["1", "2"]}, {"ports": ["1", "2"]}) == []
    assert u.unifi_diff({"ports": ["1", "2"]}, {"ports": ["2", "1"]}) == ["ports"]


def test_none_current_value_differs_from_absent_semantics():
    # None stored vs desired "" are different values — no coercion.
    assert u.unifi_diff({"desc": ""}, {"desc": None}) == ["desc"]
