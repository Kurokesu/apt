#!/usr/bin/env python3
"""Parse and interpret conf/manifest.yml for the Kurokesu APT archive.

This is the single place that understands the manifest schema and derives asset
filenames, so the shell scripts (ingest.sh, publish.sh) and the CI workflow stay
free of hardcoded suites, architectures or filename conventions.

Subcommands:
  plan          TSV of ingest/publish units, one row per (release, suite, arch):
                source  repo  tag  version  suite  arch  component  origin  tarball
  suites        space-separated unique suites referenced by releases
  architectures space-separated architectures, union across units
                (restrict to one suite with --suite)
  origin        defaults.origin
  component     defaults.component
  validate      load + sanity-check the manifest (exit non-zero on error)
"""

import argparse
import os
import sys

try:
    import yaml
except ModuleNotFoundError:
    sys.exit("manifest.py: PyYAML is required (apt install python3-yaml / pip install pyyaml)")

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_MANIFEST = os.path.join(REPO_ROOT, "conf", "manifest.yml")


def die(msg):
    sys.exit(f"manifest.py: {msg}")


def require_str_list(value, where):
    """Validate that `value` is a non-empty list of non-empty strings."""
    if not isinstance(value, list) or not value:
        die(f"{where} must be a non-empty list")
    for item in value:
        if not isinstance(item, str) or not item:
            die(f"{where} must contain only non-empty strings")
    return value


def resolve_list(rel, source_cfg, defaults, key, idx):
    """Resolve a list-valued field with precedence: release > source > defaults.

    `source_cfg` and `defaults` values are already validated in load(). A release
    override is validated here on first use.
    """
    if key in rel:
        return require_str_list(rel[key], f"releases[{idx}].{key}")
    if key in source_cfg:
        return source_cfg[key]
    return defaults[key]


def load(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh)
    except FileNotFoundError:
        die(f"manifest not found: {path}")
    except yaml.YAMLError as exc:
        die(f"invalid YAML in {path}: {exc}")
    if not isinstance(data, dict):
        die("manifest top level must be a mapping")

    defaults = data.get("defaults") or {}
    sources = data.get("sources") or {}
    releases = data.get("releases") or []

    for key in ("architectures", "component", "origin", "suites"):
        if key not in defaults:
            die(f"defaults.{key} is required")
    require_str_list(defaults["architectures"], "defaults.architectures")
    require_str_list(defaults["suites"], "defaults.suites")
    if not isinstance(sources, dict) or not sources:
        die("sources must be a non-empty mapping")
    for name, cfg in sources.items():
        if not isinstance(cfg, dict):
            die(f"sources.{name} must be a mapping")
        repo = cfg.get("repo")
        if not repo or not isinstance(repo, str):
            die(f"sources.{name}.repo is required and must be a string")
        if "architectures" in cfg:
            require_str_list(cfg["architectures"], f"sources.{name}.architectures")
        if "suites" in cfg:
            require_str_list(cfg["suites"], f"sources.{name}.suites")

    if not isinstance(releases, list) or not releases:
        die("releases must be a non-empty list")
    for idx, rel in enumerate(releases):
        if not isinstance(rel, dict):
            die(f"releases[{idx}] must be a mapping")

    return defaults, sources, releases


def units(defaults, sources, releases):
    """Yield one dict per (release, suite, arch) with a derived tarball name."""
    suffixes = defaults.get("suite_suffix") or {}
    component = defaults["component"]
    origin = defaults["origin"]
    seen = set()
    for idx, rel in enumerate(releases):
        for key in ("source", "tag", "version"):
            if key not in rel:
                die(f"releases[{idx}].{key} is required")
        source = rel["source"]
        if source not in sources:
            die(f"releases[{idx}].source '{source}' is not declared under sources")
        source_cfg = sources[source]
        repo = source_cfg["repo"]
        tag = rel["tag"]
        if (source, tag) in seen:
            die(f"duplicate release {source} '{tag}' - edit the existing block in place, do not append")
        seen.add((source, tag))
        version = rel["version"]
        suites = resolve_list(rel, source_cfg, defaults, "suites", idx)
        arches = resolve_list(rel, source_cfg, defaults, "architectures", idx)
        for suite in suites:
            suffix = suffixes.get(suite, "")
            for arch in arches:
                tarball = f"{source}_{version}{suffix}_{suite}_{arch}.tar.gz"
                yield {
                    "source": source,
                    "repo": repo,
                    "tag": tag,
                    "version": version,
                    "suite": suite,
                    "arch": arch,
                    "component": component,
                    "origin": origin,
                    "tarball": tarball,
                }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["plan", "suites", "architectures", "origin", "component", "validate"])
    ap.add_argument("--manifest", default=DEFAULT_MANIFEST)
    ap.add_argument("--suite", help="restrict 'architectures' output to one suite")
    args = ap.parse_args()

    defaults, sources, releases = load(args.manifest)
    rows = list(units(defaults, sources, releases))

    if args.command == "validate":
        print(f"ok: {len(releases)} release(s), {len(rows)} ingest unit(s)")
    elif args.command == "plan":
        cols = ["source", "repo", "tag", "version", "suite", "arch", "component", "origin", "tarball"]
        for row in rows:
            print("\t".join(row[c] for c in cols))
    elif args.command == "suites":
        print(" ".join(dict.fromkeys(r["suite"] for r in rows)))
    elif args.command == "architectures":
        arch_rows = rows if args.suite is None else [r for r in rows if r["suite"] == args.suite]
        print(" ".join(dict.fromkeys(r["arch"] for r in arch_rows)))
    elif args.command == "origin":
        print(defaults["origin"])
    elif args.command == "component":
        print(defaults["component"])


if __name__ == "__main__":
    main()
