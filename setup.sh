#!/bin/sh
# Kurokesu APT archive setup.
#
# Enables the repository only: installs the signing key, writes the deb822
# source and the o=Kurokesu priority pin. It deliberately does NOT run
# `apt update` or install packages - a global apt update refreshes every
# configured repo and is a network side effect - it prints the next commands
# instead (pass --update to opt in to a refresh).
#
# Usage:
#   sudo sh setup.sh                  enable the repository
#   sudo sh setup.sh --update         enable, then refresh apt
#   sudo sh setup.sh --codename NAME  force the suite (bookworm|trixie)
#   sudo sh setup.sh --remove         remove the source, pin and key
#   sh setup.sh --help
#
# Re-run after an OS dist-upgrade to refresh the suite in the source list.
set -eu

ARCHIVE_URL="https://apt.kurokesu.com"
KEY_URL="${ARCHIVE_URL}/kurokesu-archive-keyring.gpg"
KEYRING="/etc/apt/keyrings/kurokesu-archive-keyring.gpg"
SOURCES="/etc/apt/sources.list.d/kurokesu.sources"
PREFS="/etc/apt/preferences.d/kurokesu.pref"
# The archive signing key; verify against the fingerprint at https://apt.kurokesu.com/
EXPECTED_FPR="63853998AD7195E43D2D4E833EBA33E5B4644D7A"

msg() { printf '%s\n' "$*"; }
die() { printf 'setup.sh: error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Kurokesu APT archive setup
  sudo sh setup.sh                  enable the repository
  sudo sh setup.sh --update         enable, then refresh apt
  sudo sh setup.sh --codename NAME  force the suite (bookworm|trixie)
  sudo sh setup.sh --remove         remove the source, pin and key
USAGE
}

download() { # download <dest> <url>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$1" "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$1" "$2"
  else
    die "need curl or wget"
  fi
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "must run as root (re-run with sudo)"
}

mode=enable
codename_override=""
while [ $# -gt 0 ]; do
  case "$1" in
    --update     ) mode=update ;;
    --remove     ) mode=remove ;;
    --codename   ) shift; codename_override="${1:-}"
                   [ -n "$codename_override" ] || die "--codename needs a value (bookworm or trixie)" ;;
    --codename=* ) codename_override="${1#--codename=}" ;;
    -h|--help    ) usage; exit 0 ;;
    *            ) die "unknown option '$1' (try --update, --codename, --remove, --help)" ;;
  esac
  shift
done

if [ "$mode" = remove ]; then
  require_root
  rm -f "$SOURCES" "$PREFS" "$KEYRING"
  msg "Removed the Kurokesu source, pin and key."
  msg "Run 'sudo apt update' to refresh apt's lists."
  exit 0
fi

require_root

# Supported targets only.
arch=$(dpkg --print-architecture 2>/dev/null || echo unknown)
[ "$arch" = arm64 ] || die "unsupported architecture '$arch' (need arm64 / a 64-bit OS)"

# Resolve the target suite: an explicit --codename wins, else /etc/os-release.
# Either way it must be a suite this archive actually serves.
if [ -n "$codename_override" ]; then
  codename="$codename_override"
else
  [ -r /etc/os-release ] || die "cannot read /etc/os-release (pass --codename bookworm|trixie)"
  # shellcheck source=/dev/null
  . /etc/os-release
  codename="${VERSION_CODENAME:-unknown}"
fi
case "$codename" in
  bookworm|trixie ) ;;
  * ) die "unsupported suite '$codename' (this archive serves bookworm and trixie; pass --codename to override)" ;;
esac

umask 022
install -d -m 0755 /etc/apt/keyrings

# 1. signing key: download to a temp file, then move into place atomically.
tmpkey=$(mktemp)
gpgtmp=""
trap 'rm -f "$tmpkey"; [ -n "$gpgtmp" ] && rm -rf "$gpgtmp"; true' EXIT
download "$tmpkey" "$KEY_URL" || die "failed to download key from $KEY_URL"
[ -s "$tmpkey" ] || die "downloaded key is empty"
install -m 0644 "$tmpkey" "$KEYRING"

# 2. deb822 source, scoped to this OS release.
cat > "$SOURCES" <<EOF
Types: deb
URIs: ${ARCHIVE_URL}
Suites: ${codename}
Components: main
Architectures: arm64
Signed-By: ${KEYRING}
EOF
chmod 0644 "$SOURCES"

# 3. pin: our origin wins for Kurokesu packages.
cat > "$PREFS" <<EOF
Package: *
Pin: release o=Kurokesu
Pin-Priority: 1001
EOF
chmod 0644 "$PREFS"

msg "Kurokesu archive enabled for ${codename} (arm64)."

# Echo the installed key fingerprint and check it against the expected one.
# gpg is optional (apt verifies via gpgv); run it in a throwaway home so it
# never creates /root/.gnupg as a side effect.
if command -v gpg >/dev/null 2>&1; then
  gpgtmp=$(mktemp -d)
  got=$(GNUPGHOME="$gpgtmp" gpg --show-keys --with-colons "$KEYRING" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')
  if [ -n "$got" ]; then
    msg ""
    msg "Signing key fingerprint (verify against https://apt.kurokesu.com/):"
    if [ "$got" = "$EXPECTED_FPR" ]; then
      msg "  $got  [matches expected]"
    else
      msg "  installed: $got"
      msg "  expected:  $EXPECTED_FPR"
      die "key fingerprint mismatch - refusing to trust this key"
    fi
  fi
fi

if [ "$mode" = update ]; then
  msg ""
  msg "Refreshing apt..."
  apt-get update
  msg ""
  msg "Archive ready. Install packages with: sudo apt install <package>"
else
  msg ""
  msg "Next:"
  msg "  sudo apt update"
  msg "  sudo apt install <package>"
fi
