"""Custom Jinja2 filters for registry lookups."""


class FilterModule:
    """Registry filter plugins for safe value access."""

    def filters(self):
        return {
            'registry_get': self.registry_get,
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
