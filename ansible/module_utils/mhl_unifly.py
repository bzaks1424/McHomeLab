# -*- coding: utf-8 -*-
"""Shared helpers for the mhl UniFi modules: a thin, testable wrapper around the
unifly CLI (research/RESEARCH_UNIFI_RC.md §2). No Ansible imports here so the
logic is unit-testable without an Ansible runtime."""
from __future__ import absolute_import, division, print_function

__metaclass__ = type

import json
import subprocess


class UniflyError(Exception):
    pass


class Unifly(object):
    """Runs `unifly ... --all -o json` and parses the result. `runner` is injectable for tests:
    runner(argv) -> (rc, stdout, stderr)."""

    def __init__(self, binary, runner=None):
        self.binary = binary
        self.runner = runner or self._run

    @staticmethod
    def _run(argv):
        # stdin closed: unifly must never block on a confirmation prompt under Ansible.
        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, err = p.communicate()
        return p.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")

    def call(self, *args):
        """Write-style call: returns stdout text, raises on non-zero."""
        rc, out, err = self.runner([self.binary] + list(args))
        if rc != 0:
            raise UniflyError("unifly %s failed (rc=%s): %s" % (" ".join(args[:3]), rc, err.strip() or out.strip()))
        return out

    def write(self, *args):
        """Mutating call: always non-interactive (-y)."""
        return self.call(*(list(args) + ["--yes"]))

    def list_json(self, *args):
        out = self.call(*(list(args) + ["--all", "-o", "json"]))
        if not out.strip():
            raise UniflyError("unifly %s: empty output (refusing to treat as an empty list)" % " ".join(args))
        try:
            doc = json.loads(out or "[]")
        except ValueError as e:
            raise UniflyError("unifly %s: not JSON (%s)" % (" ".join(args), e))
        return normalize_list(doc)


def api_get(unifly, path):
    """Raw GET through `unifly api`. Used instead of the typed subcommands wherever
    unifly's own model is lossy: its NAT model omits destination_filter.invert_address
    entirely on read and hardcodes it false on create (v0.10.0,
    crates/unifly-api/.../policy/nat.rs:235,243), so a rule read and recreated through
    `unifly nat policies` silently inverts its meaning. Raw JSON round-trips intact."""
    out = unifly.call("api", path)
    if not out.strip():
        raise UniflyError("unifly api %s: empty output" % path)
    try:
        return normalize_list(json.loads(out))
    except ValueError as e:
        raise UniflyError("unifly api %s: not JSON (%s)" % (path, e))


def api_write(unifly, method, path, payload):
    """Raw write through `unifly api -m <method> -d <json>`. Returns parsed JSON when
    the controller sends any, else None."""
    out = unifly.call("api", path, "-m", method, "-d", json.dumps(payload))
    if not out.strip():
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


def network_map(networks):
    """[{name, _id|id}] -> {name: id}. NAT rules reference a network by id in
    `in_interface`; the inventory names it, exactly as zones are named for policies."""
    out = {}
    for n in networks:
        nid = n.get("_id") or n.get("id")
        if n.get("name") and nid:
            out[n["name"]] = nid
    return out


def find_nat_rule(rules, description, in_interface_id):
    """NAT rules carry `description`, not `name`, and descriptions are not guaranteed
    unique. Match on (description, in_interface); more than one hit is an error, never
    a guess -- same contract as find_policy."""
    hits = [r for r in rules
            if r.get("description") == description
            and r.get("in_interface") == in_interface_id
            and not r.get("is_predefined")]
    if len(hits) > 1:
        raise AmbiguousMatch("%d NAT rules described %r on the same interface (ids: %s)"
                             % (len(hits), description,
                                ", ".join(str(h.get("_id")) for h in hits)))
    return hits[0] if hits else None


def nat_filter_shape(f):
    """The compared subset of a source/destination filter, in canonical form.
    `address` is absent on a filter that inverts against nothing -- the DMZ hijack rule
    is shaped that way and works -- so absent and empty must stay distinguishable."""
    f = f or {}
    return {
        "filter_type": f.get("filter_type") or "NONE",
        "address": f.get("address"),
        "port": str(f["port"]) if f.get("port") not in (None, "") else None,
        "invert_address": bool(f.get("invert_address", False)),
        "invert_port": bool(f.get("invert_port", False)),
    }


def nat_rule_shape(rule):
    """The compared subset of a live NAT rule."""
    return {
        "type": (rule.get("type") or "").upper(),
        "enabled": bool(rule.get("enabled", False)),
        "protocol": rule.get("protocol") or "all",
        "ip_address": rule.get("ip_address"),
        "port": str(rule["port"]) if rule.get("port") not in (None, "") else None,
        "logging": bool(rule.get("logging", False)),
        "exclude": bool(rule.get("exclude", False)),
        "ip_version": rule.get("ip_version") or "IPV4",
        "destination_filter": nat_filter_shape(rule.get("destination_filter")),
        "source_filter": nat_filter_shape(rule.get("source_filter")),
    }


def normalize_list(doc):
    """unifly returns either a bare list or {"data": [...]}."""
    if isinstance(doc, dict):
        return doc.get("data", []) or []
    return doc or []


