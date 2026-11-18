#!/usr/bin/env bash
# 编译并安装到 ~/Applications。
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh

mkdir -p "$HOME/Applications"
TARGET="$HOME/Applications/DSH Web.app"
rm -rf "$TARGET"
cp -R "dist/DSH Web.app" "$TARGET"

# 每次重装都是一次全新的包，Finder/IconServices 可能还拿着上一次的通用图标缓存。
# touch 一下再让 LaunchServices 重新登记；lsregister 偶尔会卡，放后台跑。
touch "$TARGET"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  ( "$LSREGISTER" -f "$TARGET" >/dev/null 2>&1 || true ) &
fi
echo "installed: $TARGET"
