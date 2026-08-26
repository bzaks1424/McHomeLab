"""registry_get / inventory_entry — cross-host lookups every role relies on."""
from conftest import plugin

fm = plugin("registry_filters").FilterModule()
registry_get, inventory_entry = fm.registry_get, fm.inventory_entry


def test_registry_get_returns_value_field():
    assert registry_get({"k": {"value": "v"}}, "k") == "v"


def test_registry_get_default_paths():
    assert registry_get({}, "k") is None
    assert registry_get({}, "k", "d") == "d"
    assert registry_get(None, "k", "d") == "d"
    assert registry_get({"k": "not-a-dict"}, "k", "d") == "d"
    assert registry_get({"k": {"path": "/x"}}, "k", "d") == "d"


HOST = {
    "import": [
        {"name": "root_ca_cert", "dest": "/usr/local/share/ca-certificates/root_ca.crt"},
        {"name": "root_ca_cert", "dest": "/opt/certs/root_ca.crt"},
    ],
    "export": [{"name": "root_ca_cert", "src": "/data/root_ca.crt"}],
}


def test_inventory_entry_first_match_wins():
    assert inventory_entry(HOST, "import", "root_ca_cert", "dest") == "/usr/local/share/ca-certificates/root_ca.crt"


def test_inventory_entry_contains_filter_selects_later_match():
    assert inventory_entry(HOST, "import", "root_ca_cert", "dest", contains="/opt/") == "/opt/certs/root_ca.crt"


def test_inventory_entry_contains_no_match_gives_default():
    assert inventory_entry(HOST, "import", "root_ca_cert", "dest", default="d", contains="zzz") == "d"


def test_inventory_entry_export_section():
    assert inventory_entry(HOST, "export", "root_ca_cert", "src") == "/data/root_ca.crt"


def test_inventory_entry_missing_shapes():
    assert inventory_entry(HOST, "nope", "x", "y", "d") == "d"
    assert inventory_entry({"import": "str"}, "import", "x", "y", "d") == "d"
    assert inventory_entry("not-a-mapping", "import", "x", "y", "d") == "d"
    assert inventory_entry(HOST, "import", "missing", "dest", "d") == "d"
    assert inventory_entry(HOST, "import", "root_ca_cert", "missing_attr", "d") == "d"