def zone_map(zones):
    """[{name, id}] -> {name: id}"""
    return dict((z["name"], z["id"]) for z in zones if "name" in z and "id" in z)


def by_name(items, name):
    for it in items:
        if it.get("name") == name:
            return it
    return None


class AmbiguousMatch(Exception):
    pass


def find_policy(policies, name, source_zone_id, destination_zone_id):
    """Policy names are NOT unique on a controller (system rules repeat per zone pair, and
    auto '(Return)' companions carry origin None). Match user-defined policies on
    (name, source zone, destination zone); more than one hit is an error, not a guess."""
    hits = [
        p for p in policies
        if p.get("name") == name and p.get("origin") == "UserDefined"
        and (p.get("source") or {}).get("zone_id") == source_zone_id
        and (p.get("destination") or {}).get("zone_id") == destination_zone_id
    ]
    if len(hits) > 1:
        raise AmbiguousMatch("%d user-defined policies named %r between the same zones (ids: %s)"
                             % (len(hits), name, ", ".join(str(h.get("id")) for h in hits)))
    return hits[0] if hits else None


def diff_keys(desired, current):
    """Keys of desired whose value differs from current (missing counts as different)."""
    sentinel = object()
    return [k for k, v in desired.items() if current.get(k, sentinel) != v]


# --- site settings ---------------------------------------------------------------
#
# Settings differ from policies and NAT rules in one way that shapes everything below:
# a section always exists and cannot be created or deleted, only converged. There is no
# `absent`. The `usg` section alone carries ~30 fields the lab does not manage, so a
# module that compared or sent the whole section would fight the controller over
# defaults it has no opinion about. Only declared keys are compared, and only declared
# keys are sent.

SECRET_FIELD_PREFIX = "x_"


def find_setting(sections, key):
    """The section with this key, or None. Sections are unique per key on a site;
    more than one is a controller we do not understand, not something to guess at."""
    hits = [s for s in sections if s.get("key") == key]
    if len(hits) > 1:
        raise AmbiguousMatch("%d setting sections keyed %r (ids: %s)"
                             % (len(hits), key, ", ".join(str(h.get("_id")) for h in hits)))
    return hits[0] if hits else None


def secret_fields(values):
    """Declared field names that carry credentials. unifly documents the `x_` prefix as
    exactly that, and rule 5 says a secret is an inline !vault value in hosts.yml, never
    a plain field. Declaring one here would put it in git in clear, so the module refuses
    rather than trusting the author to have noticed."""
    return sorted(k for k in values if k.startswith(SECRET_FIELD_PREFIX))


def setting_diff(declared, current):
    """Declared keys whose live value differs. Nested objects (dns_verification is one)
    compare whole: the lab declares the entire sub-object or none of it, so a partial
    match is a difference. Reuses diff_keys so there is one definition of 'differs'."""
    return sorted(diff_keys(declared, current or {}))


def policy_ports(policy):
    """destination.filter.ports.items as a sorted list of strings ([] when unrestricted)."""
    dest = policy.get("destination") or {}
    flt = dest.get("filter") or {}
    ports = flt.get("ports") or {}
    return sorted(str(x) for x in (ports.get("items") or []))


def policy_shape(policy):
    """The compared subset of a live policy, in the module's canonical shape."""
    dest = policy.get("destination") or {}
    flt = dest.get("filter") or {}
    return {
        "action": (policy.get("action") or "").lower(),
        "enabled": bool(policy.get("enabled", False)),
        "source_zone_id": (policy.get("source") or {}).get("zone_id", ""),
        "destination_zone_id": dest.get("zone_id", ""),
        "destination_filter_kind": flt.get("kind") or "",   # "" = unrestricted, "port", "ip_address", ...
        "destination_ports": policy_ports(policy),
        "logging": bool(policy.get("logging_enabled", False)),
    }


# What unifly can change in place (0.10.0 --help, 2026-08-26): `update` takes the port
# flags; `patch` toggles enabled/logging. Anything else differing is refused.
UPDATE_ONLY = ("destination_ports",)
PATCHABLE = ("enabled", "logging")


def create_args(name, desired, description):
    args = [
        "--name", name,
        "--action", desired["action"],
        "--source-zone", desired["source_zone_id"],
        "--dest-zone", desired["destination_zone_id"],
        "--enabled", "true" if desired["enabled"] else "false",
        "--description", description,
    ]
    if desired["destination_ports"]:
        args += ["--dst-port", ",".join(desired["destination_ports"])]
    if desired["logging"]:
        args.append("--logging")
    return args


def update_args(desired):
    """Port change only. Clearing the ports (desired []) has no unifly flag: the caller
    must refuse it rather than send an empty update that changes nothing."""
    if not desired["destination_ports"]:
        raise ValueError("cannot clear destination ports via unifly update")
    return ["--dst-port", ",".join(desired["destination_ports"])]


def patch_args(desired, keys):
    args = []
    if "enabled" in keys:
        args += ["--enabled", "true" if desired["enabled"] else "false"]
    if "logging" in keys:
        args += ["--logging", "true" if desired["logging"] else "false"]
    return args
