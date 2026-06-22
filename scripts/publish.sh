#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026, UAB Kurokesu
#
# Build a signed, per-suite apt index from the ingested .debs and assemble the
# publish tree (dists/ + pool/) that becomes the Pages artifact. Stateless: the
# aptly DB and publish dir are rebuilt from scratch every run.
#
# Signing: set ARCHIVE_GPG_SIGNING_KEY (the signing subkey) to sign. The key id is
# derived at run time. SKIP_SIGNING=1 builds an unsigned tree for local structural
# inspection only, which apt cannot use.

# shellcheck source=scripts/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmds aptly gpg dpkg dpkg-deb

START_TS=$(date +%s)
SKIP_SIGNING="${SKIP_SIGNING:-0}"
APTLY_CONFIG="$REPO_ROOT/aptly.conf"

aptly() { command aptly -config="$APTLY_CONFIG" "$@"; }

# aptly resolves its rootDir and the publish endpoint relative to cwd.
cd "$REPO_ROOT" || die "cannot cd to $REPO_ROOT"

[ -d "$STAGING_DIR" ] || die "no staging dir ($STAGING_DIR), run ingest.sh first"

read -ra SUITES <<< "$(mf_suites)"
[ "${#SUITES[@]}" -gt 0 ] || die "manifest lists no suites"

component=$(mf_component)
origin=$(mf_origin)

