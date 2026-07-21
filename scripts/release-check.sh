#!/bin/bash
# Release gate — run before EVERY release/version bump:
#   ./scripts/release-check.sh
#
# Stages: unit tests -> package -> smoke launch -> health checks -> cleanup.
# Exits non-zero on the first failure; a release only ships on ✅.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/dist/Birth.app"
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"

fail() {
    echo "❌ FAIL: $1"
    exit 1
}

echo "==> [1/4] swift test"
swift test 2>&1 | tail -2

echo "==> [2/4] package"
./scripts/make-app.sh

echo "==> [3/4] smoke launch"
# Quit any running instance (path-pinned so a stale /Applications copy
# can't hijack the name).
osascript -e "tell application \"$APP\" to quit" 2>/dev/null || true
pkill -x Birth 2>/dev/null || true
sleep 1

crashes_before=$(ls "$CRASH_DIR" 2>/dev/null | grep -c '^Birth-' || true)

# BIRTH_AUTOTEST=inspector drives the advanced table + inspector path —
# the route that once crashed on every click. launchctl setenv + open is
# mandatory: exec-ing the binary from a shell inherits its sandbox.
launchctl setenv BIRTH_AUTOTEST inspector
open "$APP"
sleep 12
launchctl unsetenv BIRTH_AUTOTEST

echo "==> [4/4] health checks"
pid=$(pgrep -x Birth) || fail "进程未存活（启动 12 秒后已退出）"
echo "    进程存活 (PID $pid)"

# Main thread must be idle-parked in the event loop, not wedged.
idle=$(sample Birth 1 -mayDie 2>/dev/null | grep -c mach_msg2_trap || true)
[ "$idle" -ge 1 ] || fail "主线程未回到事件循环（疑似卡死）— 用 sample Birth 10 诊断"
echo "    主线程健康"

crashes_after=$(ls "$CRASH_DIR" 2>/dev/null | grep -c '^Birth-' || true)
[ "$crashes_after" -le "$crashes_before" ] || fail "冒烟期间产生了新的崩溃报告（$CRASH_DIR）"
echo "    零新崩溃"

# Cleanup: quit the smoke instance, undo the autotest's persisted
# selection, relaunch in normal mode.
osascript -e "tell application \"$APP\" to quit" 2>/dev/null || true
sleep 1
defaults write dev.birth.Birth sidebarSelection -string loginApps 2>/dev/null || true

echo "✅ release check passed — dist/Birth.app 可以发布"
