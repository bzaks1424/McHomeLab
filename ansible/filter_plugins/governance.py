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


class FilterModule:
    def filters(self):
        return {"governance_list": governance_list, "governance_port_match": governance_port_match}
