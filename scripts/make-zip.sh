#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP_SRC="$BUILD/Build/Products/Release/QuickAsk.app"
DIST="$ROOT/dist"
VERSION="${QUICKASK_VERSION:-1.0}"
ZIP_NAME="QuickAsk-${VERSION}.zip"

cd "$ROOT"
command -v xcodegen >/dev/null && xcodegen generate

echo "Building Release…"
xcodebuild -scheme QuickAsk -configuration Release -derivedDataPath "$BUILD" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES \
  | tail -n 20

test -d "$APP_SRC" || { echo "Missing $APP_SRC"; exit 1; }

rm -rf "$DIST"
mkdir -p "$DIST"
ditto "$APP_SRC" "$DIST/QuickAsk.app"
xattr -cr "$DIST/QuickAsk.app"
codesign --force --deep --sign - "$DIST/QuickAsk.app"

# ditto zip preserves .app bundle correctly for Finder
rm -f "$ROOT/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$DIST/QuickAsk.app" "$ROOT/$ZIP_NAME"

# optional: also install locally
if [[ "${INSTALL_LOCAL:-1}" == "1" ]]; then
  echo "Installing to /Applications…"
  rm -rf /Applications/QuickAsk.app
  ditto "$DIST/QuickAsk.app" /Applications/QuickAsk.app
fi

echo ""
echo "Ready: $ROOT/$ZIP_NAME"
ls -lh "$ROOT/$ZIP_NAME"
