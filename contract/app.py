#!/usr/bin/env python3
"""Describes how an app deploys to one account, read from its deploy/ files (for deploy-app).

    python3 contract/app.py --environment production path/to/app-repo

Prints JSON: runtime, name, regions (from deploy/env/<account>.tfvars; the first is the primary),
hosts, source_dir (cloudfront), data (deploy/data.hcl exists) and smoke (tests/smoke/*.hurl).
Run contract/check.py first: this only reads, it does not validate the contract.

Standard library only: it runs in any CI image.
"""

import argparse
import json
import re
import sys
from pathlib import Path

from check import top_level

DEFAULT_REGIONS = ["us-east-1"]  # the runners' default when an app does not list regions
DEFAULT_SOURCE_DIR = "site"  # the CloudFront runner's default


def string_list(text, key):
    """Strings of a top-level list (regions = ["us-east-1", "sa-east-1"]), or None if absent."""
    m = re.search(rf"^[ \t]*{re.escape(key)}[ \t]*=[ \t]*\[(.*?)\]", text, re.M | re.S)
    if not m:
        return None
    body = re.sub(r"(#|//).*", "", m.group(1))  # comments inside the list
    return re.findall(r'"([^"]*)"', body)


def describe(repo, environment):
    app_file = repo / "deploy" / "app.hcl"
    env_file = repo / "deploy" / "env" / f"{environment}.tfvars"
    if not app_file.is_file():
        raise SystemExit("deploy/app.hcl not found: every app declares at least runtime and name (Contrato da app).")
    if not env_file.is_file():
        raise SystemExit(f"deploy/env/{environment}.tfvars not found: the app does not run in {environment}.")

    app_text = app_file.read_text(encoding="utf-8")
    env_text = env_file.read_text(encoding="utf-8")
    app = top_level(app_text)

    def listed(key):
        value = string_list(env_text, key)
        return value if value is not None else string_list(app_text, key)

    return {
        "runtime": app.get("runtime"),
        "name": app.get("name"),
        "regions": listed("regions") or DEFAULT_REGIONS,
        "hosts": listed("hosts") or [],
        "source_dir": app.get("source_dir") or DEFAULT_SOURCE_DIR,
        "data": (repo / "deploy" / "data.hcl").is_file(),
        "smoke": sorted(p.relative_to(repo).as_posix() for p in (repo / "tests" / "smoke").glob("*.hurl")),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("repo", nargs="?", default=".", help="app repo root (default: current directory)")
    parser.add_argument("--environment", required=True, help="the account: deploy/env/<account>.tfvars")
    args = parser.parse_args(argv)
    print(json.dumps(describe(Path(args.repo), args.environment)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
