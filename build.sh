#!/bin/bash
# Build FolderSync.app from the Swift package — no full Xcode required.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="FolderSync"
BUILD_CONFIG="release"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"

echo "==> Compiling (${BUILD_CONFIG})…"
swift build -c "${BUILD_CONFIG}"

BIN_PATH="$(swift build -c "${BUILD_CONFIG}" --show-bin-path)/${APP_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
    echo "error: built binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> Assembling ${APP_BUNDLE}…"
rm -rf "${APP_BUNDLE}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "${BIN_PATH}" "${CONTENTS}/MacOS/${APP_NAME}"
cp Info.plist "${CONTENTS}/Info.plist"
cp Icon/AppIcon.icns "${CONTENTS}/Resources/AppIcon.icns"
printf 'APPL????' > "${CONTENTS}/PkgInfo"

echo "==> Ad-hoc code signing…"
codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || \
    echo "   (codesign skipped — app will still run)"

echo ""
echo "Done. Built ${APP_BUNDLE}"
echo "Run it with:   open ${APP_BUNDLE}"
echo "Or install it: cp -R ${APP_BUNDLE} /Applications/"