# Cross-suite version-inversion guard. Suites are oldest to newest in
# defaults.suites order. For any binary package in more than one suite, an older
# suite must not sort ABOVE a newer one (equal is fine, e.g. an arch:all package
# built once). Versions are read from the ingested .debs, not the manifest.
group_begin "version-inversion guard"
declare -A PKG_VER PKG_SEEN
for suite in "${SUITES[@]}"; do
  shopt -s nullglob
  for deb in "$STAGING_DIR/$suite"/*.deb; do
    p=$(dpkg-deb -f "$deb" Package)
    PKG_VER["$p|$suite"]=$(dpkg-deb -f "$deb" Version)
    PKG_SEEN["$p"]=1
  done
done
for p in "${!PKG_SEEN[@]}"; do
  for ((i = 0; i < ${#SUITES[@]}; i++)); do
    lo="${PKG_VER["$p|${SUITES[i]}"]:-}"
    [ -n "$lo" ] || continue
    for ((j = i + 1; j < ${#SUITES[@]}; j++)); do
      hi="${PKG_VER["$p|${SUITES[j]}"]:-}"
      [ -n "$hi" ] || continue
      if dpkg --compare-versions "$lo" gt "$hi"; then
        die "version inversion: $p ${SUITES[i]} ($lo) sorts above ${SUITES[j]} ($hi)"
      fi
    done
  done
done
group_end

# Signing setup.
keyargs=()
if [ "$SKIP_SIGNING" = 1 ]; then
  warn "SKIP_SIGNING=1: building UNSIGNED indices (not usable by apt)"
  keyargs=(-skip-signing)
else
  GNUPGHOME=$(mktemp -d)
  export GNUPGHOME
  trap 'gpgconf --kill all 2>/dev/null || true; rm -rf "$GNUPGHOME"' EXIT
  if [ -n "${ARCHIVE_GPG_SIGNING_KEY:-}" ]; then
    printf '%s' "$ARCHIVE_GPG_SIGNING_KEY" | gpg --batch --quiet --no-greeting --import || true
  fi
  mapfile -t keyids < <(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1=="ssb" && $12~/s/ {print $5}')
  if [ "${#keyids[@]}" -ne 1 ]; then
    die "expected exactly one signing subkey, found: ${keyids[*]:-none} (set ARCHIVE_GPG_SIGNING_KEY, or SKIP_SIGNING=1 for local inspection)"
  fi
  keyid="${keyids[0]}"
  keyargs=(-gpg-key="$keyid" -batch)
  log "Signing with subkey $keyid"
fi

# Stateless rebuild.
rm -rf "$REPO_ROOT/.aptly" "$PUBLISH_DIR"
mkdir -p "$PUBLISH_DIR"

for suite in "${SUITES[@]}"; do
  staged="$STAGING_DIR/$suite"
  shopt -s nullglob
  debs=( "$staged"/*.deb )
  [ "${#debs[@]}" -gt 0 ] || die "no staged .debs for $suite"
  arches=$(manifest architectures --suite "$suite" | tr ' ' ',')
  [ -n "$arches" ] || die "no architectures resolved for $suite"
  repo="kurokesu-$suite"

  group_begin "publish $suite [$arches]"
  aptly repo create -distribution="$suite" -component="$component" "$repo" >/dev/null
  aptly repo add "$repo" "$staged" >/dev/null
  # -architectures cannot change on an existing published distribution, which is
  # fine here because each run drops and re-publishes the whole tree.
  aptly publish repo \
    -architectures="$arches" \
    -acquire-by-hash \
    -origin="$origin" \
    -distribution="$suite" \
    -component="$component" \
    "${keyargs[@]}" \
    "$repo" "filesystem:pages:"
  group_end
done

# aptly leaves dangling by-hash convenience symlinks (Packages/Release/Contents
# names) whose targets are written relative to the publish root. apt fetches the
# real by-hash/<algo>/<hash> files, never these, and a dereferencing tar
# (upload-pages-artifact) aborts on the broken links. Drop them for a clean,
# static-servable tree.
find "$PUBLISH_DIR" -xtype l -delete

# Origin assertion. The customer pin (Pin: release o=Kurokesu, Priority 1001)
# fails OPEN if Origin is absent or misspelled, so customers drift back to stock.
# Never deploy a tree missing it.
for suite in "${SUITES[@]}"; do
  rel="$PUBLISH_DIR/dists/$suite/Release"
  [ -f "$rel" ] || die "missing $rel after publish"
  grep -q "^Origin: ${origin}\$" "$rel" \
    || die "Origin: ${origin} missing in dists/$suite/Release (customer pin would fail open)"
done
log "Origin: ${origin} present in all ${#SUITES[@]} suite Release file(s)"

# Human-facing root: landing page, setup.sh and the public signing key, served at
# stable URLs for the documented install flow. apt only fetches dists/ and pool/,
# so anything else at the root is invisible to it.
[ -f "$KEYRING" ] || die "missing signing keyring $KEYRING (needed to serve the public key)"
[ -d "$REPO_ROOT/site" ] || die "missing $REPO_ROOT/site (landing page)"
[ -f "$REPO_ROOT/setup.sh" ] || die "missing $REPO_ROOT/setup.sh (customer bootstrap)"
cp -a "$REPO_ROOT/site/." "$PUBLISH_DIR/"
cp "$REPO_ROOT/setup.sh" "$PUBLISH_DIR/setup.sh"
cp "$KEYRING" "$PUBLISH_DIR/kurokesu-archive-keyring.gpg"

[ -f "$PUBLISH_DIR/index.html" ] || die "landing page missing at $PUBLISH_DIR/index.html"
log "Root extras: landing page + setup.sh + kurokesu-archive-keyring.gpg"

# Instrumentation: tree size + run duration, echoed to the job summary so the
# eventual Pages -> self-host migration trigger is data, not a guess.
duration=$(( $(date +%s) - START_TS ))
tree_size=$(du -sh "$PUBLISH_DIR" 2>/dev/null | cut -f1 || echo n/a)
pool_size=$(du -sh "$PUBLISH_DIR/pool" 2>/dev/null | cut -f1 || echo n/a)
log "Published tree: ${tree_size} (pool: ${pool_size}) in ${duration}s"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### APT publish"
    echo
    echo "| metric | value |"
    echo "| --- | --- |"
    echo "| suites | ${SUITES[*]} |"
    echo "| published tree | ${tree_size} |"
    echo "| pool | ${pool_size} |"
    echo "| duration | ${duration}s |"
  } >> "$GITHUB_STEP_SUMMARY"
fi

log "Publish complete -> $PUBLISH_DIR"
