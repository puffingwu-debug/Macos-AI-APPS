#!/bin/bash
#
# Builds AITokenBar and assembles a launchable macOS .app bundle.
#
#   ./build.sh            # release build into dist/AITokenBar.app
#   ./build.sh debug      # faster build while developing
#   ./build.sh release run  # build then launch
#
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
ACTION="${2:-}"

APP_NAME="AITokenBar"
BUNDLE="dist/${APP_NAME}.app"

# zstd is linked statically so the bundle has no runtime Homebrew dependency.
if command -v brew >/dev/null 2>&1; then
  ZSTD_PREFIX="$(brew --prefix zstd 2>/dev/null || true)"
fi
if [ -z "${ZSTD_PREFIX:-}" ] || [ ! -f "${ZSTD_PREFIX}/lib/libzstd.a" ]; then
  if [ -f /opt/homebrew/lib/libzstd.a ]; then
    ZSTD_PREFIX=/opt/homebrew
  elif [ -f /usr/local/lib/libzstd.a ]; then
    ZSTD_PREFIX=/usr/local
  else
    echo "!! libzstd.a not found — building without DSH log support."
    echo "   Install it with: brew install zstd"
    export TB_NO_ZSTD=1
    ZSTD_PREFIX=/opt/homebrew
  fi
fi
export ZSTD_PREFIX
echo "==> zstd prefix: ${ZSTD_PREFIX}${TB_NO_ZSTD:+ (disabled)}"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}" --product "${APP_NAME}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
if [ ! -x "${BIN_PATH}" ]; then
  echo "!! built binary not found at ${BIN_PATH}" >&2
  exit 1
fi

echo "==> assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "${BIN_PATH}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"
printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "${BUNDLE}/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature: enough for local launch, keychain-free operation and
# stable privacy permissions. Replace with a Developer ID for distribution.
echo "==> ad-hoc signing"
codesign --force --deep --sign - "${BUNDLE}" 2>&1 | sed 's/^/    /' || true

echo "==> done: ${BUNDLE}"

if [ "${ACTION}" = "run" ]; then
  echo "==> launching"
  pkill -x "${APP_NAME}" 2>/dev/null || true
  sleep 0.4
  open "${BUNDLE}"
fi
