#!/usr/bin/env bash
# 编译并组装一个自包含的 .app 到 dist/。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DSH Web"
BUNDLE="dist/${APP_NAME}.app"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

swiftc -O -swift-version 5 \
  -framework Cocoa -framework WebKit \
  -o "$BUNDLE/Contents/MacOS/DSHWebLauncher" Sources/main.swift

cp Info.plist "$BUNDLE/Contents/Info.plist"
if [ -f assets/AppIcon.icns ]; then
  cp assets/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

# 本地自用，ad-hoc 签名即可。
codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || true

echo "built: $BUNDLE"
