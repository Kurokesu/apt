# Shared helpers for the Kurokesu APT archive scripts.
# Source this from ingest.sh / publish.sh: . "$(dirname "$0")/common.sh"
# Not executable on its own.
# shellcheck shell=bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
MANIFEST="$REPO_ROOT/manifest.yml"
# shellcheck disable=SC2034  # consumed by sourcing scripts (ingest.sh)
KEYRING="$REPO_ROOT/keys/kurokesu-archive-keyring.gpg"

# Work directories
WORK_DIR="${WORK_DIR:-$REPO_ROOT/work}"
STAGING_DIR="${STAGING_DIR:-$WORK_DIR/staging}"   # extracted .debs, per suite
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$WORK_DIR/download}" # fetched tarballs + checksums
PUBLISH_DIR="${PUBLISH_DIR:-$REPO_ROOT/publish}"   # assembled tree -> Pages artifact

# Logging. Emits GitHub Actions annotations when running under CI.
_in_ci() { [ -n "${GITHUB_ACTIONS:-}" ]; }

log()  { printf '%s\n' "==> $*" >&2; }
warn() { if _in_ci; then printf '::warning::%s\n' "$*" >&2; else printf 'WARN: %s\n' "$*" >&2; fi; }
die()  { if _in_ci; then printf '::error::%s\n' "$*" >&2; else printf 'ERROR: %s\n' "$*" >&2; fi; exit 1; }

group_begin() { if _in_ci; then printf '::group::%s\n' "$*"; else printf '%s\n' "--- $*" >&2; fi; }
group_end()   { if _in_ci; then printf '::endgroup::\n'; fi; }

require_cmds() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { warn "missing required command: $c"; missing=1; }
  done
  [ "$missing" -eq 0 ] || die "install the missing commands above and retry"
}

# Manifest accessors (thin wrappers over scripts/manifest.py).
manifest()      { python3 "$SCRIPTS_DIR/manifest.py" "$@" --manifest "$MANIFEST"; }
mf_plan()       { manifest plan; }
mf_suites()     { manifest suites; }
mf_arches()     { manifest architectures; }
mf_origin()     { manifest origin; }
mf_component()  { manifest component; }
