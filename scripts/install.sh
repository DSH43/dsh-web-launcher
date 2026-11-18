#!/usr/bin/env bash
# 编译并安装到 ~/Applications。
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/DSH Web.app"
cp -R "dist/DSH Web.app" "$HOME/Applications/"
echo "installed: $HOME/Applications/DSH Web.app"
