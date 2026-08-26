"""Load Ansible filter plugins and scripts modules by path (no Ansible runtime needed)."""
import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PLUGINS = ROOT / "ansible" / "filter_plugins"
SCRIPTS = ROOT / "scripts"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def plugin(name):
    return load(f"fp_{name}", PLUGINS / f"{name}.py")


def script_module(name):
    return load(name, SCRIPTS / f"{name}.py")
