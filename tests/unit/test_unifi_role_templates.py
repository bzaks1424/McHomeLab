"""Static checks on roles/unifi/tasks/main.yml. No Ansible runtime, no controller.

Why static rather than a rendered run: the unifi role's modules shell out to `unifly`,
which reads a local profile pointing at the REAL controller. Adding a `unifi:` block to
the test inventory so `make check` exercised these tasks would make `make check` talk
to production, so the coverage has to come from reading the file instead.

This exists because of a live failure. `values: "{{ setting.values }}"` reached the lab
and site.yml failed with:

    Error while resolving value for 'values': Error rendering template:
    Type 'method' is unsupported for variable storage

Jinja resolves dotted access as an attribute BEFORE a mapping key, so `setting.values`
returned the dict method `values()`. The message names the symptom and not the cause,
and no unit test of the module could have caught it: the module's logic was fine and
the wiring was wrong.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
TASKS = ROOT / "ansible" / "roles" / "unifi" / "tasks" / "main.yml"

# dict attributes that shadow a plausible inventory key. `values` is the one that bit;
# the rest are the same trap with a different name.
SHADOWED = ("values", "items", "keys", "get", "copy", "update", "pop", "clear")

# `{{ foo.values }}` / `{{ foo.values | ... }}` — dotted access to a shadowed name.
DOTTED = re.compile(
    r"\{\{[^}]*?\b[A-Za-z_][A-Za-z0-9_]*\.(%s)\b" % "|".join(SHADOWED)
)


def test_no_dotted_access_to_shadowed_dict_attributes():
    text = TASKS.read_text()
    hits = []
    for n, line in enumerate(text.splitlines(), 1):
        m = DOTTED.search(line)
        if m:
            hits.append("%s:%d: %s" % (TASKS.name, n, line.strip()))
    assert not hits, (
        "Dotted access to a dict method inside a Jinja expression. Jinja resolves the "
        "attribute before the mapping key, so this yields the METHOD, not your value, "
        "and Ansible fails with \"Type 'method' is unsupported for variable storage\". "
        "Use subscripts: setting['values']. Found:\n  " + "\n  ".join(hits)
    )


def test_the_regression_pattern_is_actually_detected():
    """A guard that cannot fail is not a guard. Prove the matcher fires on the exact
    line that broke site.yml, so this test cannot rot into a no-op."""
    broke_the_lab = '    values: "{{ setting.values }}"'
    assert DOTTED.search(broke_the_lab)
    assert not DOTTED.search('    values: "{{ setting[\'values\'] }}"')
    assert not DOTTED.search('    key: "{{ setting[\'key\'] }}"')


def test_settings_task_still_wired():
    """If the task is renamed or removed, this file's premise is gone and it should be
    revisited rather than silently passing on a file that no longer does the work."""
    text = TASKS.read_text()
    assert "mhl_unifi_setting:" in text
    assert "unifi_settings" in text
