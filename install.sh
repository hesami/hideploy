#!/usr/bin/env bash
set -euo pipefail

REPO="hesami/hideploy"
BRANCH="main"
BIN_PATH="/usr/local/bin/hideploy"

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo bash install.sh" >&2
  exit 1
fi

echo "Downloading HiDeploy from GitHub..."
curl -fsSL "https://raw.githubusercontent.com/${REPO}/${BRANCH}/hideploy.sh" -o "$BIN_PATH"

chmod +x "$BIN_PATH"
echo "HiDeploy installed successfully!"
echo "Run it with: sudo hideploy"
