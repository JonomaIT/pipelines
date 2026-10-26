#!/usr/bin/env python3
"""Checks an app's deploy/ against the app contract (ADR-014), before anything runs.

The runners load deploy/ files with -var-file, and Terraform only *warns* about a value it does not
declare. So a field the app may not set (allow_destroy, zone, ...) or a typo (cpus = 4) would be
silently ignored. This check refuses both, with a message that says what to do:

  - every top-level key of deploy/app.hcl, deploy/env/*.tfvars and deploy/data.hcl must be part of
    the contract of the app's runtime (contract/schema.json);
  - values the platform decides are refused by name; renamed fields give the new name;
  - name must be the repo name (ADR-005), runtime must have a runner.

    python3 contract/check.py --repo-name svc-vendas path/to/app-repo

Standard library only: it runs in any CI image.
"""

import argparse
import fnmatch
import json
import os
import re
import sys
from pathlib import Path

SCHEMA = json.loads((Path(__file__).parent / "schema.json").read_text(encoding="utf-8"))
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")


def top_level(text):
    """Top-level assignments of an HCL variables file: {key: string value or None}.

    Walks the text once, tracking strings, comments, heredocs and bracket depth, so keys inside
    maps and objects (slo = { availability = ... }) are never taken for fields.
    """
    keys, depth, i, n = {}, 0, 0, len(text)
    at_line_start = True
    while i < n:
        c = text[i]
        if c == "\n":
            at_line_start, i = True, i + 1
            continue
        if c in " \t\r":
            i += 1
            continue
        if c == "#" or text.startswith("//", i):
            i = text.find("\n", i)
            i = n if i < 0 else i
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        if text.startswith("<<", i):  # heredoc: skip to its closing marker
            m = re.match(r"<<-?\s*([A-Za-z_][A-Za-z0-9_]*)", text[i:])
            if m:
                end = re.search(rf"^\s*{m.group(1)}\s*$", text[i + m.end():], re.M)
                i = n if not end else i + m.end() + end.end()
                continue
        if c == '"':
            i = skip_string(text, i)
            at_line_start = False
            continue
        if c in "{[(":
            depth, i, at_line_start = depth + 1, i + 1, False
            continue
        if c in "}])":
            depth, i, at_line_start = max(0, depth - 1), i + 1, False
            continue
        if depth == 0 and at_line_start:
            m = IDENT.match(text, i)
            if m:
                rest = text[m.end():]
                eq = re.match(r"[ \t]*=(?!=)[ \t]*", rest)
                if eq:
                    value_start = m.end() + eq.end()
                    keys[m.group(0)] = string_value(text, value_start)
                    i, at_line_start = value_start, False
                    continue
        i, at_line_start = i + 1, False
    return keys


def skip_string(text, i):
    i += 1
    while i < len(text) and text[i] != '"':
        i += 2 if text[i] == "\\" else 1
    return i + 1


def string_value(text, i):
    if i < len(text) and text[i] == '"':
        end = skip_string(text, i)
        return text[i + 1:end - 1]
    return None


def check(repo, repo_name):
    errors = []
    app_file = repo / "deploy" / "app.hcl"
    if not app_file.is_file():
        return ["deploy/app.hcl not found: every app declares at least runtime and name (Contrato da app)."]

    app = top_level(app_file.read_text(encoding="utf-8"))
    runtime = app.get("runtime")
    contract = SCHEMA["runtimes"].get(runtime or "")
    if contract is None:
        known = ", ".join(sorted(SCHEMA["runtimes"]))
        return [f'deploy/app.hcl: runtime = "{runtime}" has no runner: use one of {known}.']

    if app.get("name") != repo_name:
        errors.append(f'deploy/app.hcl: name = "{app.get("name")}" must be the repo name, "{repo_name}" (ADR-005).')

    files = sorted(p for p in (repo / "deploy").rglob("*") if p.is_file() and p.suffix in (".hcl", ".tfvars"))
    for path in files:
        rel = path.relative_to(repo).as_posix()
        if rel.startswith("deploy/k8s/"):
            continue
        allowed = next((keys for pattern, keys in contract.items() if fnmatch.fnmatch(rel, pattern)), None)
        if allowed is None:
            errors.append(f"{rel}: not part of the {runtime} contract (expected {', '.join(sorted(contract))}).")
            continue
        for key in top_level(path.read_text(encoding="utf-8")):
            if key in allowed:
                continue
            if key in SCHEMA["platform"]:
                errors.append(f"{rel}: {key} is set by the platform, not by the app: remove it (ADR-014).")
            elif key in SCHEMA["renamed"]:
                errors.append(f"{rel}: {key} was renamed to {SCHEMA['renamed'][key]} (contract v2).")
            else:
                errors.append(f"{rel}: {key} is not part of the {runtime} contract (accepted here: {', '.join(allowed)}).")
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("repo", nargs="?", default=".", help="app repo root (default: current directory)")
    parser.add_argument("--repo-name", required=True, help="the repo's name, which the app's name must match")
    args = parser.parse_args(argv)

    errors = check(Path(args.repo), args.repo_name)
    prefix = "::error::" if os.environ.get("GITHUB_ACTIONS") else ""  # annotations on the PR
    for error in errors:
        print(f"{prefix}{error}")
    if not errors:
        print("deploy/ follows the app contract.")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
