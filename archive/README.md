# archive/

Retired code, kept for provenance. Nothing here is loaded by `site.yml` or lint.

| Path | Retired | Why | Superseded by |
|---|---|---|---|
| `roles/uisp` | 2026-08-25 | Installer execution was commented out; `_uisp_installer_args` Jinja was syntactically invalid (failed `ansible-lint` at `production`). UISP on the `unifi` VM was installed by hand. | Decision Q6 (`research/RESEARCH_SYSADMIN_AGENT.md` §9): UISP is an observed component with backup capture, not a declared install. |
| `roles/unifi-os` | 2026-08-25 | Run + systemd-enable steps were commented out; UniFi OS Server was installed by hand. | Same as above. |
| `host-tasks/configure_container_docker.yml` | 2026-08-25 | BTF target for `provision.type: container` — no inventory host uses it. | Nothing; re-add from here if a container-type host ever returns. |

The `unifi` host's `software:` keys referencing these roles are removed from
the inventory in the same change set.
