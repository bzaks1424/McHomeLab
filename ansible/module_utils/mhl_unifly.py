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
        p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, err = p.communicate()
        return p.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")

    def call(self, *args):
        """Write-style call: returns stdout text, raises on non-zero."""
        rc, out, err = self.runner([self.binary] + list(args))
        if rc != 0:
            raise UniflyError("unifly %s failed (rc=%s): %s" % (" ".join(args[:3]), rc, err.strip() or out.strip()))
        return out

    def list_json(self, *args):
        out = self.call(*(list(args) + ["--all", "-o", "json"]))
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
    return {
        "action": (policy.get("action") or "").lower(),
        "enabled": bool(policy.get("enabled", False)),
        "source_zone_id": (policy.get("source") or {}).get("zone_id", ""),
        "destination_zone_id": (policy.get("destination") or {}).get("zone_id", ""),
        "destination_ports": policy_ports(policy),
        "logging": bool(policy.get("logging_enabled", False)),
    }


# Fields unifly `update` cannot change (verified against unifly 0.10.0 --help, 2026-08-26).
UPDATE_ONLY = ("destination_ports",)


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
    args = []
    if desired["destination_ports"]:
        args += ["--dst-port", ",".join(desired["destination_ports"])]
    return args
