#!/bin/bash
# Builds Birth.app into dist/ from the SPM executable.
#   ./scripts/make-app.sh            release build, current architecture
#   ./scripts/make-app.sh universal  release build, arm64 + x86_64
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.2.8}"
APP=dist/Birth.app
BUILD_ARGS=(-c release)
if [[ "${1:-}" == "universal" ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

echo "==> swift build ${BUILD_ARGS[*]}"
swift build "${BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/Birth"

echo "==> assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/Birth"

# SPM resource bundles (localized strings): Localization.swift resolves
# them from Contents/Resources inside a packaged .app. Missing bundles
# would strand users on raw keys — fail the build loudly, never ship.
copied=0
for bundle in "$(dirname "$BIN_PATH")"/birth_*.bundle; do
    [ -e "$bundle" ] || continue
    cp -R "$bundle" "$APP/Contents/Resources/"
    copied=$((copied + 1))
done
if [ "$copied" -eq 0 ]; then
    echo "ERROR: no birth_*.bundle produced by swift build — localization would be broken" >&2
    exit 1
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleExecutable</key>
    <string>Birth</string>
    <key>CFBundleIdentifier</key>
    <string>dev.birth.Birth</string>
    <key>CFBundleName</key>
    <string>Birth</string>
    <key>CFBundleDisplayName</key>
    <string>Birth</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Birth 需要通过“系统事件”来添加和移除登录时打开的 App。</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
</dict>
</plist>
PLIST

# Declare both localizations so framework-provided strings (menu bar,
# standard dialog buttons) follow the app's language, not just Chinese.
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj" "$APP/Contents/Resources/en.lproj"

# TCC usage strings follow the app language too; the Chinese original
# lives in Info.plist itself (the development-region fallback).
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
"NSAppleEventsUsageDescription" = "Birth needs to control System Events to add and remove apps that open at login.";
STRINGS

echo "==> rendering icon"
ICONSET=dist/AppIcon.iconset
rm -rf "$ICONSET"
swift scripts/generate-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "==> done: $APP"
