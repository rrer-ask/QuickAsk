#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP_SRC="$BUILD/Build/Products/Release/QuickAsk.app"
DIST="$ROOT/dist"
STAGE="$ROOT/dist/dmg-stage"
VERSION="${QUICKASK_VERSION:-1.0}"
DMG_NAME="QuickAsk-${VERSION}.dmg"
VOL_NAME="QuickAsk"

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

rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$DIST/QuickAsk.app" "$STAGE/QuickAsk.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$ROOT/$DMG_NAME"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$ROOT/$DMG_NAME"

rm -rf "$STAGE"

if [[ "${INSTALL_LOCAL:-1}" == "1" ]]; then
  echo "Installing to /Applications…"
  rm -rf /Applications/QuickAsk.app
  ditto "$DIST/QuickAsk.app" /Applications/QuickAsk.app
fi

echo ""
echo "Ready: $ROOT/$DMG_NAME"
ls -lh "$ROOT/$DMG_NAME"
