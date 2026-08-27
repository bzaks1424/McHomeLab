"""Filters for the governance role (UniFi JSON shapes as returned by unifly)."""


def governance_list(doc):
    """unifly returns either a bare list or {"data": [...]}; normalise."""
    if isinstance(doc, dict):
        return doc.get("data", [])
    return doc or []


def _port_hits(items, port):
    for it in items or []:
        s = str(it)
        if s == port:
            return True
        if "-" in s:
            lo, hi = s.split("-", 1)
            try:
                if int(lo) <= int(port) <= int(hi):
                    return True
            except ValueError:
                pass
    return False


VALID_ACTIONS = ("allow", "block", "reject")


def governance_allowing(policies):
    """Enabled policies whose action is ALLOW, case-insensitively. Raises on an action
    outside allow/block/reject so a renamed enum cannot make the assertion pass vacuously."""
    out = []
    for p in policies:
        action = str(p.get("action") or "").lower()
        if action not in VALID_ACTIONS:
            raise ValueError("unexpected firewall action %r on policy %r" % (p.get("action"), p.get("name")))
        enabled = _enabled(p)
        # An allow restricted to ESTABLISHED/RELATED (no NEW) cannot open a port; it only
        # lets replies through for connections some other policy permitted.
        states = [str(x).upper() for x in (p.get("connection_states") or [])]
        reply_only = bool(states) and "NEW" not in states and set(states) <= {"ESTABLISHED", "RELATED"}
        if enabled and action == "allow" and not reply_only:
            out.append(p)
    return out


def governance_port_match(policies, port):
    """Policies whose destination filter reaches `port`: a `ports` block (present
    on port and ip_address filters alike) matching the value or a range, or a
    filter with no `ports` restriction at all (reaches every port)."""
    out = []
    for p in policies:
        f = (p.get("destination") or {}).get("filter") or {}
        ports = f.get("ports")
        if not ports:
            out.append(p)
            continue
        hit = _port_hits(ports.get("items"), str(port))
        if ports.get("match_opposite"):
            hit = not hit
        if hit:
            out.append(p)
    return out


def _enabled(p):
    e = p.get("enabled")
    if isinstance(e, str):
        return e.lower() == "true"
    return bool(e)


def _initiating_states(p):
    """connection_states as a set; empty = any state (can open connections)."""
    return set(str(x).upper() for x in (p.get("connection_states") or []))


def _covers(block, allow):
    """True when `block` matches a superset of what `allow` matches (same zone pair assumed).
    Conservative: any narrowing on the block side (source filter, destination ip filter,
    schedule, a connection-state restriction the allow does not share) means no cover."""
    if (block.get("source") or {}).get("filter"):
        return False
    bf = (block.get("destination") or {}).get("filter") or {}
    if bf and bf.get("kind") not in (None, "", "port"):
        return False
    if block.get("schedule"):
        return False
    bs, as_ = _initiating_states(block), _initiating_states(allow)
    if bs and not (as_ and as_ <= bs):
        return False
    return True


def governance_unshadowed(allows, policies, port):
    """Drop allow policies that are shadowed by an enabled Block/Reject for the same zone pair
    that reaches the port, is evaluated earlier (lower index), and matches a SUPERSET of the
    allow's traffic (a single-host or INVALID-only block does not excuse an Allow-All)."""
    blocks = [p for p in policies if str(p.get("action") or "").lower() in ("block", "reject") and _enabled(p)]
    blocks = governance_port_match(blocks, port)
    out = []
    for a in allows:
        src = (a.get("source") or {}).get("zone_id")
        dst = (a.get("destination") or {}).get("zone_id")
        idx = a.get("index", 0) or 0
        shadowed = any(
            (b.get("source") or {}).get("zone_id") == src
            and (b.get("destination") or {}).get("zone_id") == dst
            and (b.get("index", 0) or 0) < idx
            and _covers(b, a)
            for b in blocks
        )
        if not shadowed:
            out.append(a)
    return out


class FilterModule:
    def filters(self):
        return {
            "governance_list": governance_list,
            "governance_allowing": governance_allowing,
            "governance_port_match": governance_port_match,
            "governance_unshadowed": governance_unshadowed,
        }
