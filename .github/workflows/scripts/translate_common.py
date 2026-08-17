#!/usr/bin/env python3
"""Shared helpers for the vllm-ascend-recipes EN→ZH translation pipeline.

This module is imported by detect_yaml_changes.py, yaml_translate.py and
apply_translations.py (all three live in the same directory, so Python's
script-dir-on-sys.path makes ``import translate_common`` work).

It centralises the pieces that must stay consistent across the three stages:

- path representation: every translatable leaf is addressed by a *path tuple*,
  a sequence of ``('k', name)`` / ``('i', index)`` segments, plus a canonical
  string form (``scenarios[0].steps[0].content``) used as JSON keys.
- the translatable-field allowlist (deny-by-default), parsed from
  yaml_translate_fields.json.
- YAML loading (round-trip for en, safe for read-only zh).
- the translation memory layout under models/translations/**.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from ruamel.yaml import YAML
from ruamel.yaml.scalarstring import LiteralScalarString

# --- Paths -----------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent.parent
EN_DIR = REPO_ROOT / "models" / "en"
ZH_DIR = REPO_ROOT / "models" / "zh"
MEM_DIR = REPO_ROOT / "models" / "translations"
FIELDS_FILE = SCRIPT_DIR / "yaml_translate_fields.json"


# --- YAML instances --------------------------------------------------------

# Round-trip: preserves comments, key order and scalar styles. Used to rebuild
# the zh mirror from the en file with minimal diff.
RT = YAML(typ="rt")
RT.preserve_quotes = True
RT.width = 4096

# Safe: plain dict/list/str, used for read-only inspection of the zh mirror.
SAFE = YAML(typ="safe")


def load_yaml_safe(path: Path):
    with open(path, encoding="utf-8") as fh:
        return SAFE.load(fh)


def load_yaml_rt(path: Path):
    with open(path, encoding="utf-8") as fh:
        return RT.load(fh)


def dump_yaml_rt(data, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        RT.dump(data, fh)


# --- JSON helpers ----------------------------------------------------------

def load_json(path: Path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


# --- Field allowlist -------------------------------------------------------

def load_patterns(fields_file: Path = FIELDS_FILE) -> list[list[tuple[str, str | None]]]:
    """Load and parse the translatable-field patterns.

    Each pattern string is parsed into a list of segments: ``('k', name)`` for a
    literal map key, ``('k', None)`` for any map key (``*``), ``('i', None)``
    for any list index (``[]``).
    """
    raw = load_json(fields_file)
    patterns = []
    for pat in raw.get("patterns", []):
        segs: list[tuple[str, str | None]] = []
        for tok in pat.split("."):
            if tok == "*":
                segs.append(("k", None))
            elif tok.endswith("[]"):
                segs.append(("k", tok[:-2]))
                segs.append(("i", None))
            else:
                segs.append(("k", tok))
        patterns.append(segs)
    return patterns


# --- Path tuples -----------------------------------------------------------

def iter_leaves(node, prefix: tuple = ()):
    """Yield (path_tuple, value) for every string leaf in *node*."""
    if isinstance(node, dict):
        for k, v in node.items():
            yield from iter_leaves(v, prefix + (("k", k),))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from iter_leaves(v, prefix + (("i", i),))
    elif isinstance(node, str):
        yield prefix, node


def path_to_str(segments) -> str:
    """Render a path tuple as a canonical JSON-style string key."""
    s = ""
    for seg in segments:
        if seg[0] == "k":
            if s:
                s += "."
            s += seg[1]
        else:
            s += f"[{seg[1]}]"
    return s


def match_path(path_tuple: tuple, pattern_segs: list[tuple[str, str | None]]) -> bool:
    """Return True if *path_tuple* matches *pattern_segs*."""
    if len(path_tuple) != len(pattern_segs):
        return False
    for (ct, cv), (pt, pv) in zip(path_tuple, pattern_segs):
        if pt == "k":
            if pv is None:  # any key
                if ct != "k":
                    return False
            else:
                if ct != "k" or cv != pv:
                    return False
        else:  # 'i' — any index
            if ct != "i":
                return False
    return True


def extract_translatable(data, patterns):
    """Return a list of (path_tuple, path_str, en_text) for translatable leaves."""
    entries = []
    for path, val in iter_leaves(data):
        if not val or not val.strip():
            continue
        for psegs in patterns:
            if match_path(path, psegs):
                entries.append((path, path_to_str(path), val))
                break
    return entries


# --- Translation memory ----------------------------------------------------

def memory_path_for(en_path: Path) -> Path:
    rel = en_path.relative_to(EN_DIR)
    return MEM_DIR / rel.with_suffix(".json")


def zh_path_for(en_path: Path) -> Path:
    rel = en_path.relative_to(EN_DIR)
    return ZH_DIR / rel


def load_memory(mem_path: Path) -> dict:
    if not mem_path.exists():
        return {}
    return load_json(mem_path)


def save_memory(mem_path: Path, data: dict) -> None:
    write_json(mem_path, data)


# --- ruamel in-place update ------------------------------------------------

def set_path(root, path_tuple: tuple, value: str) -> None:
    """Set the leaf addressed by *path_tuple* in a ruamel round-trip tree."""
    node = root
    for seg in path_tuple[:-1]:
        node = node[seg[1]]
    last = path_tuple[-1]
    if "\n" in value:
        value = LiteralScalarString(value)
    node[last[1]] = value


# --- Structural integrity --------------------------------------------------

# The integrity check guards only the *machine-consumed* tokens that must never
# be localised: Jinja-style placeholders ({{max_num_seqs}}), config markers
# (%%CONFIG:key%% ... %%/CONFIG:key%%), and fenced code block count parity.
#
# Deliberately NOT checked (humans legitimately localise these, and the LLM is
# told to too): URLs (en → zh-cn doc links), and code-block *contents* (shell
# comments are prose and may be translated).
_PLACEHOLDER_RE = re.compile(r"\{\{[^{}]*\}\}")
_CONFIG_RE = re.compile(r"%%[A-Za-z0-9_:\-/]+%%")


def protected_tokens(text: str) -> list[str]:
    """Return machine-consumed tokens that must survive translation verbatim."""
    tokens: list[str] = []
    tokens.extend(_PLACEHOLDER_RE.findall(text))
    tokens.extend(_CONFIG_RE.findall(text))
    return tokens


def check_integrity(en: str, zh: str) -> tuple[bool, list[str]]:
    """Return (ok, missing): placeholders/markers absent from zh, or fence imbalance."""
    missing = [t for t in protected_tokens(en) if t not in zh]
    if en.count("```") != zh.count("```"):
        missing.append("<fence-count-mismatch>")
    return (not missing, missing)
