#!/bin/bash
# Packages dist/Birth.app into a drag-to-Applications DMG for GitHub
# Releases — the no-developer-account distribution path.
#   ./scripts/make-app.sh && ./scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
APP=dist/Birth.app
DMG="dist/Birth-${VERSION}.dmg"

[ -d "$APP" ] || { echo "缺少 $APP —— 先运行 ./scripts/make-app.sh"; exit 1; }

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "Birth" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
echo "==> done: $DMG"
