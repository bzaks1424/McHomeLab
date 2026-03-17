"""Custom Jinja2 filters for registry and inventory lookups."""

from collections.abc import Mapping


class FilterModule:
    """Filter plugins for registry and inventory entry access."""

    def filters(self):
        return {
            'registry_get': self.registry_get,
            'inventory_entry': self.inventory_entry,
        }

    @staticmethod
    def registry_get(registry, key, default=None):
        """Safely get a value from the registry by key.

        Usage in templates/vars:
            {{ hostvars['localhost'].registry | registry_get('pxe_base_url') }}
            {{ hostvars['localhost'].registry | registry_get('pxe_base_url', 'fallback') }}

        Returns the 'value' field of the named registry entry,
        or default if the key doesn't exist.
        """
        if not isinstance(registry, dict):
            return default
        entry = registry.get(key)
        if entry is None:
            return default
        if isinstance(entry, dict):
            return entry.get('value', default)
        return default

    @staticmethod
    def inventory_entry(hostvars_entry, section, name, attribute, default=None, contains=None):
        """Look up an attribute from a named import or export entry in inventory.

        Usage in templates/vars:
            {{ hostvars[inventory_hostname] | inventory_entry('import', 'root_ca_cert', 'dest') }}
            {{ hostvars[inventory_hostname] | inventory_entry('export', 'root_ca_cert', 'src') }}
            {{ hostvars[inventory_hostname] | inventory_entry('import', 'root_ca_cert', 'dest',
                                                              contains='ca-certificates') }}

        Args:
            hostvars_entry: The hostvars dict for a single host.
            section: 'import' or 'export'.
            name: The 'name' field to match on.
            attribute: The attribute to extract from the matched entry.
            default: Value to return if not found.
            contains: Optional substring filter — only match entries where
                      the attribute value contains this string.

        Returns the attribute value from the first matching entry,
        or default if no match is found.
        """
        if not isinstance(hostvars_entry, Mapping):
            return default
        try:
            entries = hostvars_entry[section]
        except (KeyError, TypeError):
            return default
        if not isinstance(entries, list):
            return default
        for entry in entries:
            if isinstance(entry, dict) and entry.get('name') == name:
                value = entry.get(attribute, default)
                if contains is not None:
                    if isinstance(value, str) and contains in value:
                        return value
                    continue
                return value
        return default
