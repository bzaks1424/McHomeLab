#!/usr/bin/python
# -*- coding: utf-8 -*-
"""Ansible module: converge declared fields of ONE UniFi site setting section.

Why this exists. On 2026-09-03 the controller's `usg.dns_verification` was changed by
an ad hoc CLI write, because no declarative path existed for site settings -- the
`unifi` role reconciled firewall policies and NAT rules and nothing else. That is
precisely the gap rule 1 forbids operating in: the controller's own state changed with
no revision history. This module closes it so the same change is expressed as a diff.

Settings are not policies. A section always exists, cannot be created or deleted, and
carries far more fields than the lab has an opinion about -- `usg` alone has around
thirty, most of them connection timeouts. So this module converges DECLARED KEYS ONLY:
it compares what the inventory states and sends what the inventory states, leaving
everything else to the controller. There is no `state: absent`; the opposite of
declaring a field is not declaring it.

Writes go through `unifly settings set <key> --data <json>`, which merges. The raw API
is deliberately NOT used here, unlike mhl_unifi_nat_rule: that module needs raw JSON
because unifly's typed NAT model is lossy, whereas the settings command round-trips a
merge correctly -- confirmed by reading the value back off the controller after the
2026-09-03 change. Using the typed path also means this module does not have to
discover a write endpoint by experimenting against the live controller, which rule 1
would not permit anyway.

Fields prefixed `x_` are refused outright. unifly documents that prefix as credentials
and internal secrets, and rule 5 requires secrets to be inline `!vault` values; a
declared `x_` field would be a cleartext secret in git.
"""
from __future__ import absolute_import, division, print_function

__metaclass__ = type

DOCUMENTATION = r"""
---
module: mhl_unifi_setting
short_description: Converge declared fields of a UniFi site setting section
options:
  key: {type: str, required: true, description: Section key, e.g. usg / mgmt / ntp}
  values:
    type: dict
    required: true
    description: >
      Fields to converge. Only these are compared and only these are sent; every other
      field in the section is left to the controller. Nested objects compare whole.
  unifly_bin: {type: path, default: unifly}
  site: {type: str, default: default}
"""

EXAMPLES = r"""
# The WAN health check resolved its probe domain through Cloudflare and Google in
# cleartext, outside NextDNS. Declared here so it cannot drift back.
- mhl_unifi_setting:
    key: "usg"
    values:
      dns_verification:
        domain: "ui.com"
        primary_dns_server: "45.90.30.224"
        secondary_dns_server: "45.90.28.224"
        setting_preference: "manual"
"""

RETURN = r"""
state: {description: "in sync | update", type: str}
diff_keys: {description: declared fields whose live value differs, type: list}
"""

import json  # noqa: E402

from ansible.module_utils.basic import AnsibleModule  # noqa: E402
from ansible.module_utils.mhl_unifly import (  # noqa: E402
    AmbiguousMatch, Unifly, UniflyError, api_get, find_setting, secret_fields,
    setting_diff,
)

SETTING_PATH = "api/s/%s/rest/setting"


def plan(params, sections):
    """Pure decision logic (unit-tested): dict(state, diff, declared, current, error)."""
    values = params["values"] or {}
    if not values:
        return {"error": "values is empty: declare at least one field, or omit the entry"}

    leaked = secret_fields(values)
    if leaked:
        return {"error": "refusing to manage credential fields %s: the %r prefix marks "
                         "secrets, which belong in hosts.yml as inline !vault values, "
                         "not as declared plaintext" % (leaked, "x_")}

    try:
        section = find_setting(sections, params["key"])
    except AmbiguousMatch as e:
        return {"error": str(e)}
    if section is None:
        return {"error": "no setting section keyed %r on site %r (known: %s)"
                         % (params["key"], params["site"],
                            ", ".join(sorted(s.get("key", "?") for s in sections)))}

    diff = setting_diff(values, section)
    if not diff:
        return {"state": "in sync", "diff": [], "declared": values, "current": section}
    return {"state": "update", "diff": diff, "declared": values, "current": section}


def payload(p):
    """Only the fields that differ. Sending the whole declaration would be harmless but
    less honest: the report should say what changed, and the request should match it."""
    return dict((k, p["declared"][k]) for k in p["diff"])


def main():
    module = AnsibleModule(
        argument_spec=dict(
            key=dict(type="str", required=True),
            values=dict(type="dict", required=True),
            unifly_bin=dict(type="path", default="unifly"),
            site=dict(type="str", default="default"),
        ),
        supports_check_mode=True,
    )
    u = Unifly(module.params["unifly_bin"])
    try:
        sections = api_get(u, SETTING_PATH % module.params["site"])
    except UniflyError as e:
        module.fail_json(msg=str(e))

    p = plan(module.params, sections)
    if "error" in p:
        module.fail_json(msg=p["error"], diff_keys=p.get("diff", []))

    result = dict(changed=p["state"] != "in sync", state=p["state"],
                  diff_keys=p["diff"], key=module.params["key"])
    if result["changed"] and not module.check_mode:
        # `settings set` takes no --yes, so call() not write(); it is non-interactive
        # already and Unifly closes stdin so it can never block on a prompt.
        try:
            u.call("settings", "set", module.params["key"],
                   "--data", json.dumps(payload(p)),
                   "--site", module.params["site"])
        except UniflyError as e:
            module.fail_json(msg=str(e), **result)
    module.exit_json(**result)


if __name__ == "__main__":
    main()
