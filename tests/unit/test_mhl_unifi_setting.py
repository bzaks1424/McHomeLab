"""mhl_unifi_setting: pure plan()/payload() logic, no Ansible runtime, no controller."""
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
        "mhl_unifi_setting", ROOT / "ansible" / "library" / "mhl_unifi_setting.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


mod = _load()

# The live NextDNS pair this lab's WAN1 already uses. The values matter to the tests
# below only in that they are NOT the UniFi defaults 1.1.1.1 / 8.8.8.8.
NEXTDNS = {"domain": "ui.com",
           "primary_dns_server": "45.90.30.224",
           "secondary_dns_server": "45.90.28.224",
           "setting_preference": "manual"}
UNIFI_DEFAULTS = {"domain": "ui.com",
                  "primary_dns_server": "1.1.1.1",
                  "secondary_dns_server": "8.8.8.8",
                  "setting_preference": "auto"}


def usg(dns_verification=None, **extra):
    """The `usg` section roughly as the controller returns it. The unmanaged fields are
    not padding: the real section carries about thirty of them, and a module that
    compared or sent the whole object would fight the controller over defaults the lab
    has no opinion about. Every test that passes here must pass with them present."""
    section = {
        "_id": "5f78b127b585e71b86d8fc66",
        "key": "usg",
        "site_id": "5f78b125b585e71b86d8fc59",
        "broadcast_ping": False,
        "ftp_module": True,
        "mss_clamp": "auto",
        "offload_accounting": True,
        "tcp_established_timeout": 7440,
        "timeout_setting_preference": "auto",
    }
    if dns_verification is not None:
        section["dns_verification"] = dns_verification
    section.update(extra)
    return section


def params(values, key="usg", site="default"):
    return {"key": key, "values": values, "site": site, "unifly_bin": "unifly"}


# --- convergence ------------------------------------------------------------------

def test_in_sync_when_declared_matches_live():
    p = mod.plan(params({"dns_verification": NEXTDNS}), [usg(NEXTDNS)])
    assert p["state"] == "in sync"
    assert p["diff"] == []


def test_update_when_a_nested_field_differs():
    """The 2026-09-03 change, expressed as this module would have made it."""
    p = mod.plan(params({"dns_verification": NEXTDNS}), [usg(UNIFI_DEFAULTS)])
    assert p["state"] == "update"
    assert p["diff"] == ["dns_verification"]


def test_nested_objects_compare_whole():
    """One field differing inside the object is a difference in the object. The lab
    declares the whole sub-object or none of it; a partial match is not a match."""
    nearly = dict(NEXTDNS, secondary_dns_server="8.8.8.8")
    p = mod.plan(params({"dns_verification": NEXTDNS}), [usg(nearly)])
    assert p["state"] == "update"


def test_absent_field_counts_as_different():
    p = mod.plan(params({"dns_verification": NEXTDNS}), [usg(None)])
    assert p["state"] == "update"
    assert p["diff"] == ["dns_verification"]


def test_undeclared_fields_are_never_compared():
    """A section full of unmanaged fields is still in sync. This is the whole design:
    declaring one field must not drag thirty others into the diff."""
    p = mod.plan(params({"dns_verification": NEXTDNS}),
                 [usg(NEXTDNS, mss_clamp="custom", tcp_established_timeout=60)])
    assert p["state"] == "in sync"


def test_payload_sends_only_what_differs():
    p = mod.plan(params({"dns_verification": NEXTDNS, "broadcast_ping": False}),
                 [usg(UNIFI_DEFAULTS)])
    assert mod.payload(p) == {"dns_verification": NEXTDNS}


def test_payload_never_carries_unmanaged_fields():
    p = mod.plan(params({"dns_verification": NEXTDNS}), [usg(UNIFI_DEFAULTS)])
    assert set(mod.payload(p)) == {"dns_verification"}


# --- refusals ---------------------------------------------------------------------

def test_refuses_credential_fields():
    """`x_` is unifly's documented prefix for credentials. Declaring one would put a
    secret in git in clear, which rule 5 forbids -- so the module refuses rather than
    trusting whoever wrote the inventory to have noticed."""
    p = mod.plan(params({"x_ssh_auth_password": "hunter2"}), [usg(NEXTDNS)])
    assert "error" in p
    assert "refusing to manage credential fields" in p["error"]
    assert "hunter2" not in p["error"]


def test_refusal_lists_every_offending_field():
    p = mod.plan(params({"x_a": "1", "x_b": "2", "dns_verification": NEXTDNS}), [usg(NEXTDNS)])
    assert "error" in p
    assert "x_a" in p["error"] and "x_b" in p["error"]


def test_unknown_section_is_an_error_naming_what_exists():
    p = mod.plan(params({"foo": 1}, key="nosuch"), [usg(NEXTDNS), {"key": "mgmt"}])
    assert "error" in p
    assert "nosuch" in p["error"]
    assert "mgmt" in p["error"] and "usg" in p["error"]


def test_empty_values_is_an_error():
    p = mod.plan(params({}), [usg(NEXTDNS)])
    assert "error" in p


def test_duplicate_sections_are_an_error_not_a_guess():
    p = mod.plan(params({"dns_verification": NEXTDNS}), [usg(NEXTDNS), usg(UNIFI_DEFAULTS)])
    assert "error" in p
    assert "keyed" in p["error"]


# --- regression -------------------------------------------------------------------

def test_the_change_this_module_exists_to_have_made():
    """2026-09-03: the WAN health check resolved ui.com through Cloudflare and Google in
    cleartext, outside NextDNS, and was fixed by an ad hoc CLI write because no
    declarative path existed. Converging from the defaults must produce exactly one
    change, touching exactly one field."""
    p = mod.plan(params({"dns_verification": NEXTDNS}), [usg(UNIFI_DEFAULTS)])
    assert p["state"] == "update"
    assert p["diff"] == ["dns_verification"]
    assert mod.payload(p)["dns_verification"]["primary_dns_server"].startswith("45.90.")
    assert mod.payload(p)["dns_verification"]["setting_preference"] == "manual"


def test_rerunning_after_the_change_is_a_no_op():
    """Idempotence is the point of declaring it: the second run must not rewrite."""
    p = mod.plan(params({"dns_verification": NEXTDNS}), [usg(NEXTDNS)])
    assert p["state"] == "in sync"
    with pytest.raises(KeyError):
        mod.payload(p)["dns_verification"]
