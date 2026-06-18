#!/usr/bin/env bash
# Download, verify and extract promoted release assets into a per-suite pool of
# .debs for publish.sh. conf/manifest.yml is the single source of truth.
#
# Per release tag: gh download SHA256SUMS(.asc), verify the signature against the
# shipped keyring, then per asset verify the checksum, extract and assert the .deb
# version matches the manifest.
#
# Pre-release gate: releases still marked pre-release are skipped unless
# ALLOW_PRERELEASE=1, which exists for local validation before promotion.

# shellcheck source=scripts/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_cmds gh gpgv sha256sum tar dpkg-deb

ALLOW_PRERELEASE="${ALLOW_PRERELEASE:-0}"

log "Resetting work directories"
rm -rf "$DOWNLOAD_DIR" "$STAGING_DIR"
mkdir -p "$DOWNLOAD_DIR" "$STAGING_DIR"

declare -A TAG_STATE   # "repo|tag" -> ok | skip
declare -A TAG_DIR     # "repo|tag" -> download dir
ingested=0

prepare_tag() {
  # Verify a release tag once. Sets TAG_STATE and TAG_DIR for "$repo|$tag".
  local source="$1" repo="$2" tag="$3" key="$4"
  group_begin "release $repo $tag"

  local is_pre
  is_pre=$(gh release view "$tag" --repo "$repo" --json isPrerelease --jq '.isPrerelease' 2>/dev/null || echo error)
  if [ "$is_pre" = error ]; then
    die "cannot read release $repo $tag (tag missing or release not published?)"
  fi
  if [ "$is_pre" = true ] && [ "$ALLOW_PRERELEASE" != 1 ]; then
    warn "skipping $repo $tag: still a pre-release (set ALLOW_PRERELEASE=1 to ingest for local validation)"
    TAG_STATE[$key]=skip
    group_end
    return
  fi

  local tdir
  tdir="$DOWNLOAD_DIR/${source}_$(printf '%s' "$tag" | tr -c 'A-Za-z0-9._-' '_')"
  mkdir -p "$tdir"
  gh release download "$tag" --repo "$repo" --dir "$tdir" \
    --pattern SHA256SUMS --pattern SHA256SUMS.asc --clobber
  gpgv --keyring "$KEYRING" "$tdir/SHA256SUMS.asc" "$tdir/SHA256SUMS" \
    || die "signature verification failed for $repo $tag"

  TAG_STATE[$key]=ok
  TAG_DIR[$key]="$tdir"
  group_end
}

# component and origin are plan columns consumed by publish.sh, not here.
# shellcheck disable=SC2034
while IFS=$'\t' read -r source repo tag version suite arch component origin tarball; do
  [ -n "$source" ] || continue
  key="$repo|$tag"
  [ -n "${TAG_STATE[$key]:-}" ] || prepare_tag "$source" "$repo" "$tag" "$key"
  [ "${TAG_STATE[$key]}" = ok ] || continue

  tdir="${TAG_DIR[$key]}"
  log "Ingesting $tarball ($suite/$arch)"
  gh release download "$tag" --repo "$repo" --dir "$tdir" --pattern "$tarball" --clobber
  ( cd "$tdir" && sha256sum -c --ignore-missing SHA256SUMS ) >/dev/null \
    || die "checksum verification failed for $tarball"

  exdir="$tdir/extract"
  rm -rf "$exdir"
  mkdir -p "$exdir"
  tar --no-same-owner -xzf "$tdir/$tarball" -C "$exdir"

  shopt -s nullglob
  debs=( "$exdir"/*.deb )
  [ "${#debs[@]}" -gt 0 ] || die "no .deb found in $tarball"

  dest="$STAGING_DIR/$suite"
  mkdir -p "$dest"
  for deb in "${debs[@]}"; do
    base=$(basename "$deb")
    # Safety net: source bundling drops -dbgsym, so one here is a source-side
    # regression. Skip it and warn rather than ship debug symbols to customers.
    case "$(dpkg-deb -f "$deb" Package)" in
      *-dbgsym)
        warn "$base: debug-symbol package in release, skipping (fix the source repo's release bundling)"
        continue ;;
    esac
    dv=$(dpkg-deb -f "$deb" Version)
    # trixie matches exactly, a backport build appends ~bpo... to the same base
    case "$dv" in
      "$version"|"$version"~*) : ;;
      *) die "version mismatch in $base: deb '$dv' vs manifest '$version'" ;;
    esac
    cp -f "$deb" "$dest/"
  done
  ingested=$((ingested + 1))
done < <(mf_plan)

[ "$ingested" -gt 0 ] \
  || die "nothing ingested (all releases pre-release? set ALLOW_PRERELEASE=1 for local validation)"

log "Ingested $ingested unit(s) into $STAGING_DIR"
