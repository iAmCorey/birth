#!/bin/bash
# Builds Birth.app into dist/ from the SPM executable.
#   ./scripts/make-app.sh            release build, current architecture
#   ./scripts/make-app.sh universal  release build, arm64 + x86_64
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.2.0}"
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

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
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
</dict>
</plist>
PLIST

# Declare Simplified Chinese so framework-provided strings (menu bar,
# standard dialog buttons) render in Chinese.
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj"

echo "==> rendering icon"
ICONSET=dist/AppIcon.iconset
rm -rf "$ICONSET"
swift scripts/generate-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "==> done: $APP"
