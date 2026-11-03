#!/usr/bin/env bash
# =============================================================================
# HiDeploy installer
#   curl -fsSL https://raw.githubusercontent.com/hesami/hideploy/main/install.sh | sudo bash
#
# Downloads hideploy.sh, verifies it, and installs it as /usr/local/bin/hideploy.
# It never touches your projects, containers or databases, so it is safe to
# re-run at any time to update.
#
# Optional environment variables:
#   HIDEPLOY_REPO   GitHub repository (default: hesami/hideploy)
#   HIDEPLOY_REF    branch or tag to install (default: main), e.g. v1.0.0
# =============================================================================
set -euo pipefail

REPO="${HIDEPLOY_REPO:-hesami/hideploy}"
REF="${HIDEPLOY_REF:-main}"
BIN_PATH="/usr/local/bin/hideploy"
URL="https://raw.githubusercontent.com/${REPO}/${REF}/hideploy.sh"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Please run as root:  curl -fsSL <url> | sudo bash" >&2
    exit 1
fi

if [ -r /etc/os-release ] && ! grep -qiE 'ubuntu|debian' /etc/os-release; then
    echo "Warning: HiDeploy is designed for Ubuntu/Debian. Other systems are not supported." >&2
fi

version_of() { grep -m1 '^HIDEPLOY_VERSION=' "$1" 2>/dev/null | cut -d'"' -f2 || true; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

echo "Downloading HiDeploy (${REPO}@${REF})..."
if ! curl -fsSL --retry 3 --connect-timeout 15 "$URL" -o "$tmp"; then
    echo "Download failed. Your existing installation (if any) was not changed." >&2
    exit 1
fi

# Verify before replacing anything: must be a non-empty bash script with valid syntax
if [ ! -s "$tmp" ] || ! head -n1 "$tmp" | grep -q '^#!/usr/bin/env bash'; then
    echo "The downloaded file is not a HiDeploy script. Nothing was changed." >&2
    exit 1
fi
if ! bash -n "$tmp"; then
    echo "The downloaded script has a syntax error. Nothing was changed." >&2
    exit 1
fi

old="$(version_of "$BIN_PATH")"
new="$(version_of "$tmp")"

install -m 755 "$tmp" "$BIN_PATH"

if [ -n "$old" ] && [ "$old" != "$new" ]; then
    echo "HiDeploy updated: ${old} -> ${new:-unknown}"
elif [ -n "$old" ]; then
    echo "HiDeploy ${new:-unknown} reinstalled (already up to date)."
else
    echo "HiDeploy ${new:-unknown} installed successfully!"
fi
echo "Run it with:  sudo hideploy"
