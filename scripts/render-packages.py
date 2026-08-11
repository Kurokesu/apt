#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026, UAB Kurokesu
"""Render the served package list into the published landing page.

Splices an HTML list parsed from the published Packages indexes between the
packages markers of the index.html copy in the publish tree, and stamps the
footer year between the year markers. The file in git keeps only the markers,
so the content cannot drift or be hand-edited. Fails when markers are missing
or nothing parses.

Usage:
  render-packages.py --publish-dir publish --component main --suites "bookworm trixie"
"""

import argparse
import html
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def die(msg):
    sys.exit(f"render-packages.py: {msg}")


def splice(text, name, content, page):
    begin = f"<!-- {name}:begin -->"
    end = f"<!-- {name}:end -->"
    if begin not in text or end not in text:
        die(f"{name} markers missing in {page}")
    before, _, rest = text.partition(begin)
    _, _, after = rest.partition(end)
    return before + begin + content + end + after


def newer(version, than):
    """dpkg ordering, so a suite serving several versions headlines the highest."""
    return subprocess.call(["dpkg", "--compare-versions", version, "gt", than]) == 0


def parse_packages(path):
    """Parse RFC822-style Packages stanzas into a list of field dicts."""
    stanzas = []
    fields = {}
    key = None
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            if fields:
                stanzas.append(fields)
            fields = {}
            key = None
        elif line[0] in " \t":
            # Multi-line field continuation, only the synopsis is rendered.
            if key:
                fields[key] += "\n" + line.strip()
        else:
            key, _, value = line.partition(":")
            fields[key] = value.strip()
    if fields:
        stanzas.append(fields)
    return stanzas


def collect(publish_dir, component, suites):
    """Map package name to description, homepage and per-suite versions."""
    packages = {}
    for suite in suites:
        indexes = sorted((publish_dir / "dists" / suite / component).glob("binary-*/Packages"))
        if not indexes:
            die(f"no Packages index under dists/{suite}/{component}")
        for index in indexes:
            for stanza in parse_packages(index):
                name = stanza.get("Package")
                if not name:
                    die(f"stanza without a Package field in {index}")
                version = stanza.get("Version")
                if not version:
                    die(f"{name} stanza without a Version field in {index}")
                entry = packages.setdefault(
                    name, {"description": "", "homepage": "", "versions": {}}
                )
                served = entry["versions"].get(suite)
                if served and not newer(version, served):
                    continue
                entry["versions"][suite] = version
                entry["description"] = stanza.get("Description", "").splitlines()[0]
                entry["homepage"] = stanza.get("Homepage", "")
    if not packages:
        die("no packages parsed from the published indexes")
    return packages


def display_version(version):
    """GitHub-release style: strip epoch and revision, map ~ to -, prefix v."""
    v = version.split(":", 1)[-1].rsplit("-", 1)[0]
    return "v" + v.replace("~", "-")


def render(packages, suites):
    blocks = []
    for name in sorted(packages):
        entry = packages[name]
        served = entry["versions"]
        present = [suite for suite in suites if suite in served]
        mapped = {suite: display_version(served[suite]) for suite in present}
        # Suites are ordered oldest first and the publish version-inversion
        # guard keeps newer suites at or above older ones, so the newest suite
        # carries the headline version and older ones only annotate when they
        # lag after mapping.
        shown = mapped[present[-1]]
        lagging = [f"{s} still {mapped[s]}" for s in present[:-1] if mapped[s] != shown]
        if lagging:
            shown += " · " + ", ".join(lagging)
        full = ", ".join(f"{suite}: {served[suite]}" for suite in present)
        head = (
            f"<code>{html.escape(name)}</code> "
            f'<span class="pkg-ver" title="{html.escape(full, quote=True)}">{html.escape(shown)}</span>'
        )
        if entry["homepage"]:
            head += f' <a class="pkg-repo" href="{html.escape(entry["homepage"], quote=True)}">GitHub</a>'
        blocks.append(
            '<div class="pkg">'
            f'<div class="pkg-head">{head}</div>'
            f'<div class="hint">{html.escape(entry["description"])}</div>'
            "</div>"
        )
    return "\n".join(blocks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publish-dir", required=True, type=Path)
    parser.add_argument("--component", required=True)
    parser.add_argument("--suites", required=True, help="space-separated, oldest suite first")
    args = parser.parse_args()

    suites = args.suites.split()
    if not suites:
        die("--suites is empty")

    packages = collect(args.publish_dir, args.component, suites)
    table = render(packages, suites)

    page = args.publish_dir / "index.html"
    if not page.is_file():
        die(f"landing page missing at {page}")
    text = page.read_text(encoding="utf-8")
    text = splice(text, "packages", "\n" + table + "\n", page)
    text = splice(text, "year", str(datetime.now(timezone.utc).year), page)
    page.write_text(text, encoding="utf-8")
    print(f"render-packages.py: {len(packages)} package(s) across {len(suites)} suite(s) -> {page}")


if __name__ == "__main__":
    main()
