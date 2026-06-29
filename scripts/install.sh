#!/usr/bin/env bash
# Build a Release version of Subtitle and install it to /Applications.
# Usage: scripts/install.sh
set -euo pipefail

# Resolve the project root (parent of this script's directory).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Subtitle"
CONFIG="Release"
DERIVED="build"
PRODUCT="${DERIVED}/Build/Products/${CONFIG}/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"

echo "==> Generating Xcode project"
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >/dev/null
else
  echo "xcodegen not found (brew install xcodegen). Using existing project if present." >&2
fi

echo "==> Building ${CONFIG}"
xcodebuild -project "${APP_NAME}.xcodeproj" -scheme "${APP_NAME}" \
  -configuration "${CONFIG}" -derivedDataPath "${DERIVED}" \
  CODE_SIGNING_ALLOWED=NO build | tail -1

if [[ ! -d "${PRODUCT}" ]]; then
  echo "Error: build product not found at ${PRODUCT}" >&2
  exit 1
fi

echo "==> Ad-hoc signing"
codesign --force --deep -s - "${PRODUCT}"

echo "==> Installing to ${DEST}"
# Quit any running copy of the installed app before replacing it.
pkill -f "${DEST}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
rm -rf "${DEST}"
ditto "${PRODUCT}" "${DEST}"
xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true

echo "==> Installed. Launching."
open -a "${DEST}"
echo "Done: ${DEST}"
