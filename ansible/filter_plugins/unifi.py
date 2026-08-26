"""UniFi-as-code helpers (Phase 5)."""


def unifi_diff(desired, current):
    """Keys of `desired` whose value differs from `current` (missing counts as different)."""
    return [k for k, v in desired.items() if current.get(k, object()) != v]


class FilterModule(object):
    def filters(self):
        return {"unifi_diff": unifi_diff}
