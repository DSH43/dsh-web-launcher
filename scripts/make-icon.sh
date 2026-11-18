#!/usr/bin/env bash
# 从 DSH Web 的 512px 图标生成 macOS 的 .icns。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-$HOME/Code/deepseek-harness/apps/web/public/icon-512.png}"
[ -f "$SRC" ] || { echo "找不到图标源文件: $SRC" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/AppIcon.iconset"

sips -z 16 16 "$SRC" --out "$TMP/AppIcon.iconset/icon_16x16.png" >/dev/null
sips -z 32 32 "$SRC" --out "$TMP/AppIcon.iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$SRC" --out "$TMP/AppIcon.iconset/icon_32x32.png" >/dev/null
sips -z 64 64 "$SRC" --out "$TMP/AppIcon.iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$SRC" --out "$TMP/AppIcon.iconset/icon_128x128.png" >/dev/null
sips -z 256 256 "$SRC" --out "$TMP/AppIcon.iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SRC" --out "$TMP/AppIcon.iconset/icon_256x256.png" >/dev/null
sips -z 512 512 "$SRC" --out "$TMP/AppIcon.iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SRC" --out "$TMP/AppIcon.iconset/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SRC" --out "$TMP/AppIcon.iconset/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$TMP/AppIcon.iconset" -o assets/AppIcon.icns
echo "生成 assets/AppIcon.icns"
