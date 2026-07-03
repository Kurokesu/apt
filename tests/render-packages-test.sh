#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026, UAB Kurokesu
#
# Dry-run render-packages.py against fixture indexes in the shape aptly
# publishes, hashes cut. They cover an arch:all DKMS package, a suite-arch
# package with an epoch and a ~bpo suffix on bookworm and a package whose
# suites serve different versions.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cp -a "$ROOT/tests/fixtures/dists" "$TMP/dists"
cp "$ROOT/site/index.html" "$TMP/index.html"

python3 "$ROOT/scripts/render-packages.py" \
  --publish-dir "$TMP" --component main --suites "bookworm trixie"

# The list replaced the placeholder and carries every fixture package.
grep -q '<code>ar0822-rpi-dkms</code>' "$TMP/index.html"
grep -q 'class="pkg-repo" href="https://github.com/Kurokesu/ar0822-rpi-driver"' "$TMP/index.html"
grep -q 'Onsemi AR0822 camera driver for Raspberry Pi (DKMS)' "$TMP/index.html"
# Same mapped version in both suites collapses to one bare entry.
grep -q '>v0.1.0<' "$TMP/index.html"
grep -q '>v0.7.1+rpt20260429+krks1<' "$TMP/index.html"
# Diverging suites annotate the lagging one.
grep -q '>v1.12.0+krks1 · bookworm still v1.11.0+krks1<' "$TMP/index.html"
# Hover keeps the exact served Debian versions, epoch and ~bpo included.
grep -q 'title="bookworm: 1:0.7.1+rpt20260429+krks1-4~bpo12+1, trixie: 1:0.7.1+rpt20260429+krks1-4"' "$TMP/index.html"
# The footer year is stamped at render time.
grep -q "year:begin -->$(date +%Y)<!-- year:end" "$TMP/index.html"
if grep -q 'generated when the archive is published' "$TMP/index.html"; then
  echo "FAIL: placeholder still present after render" >&2
  exit 1
fi

# Missing markers must fail the publish, not silently ship the page.
sed 's/<!-- packages:begin -->//' "$ROOT/site/index.html" > "$TMP/index.html"
if python3 "$ROOT/scripts/render-packages.py" \
  --publish-dir "$TMP" --component main --suites "bookworm trixie" 2>/dev/null; then
  echo "FAIL: renderer succeeded with the begin marker missing" >&2
  exit 1
fi

echo "render-packages-test: ok"
