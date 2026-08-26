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
