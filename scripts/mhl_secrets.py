"""One definition of "a secret in a YAML file", shared by scripts/mhl-no-secrets
(the gate) and scripts/mhl-vault-file (the tool), so they can never disagree.

Model: the file is composed with PyYAML's BaseLoader (no implicit typing).
A candidate is a key in a MAPPING whose name ends in a secret word. Each
candidate is classified; the gate flags exactly the classes the tool must
either fix or refuse loudly, and the tool exits 0 only on classes the gate
does not flag.

  class          gate   tool                      meaning
  plain          FAIL   vault                     scalar value (plain/quoted), one line
  vaulted        pass   skip (exit 0)             already !vault
  ref            pass   skip (exit 0)             value is a {{ }} Jinja reference
  empty          pass   skip (exit 0)             `key:` with no value
  collection     pass   skip (exit 0)             key holds a mapping/sequence (e.g. `credentials:`)
  block_scalar   FAIL   refuse (exit 1, remedy)   `key: |` / `key: >` — vault by hand from a file
  multiline      FAIL   refuse (exit 1, remedy)   quoted scalar spanning lines
  flow           FAIL   refuse (exit 1, remedy)   key inside a flow mapping { }
  tag            FAIL   refuse (exit 1, remedy)   explicitly tagged value
  alias          FAIL   refuse (exit 1, remedy)   value is an alias/anchor
  complex_key    FAIL   refuse (exit 1, remedy)   `? key` form
  empty_quoted   FAIL   refuse (exit 1, remedy)   `key: ""` — set a value or remove the key
  (unparseable)  text   refuse (exit 1)           gate falls back to the line regex; tool refuses

A `password:` line INSIDE another key's block scalar is text, not a key: no
class, not flagged, not touched (round-5 Blocker A).
"""
import io
import re

import yaml

SECRET_WORDS = "pass|password|passwd|secret|token|api_?key|apikey|claim|private_key|preshared_key|credential"
KEY_RE = re.compile(r"^(?:[A-Za-z0-9._]*_)?(?i:" + SECRET_WORDS + r")$")
# Text fallback for files that do not parse (same words, line-shaped). Keep in
# sync with the table above: it flags a secret-named key with a non-!vault,
# non-{{ }}, non-empty, non-comment value.
LINE_RE = re.compile(r"^[ \t-]*(?:[A-Za-z0-9._]*_)?(?i:" + SECRET_WORDS + r")[ \t]*:[ \t]*(?!(!vault|\{\{|\"\{\{|'\{\{|$|#))\S")
GATE_FAILS = {"plain", "block_scalar", "multiline", "flow", "tag", "alias", "complex_key", "empty_quoted"}
TOOL_REFUSES = {"block_scalar", "multiline", "flow", "tag", "alias", "complex_key", "empty_quoted"}


class Finding:
    __slots__ = ("path", "key", "line", "cls", "key_node", "value_node")

    def __init__(self, path, key, line, cls, key_node=None, value_node=None):
        self.path, self.key, self.line, self.cls = path, key, line, cls
        self.key_node, self.value_node = key_node, value_node

    def __repr__(self):
        return f"{self.cls}:{self.key}@{self.line}"


def compose(text):
    """Return (node, None) for a single-document parse, or (None, reason)."""
    try:
        docs = list(yaml.compose_all(io.StringIO(text), Loader=yaml.BaseLoader))
    except yaml.MarkedYAMLError as e:
        mark = e.problem_mark or e.context_mark
        return None, f"not valid YAML (line {mark.line + 1 if mark else '?'})"
    except yaml.YAMLError:
        return None, "not valid YAML"
    if len(docs) != 1:
        return None, f"{len(docs)} YAML documents; exactly one is supported"
    return docs[0], None


def walk(node, path=()):
    if isinstance(node, yaml.MappingNode):
        for k, v in node.value:
            kp = path + (k.value if isinstance(k, yaml.ScalarNode) else "<complex-key>",)
            yield kp, node, k, v
            yield from walk(v, kp)
    elif isinstance(node, yaml.SequenceNode):
        for i, v in enumerate(node.value):
            yield from walk(v, path + (f"[{i}]",))


def classify(text, tree):
    """Ordered Findings for every secret-named key in the tree."""
    lines = text.split("\n")
    out = []
    for path, parent, k, v in walk(tree):
        if not isinstance(k, yaml.ScalarNode):
            # complex key: flag if the complex key itself names a secret anywhere
            continue
        if not KEY_RE.match(k.value):
            continue
        ln = k.start_mark.line + 1
        f = lambda cls: Finding(path, k.value, ln, cls, k, v)
        if parent.flow_style:
            out.append(f("flow")); continue
        if isinstance(v, (yaml.MappingNode, yaml.SequenceNode)):
            out.append(f("collection")); continue
        if not isinstance(v, yaml.ScalarNode):
            out.append(f("alias")); continue
        # explicit `? key` form: the key node starts at a '?' in the source
        kl = lines[k.start_mark.line] if k.start_mark.line < len(lines) else ""
        if kl[:k.start_mark.column].rstrip().endswith("?") or v.start_mark.line != k.start_mark.line and v.style not in ("|", ">", '"', "'"):
            out.append(f("complex_key")); continue
        if v.tag == "!vault":
            out.append(f("vaulted")); continue
        raw = lines[v.start_mark.line][v.start_mark.column:v.end_mark.column] if v.start_mark.line == v.end_mark.line else lines[v.start_mark.line][v.start_mark.column:]
        if raw.lstrip().startswith("!") or raw.lstrip().startswith("&") or raw.lstrip().startswith("*"):
            out.append(f("tag" if raw.lstrip().startswith("!") else "alias")); continue
        if v.style in ("|", ">"):
            out.append(f("block_scalar")); continue
        if v.value == "":
            out.append(f("empty" if v.style is None else "empty_quoted")); continue
        if v.start_mark.line != v.end_mark.line:
            out.append(f("multiline")); continue
        if v.value.startswith("{{"):
            out.append(f("ref")); continue
        out.append(f("plain"))
    return out


def scan_text_fallback(text):
    """Line-shaped findings for files that do not parse as YAML."""
    return [Finding((), m.group(0).split(":")[0].strip(" \t-"), i, "plain") for i, l in enumerate(text.split("\n"), 1) for m in [LINE_RE.match(l)] if m]


def gate_findings(text):
    """What the GATE reports for a file: (findings, note). Never returns values."""
    tree, err = compose(text)
    if tree is None:
        return [f for f in scan_text_fallback(text)], f"{err}; line scan used"
    return [f for f in classify(text, tree) if f.cls in GATE_FAILS], None
