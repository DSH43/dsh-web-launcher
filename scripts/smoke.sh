#!/usr/bin/env bash
# 生命周期自检：启动 App、拿到 URL、访问一次、SIGTERM、确认 host 也退出。
# 用一个空闲端口跑，不会碰你正在用的 3080。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/DSH Web.app"
BINARY="$APP/Contents/MacOS/DSHWebLauncher"
LOG="$HOME/Library/Logs/DSH Web Launcher.log"
PORT="${1:-3099}"

[ -x "$BINARY" ] || { echo "先跑 ./scripts/build.sh" >&2; exit 1; }

BEFORE=$(wc -l < "$LOG" 2>/dev/null || echo 0)
DSH_LAUNCHER_PORT="$PORT" "$BINARY" >/tmp/dsh-launcher-smoke.out 2>&1 &
APP_PID=$!
cleanup() {
  kill -KILL "$APP_PID" 2>/dev/null || true
  pkill -f "bin.js web --no-open --host 127.0.0.1 --port $PORT" 2>/dev/null || true
}
trap cleanup EXIT

URL=""
for _ in $(seq 1 120); do
  URL=$(tail -n +$((BEFORE + 1)) "$LOG" 2>/dev/null | sed -n 's/.*打开 \(http[^ ]*\).*/\1/p' | tail -1)
  [ -n "$URL" ] && break
  sleep 0.5
done
[ -n "$URL" ] || { echo "没有等到 URL" >&2; tail -20 "$LOG" >&2; exit 1; }
echo "url: $URL"

CODE=$(curl -s -o /dev/null -w '%{http_code}' "$URL")
echo "http: $CODE"
case "$CODE" in
  303|200) ;;
  *) echo "URL 返回 $CODE" >&2; exit 1 ;;
esac

kill -TERM "$APP_PID"
for _ in $(seq 1 40); do
  kill -0 "$APP_PID" 2>/dev/null || break
  sleep 0.25
done
if kill -0 "$APP_PID" 2>/dev/null; then
  echo "App 没有退出" >&2
  exit 1
fi
if ps aux | grep -q "[b]in.js web --no-open --host 127.0.0.1 --port $PORT"; then
  echo "host 没有被停掉" >&2
  exit 1
fi

echo "ok: 启动、取 URL、关停都通过"
