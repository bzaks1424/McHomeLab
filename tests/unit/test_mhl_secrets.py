"""scripts/mhl_secrets.py classifier — one case per class the gate distinguishes.
The shell matrix (scripts/tests/secrets_matrix.sh) covers gate/tool agreement end to
end; these pin the classifier itself."""
import pytest
from conftest import script_module

m = script_module("mhl_secrets")


def classes(text):
    tree, err = m.compose(text)
    assert err is None, err
    return [(f.key, f.cls) for f in m.classify(text, tree)]


def test_plain_value_is_plain():
    assert classes('password: "hunter2"\n') == [("password", "plain")]
    assert classes("password: hunter2\n") == [("password", "plain")]


def test_vaulted_value_is_vaulted():
    text = "password: !vault |\n  $ANSIBLE_VAULT;1.2;AES256;mhl\n  6162\n"
    assert classes(text) == [("password", "vaulted")]


def test_template_reference_is_ref():
    assert classes('api_key: "{{ vault_api_key }}"\n') == [("api_key", "ref")]


def test_empty_values():
    assert classes("password:\n") == [("password", "empty")]
    assert classes('password: ""\n') == [("password", "empty_quoted")]


def test_block_scalar_under_secret_key():
    assert classes("token: |\n  abc\n") == [("token", "block_scalar")]


def test_flow_collection_holding_secret():
    assert classes("password: [a, b]\n") == [("password", "flow")]
    assert classes("{password: x}\n") == [("password", "flow")]


def test_block_collection_under_secret_key_is_collection():
    # a block collection under a secret-named key is fine (classified, not failed)
    assert classes("password:\n  user: a\n") == [("password", "collection")]


def test_next_line_value():
    assert classes('password:\n  "hunter2"\n') == [("password", "next_line")]


def test_embedded_secret_line_inside_block_scalar():
    # LINE_RE is `key: value` shaped (YAML-ish lines inside the block), not KEY=value
    text = "compose: |\n  environment:\n    password: hunter2\n"
    out = classes(text)
    assert len(out) == 1 and out[0][1] == "embedded"


def test_no_secret_marker_waives_block_content_scan():
    text = "motd: |  # no-secret: prose\n  password: is a word\n"
    assert classes(text) == []


def test_non_secret_key_is_ignored():
    assert classes("hostname: util\n") == []


def test_compose_rejects_multi_document_and_invalid_yaml():
    assert m.compose("a: 1\n---\nb: 2\n")[1].startswith("2 YAML documents")
    assert m.compose("a: [\n")[1].startswith("not valid YAML")


@pytest.mark.parametrize("cls", sorted(m.TOOL_REFUSES))
def test_every_tool_refusal_also_fails_the_gate(cls):
    assert cls in m.GATE_FAILS


def test_fallback_scan_finds_line_shaped_secrets():
    out = m.scan_text_fallback("password: abc\nname: x\npassword: !vault x\n")
    assert [(f.line, f.cls) for f in out] == [(1, "plain")]
