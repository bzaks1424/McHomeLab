"""Filters for compose secret delivery (service role)."""


def service_secret_entries(item):
    """dict2items entry {key: svc, value: {secrets: {...}, secret_style: ...}} ->
    [{service, name, style, value}] for each declared secret."""
    svc = item["key"]
    cfg = item["value"]
    style = cfg.get("secret_style", "lsio")
    return [{"service": svc, "name": k, "style": style, "value": v} for k, v in (cfg.get("secrets") or {}).items()]


def secret_env_name(name, style_map, style):
    if style not in style_map:
        raise ValueError(f"unknown secret_style {style!r} (known: {sorted(style_map)})")
    st = style_map[style]
    return f"{st['prefix']}{name}{st['suffix']}"


def api_value_equal(actual, want):
    """Type-aware equality for api_settings compares: 2 == 2.0 == "2", True == "true";
    otherwise string forms must match. Returns False when actual is missing (None)."""
    if actual is None:
        return False
    if isinstance(actual, bool) or isinstance(want, bool):
        return str(actual).lower() == str(want).lower()
    try:
        return float(actual) == float(want)
    except (TypeError, ValueError):
        return str(actual) == str(want)


class FilterModule:
    def filters(self):
        return {"service_secret_entries": service_secret_entries, "secret_env_name": secret_env_name,
                "api_value_equal": api_value_equal}
