"""service_secret_entries / secret_env_name — compose secret delivery."""
import pytest
from conftest import plugin

s = plugin("service_secrets")

STYLE_MAP = {
    "lsio": {"prefix": "FILE__", "suffix": ""},
    "gluetun": {"prefix": "", "suffix": "_SECRETFILE"},
    "wud": {"prefix": "", "suffix": "__FILE"},
    "generic": {"prefix": "", "suffix": "_FILE"},
}


def test_entries_default_style_is_lsio():
    out = s.service_secret_entries({"key": "plex", "value": {"secrets": {"PLEX_CLAIM": "claim-x"}}})
    assert out == [{"service": "plex", "name": "PLEX_CLAIM", "style": "lsio", "value": "claim-x"}]


def test_entries_honour_declared_style_and_keep_order():
    out = s.service_secret_entries({"key": "gluetun", "value": {"secret_style": "gluetun", "secrets": {"A": "1", "B": "2"}}})
    assert [e["name"] for e in out] == ["A", "B"]
    assert {e["style"] for e in out} == {"gluetun"}


def test_entries_without_secrets_is_empty():
    assert s.service_secret_entries({"key": "svc", "value": {}}) == []
    assert s.service_secret_entries({"key": "svc", "value": {"secrets": None}}) == []


@pytest.mark.parametrize(
    "style,expected",
    [("lsio", "FILE__PLEX_CLAIM"), ("gluetun", "PLEX_CLAIM_SECRETFILE"), ("wud", "PLEX_CLAIM__FILE"), ("generic", "PLEX_CLAIM_FILE")],
)
def test_env_name_per_style(style, expected):
    assert s.secret_env_name("PLEX_CLAIM", STYLE_MAP, style) == expected


def test_unknown_style_is_an_error_not_a_silent_fallback():
    with pytest.raises(ValueError, match="unknown secret_style"):
        s.secret_env_name("X", STYLE_MAP, "nope")
