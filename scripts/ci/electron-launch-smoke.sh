#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_DIR="${1:-$REPO_DIR/codex-app}"
TIMEOUT_SECONDS="${CODEX_ELECTRON_SMOKE_TIMEOUT:-25}"
PORT_START="${CODEX_ELECTRON_SMOKE_PORT_START:-5590}"
PORT_END="${CODEX_ELECTRON_SMOKE_PORT_END:-5594}"

usage() {
    cat <<'HELP'
Usage: scripts/ci/electron-launch-smoke.sh [codex-app]

Runs the generated Linux launcher with an isolated temporary HOME/XDG profile,
waits for the webview server and Electron process to spawn, then terminates the
temporary instance. This checks runtime wiring without using the real user
profile or requiring a real Codex login.

Environment:
  CODEX_ELECTRON_SMOKE_TIMEOUT=25
  CODEX_ELECTRON_SMOKE_PORT_START=5590
  CODEX_ELECTRON_SMOKE_PORT_END=5594
HELP
}

info() {
    echo "[electron-smoke] $*" >&2
}

fail() {
    echo "[electron-smoke][FAIL] $*" >&2
    exit 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

[ -x "$APP_DIR/start.sh" ] || fail "Launcher not found or not executable: $APP_DIR/start.sh"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || fail "DISPLAY or WAYLAND_DISPLAY is required for Electron launch smoke"

APP_REAL="$(realpath "$APP_DIR")"
TMP_DIR="$(mktemp -d)"
HOME_DIR="$TMP_DIR/home"
CACHE_DIR="$TMP_DIR/cache"
CONFIG_DIR="$TMP_DIR/config"
STATE_DIR="$TMP_DIR/state"
RUNTIME_DIR="$TMP_DIR/run"

cleanup() {
    local pid_file pid
    shopt -s nullglob
    for pid_file in "$STATE_DIR"/codex-desktop/*.pid "$STATE_DIR"/codex-desktop/instances/*/*.pid; do
        pid="$(cat "$pid_file" 2>/dev/null || true)"
        if [ -n "$pid" ]; then
            kill "$pid" >/dev/null 2>&1 || true
        fi
    done
    for pid in $(pgrep -f "$APP_REAL/electron .*${TMP_DIR}" 2>/dev/null || true); do
        kill "$pid" >/dev/null 2>&1 || true
    done
    sleep 0.2
    for pid in $(pgrep -f "$APP_REAL/electron .*${TMP_DIR}" 2>/dev/null || true); do
        kill -9 "$pid" >/dev/null 2>&1 || true
    done
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$HOME_DIR" "$CACHE_DIR" "$CONFIG_DIR" "$STATE_DIR" "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"

status=0
info "Launching $APP_REAL with temporary profile $TMP_DIR"
HOME="$HOME_DIR" \
XDG_CACHE_HOME="$CACHE_DIR" \
XDG_CONFIG_HOME="$CONFIG_DIR" \
XDG_STATE_HOME="$STATE_DIR" \
XDG_RUNTIME_DIR="$RUNTIME_DIR" \
CODEX_CLI_PATH="${CODEX_CLI_PATH:-/bin/true}" \
CODEX_UPDATE_MANAGER_SKIP_SYSTEM_CLI_LOOKUP=1 \
CODEX_MULTI_LAUNCH=1 \
CODEX_MULTI_LAUNCH_PORT_RANGE="$PORT_START-$PORT_END" \
timeout "$TIMEOUT_SECONDS" "$APP_REAL/start.sh" --safe-mode -- --no-sandbox || status=$?

if [ "$status" -ne 0 ] && [ "$status" -ne 124 ]; then
    fail "Launcher exited before smoke timeout with status $status"
fi

LOG_FILE=""
for candidate in \
    "$CACHE_DIR/codex-desktop/launcher-port-$PORT_START.log" \
    "$CACHE_DIR/codex-desktop/launcher.log" \
    "$CACHE_DIR"/codex-desktop/launcher-port-*.log
do
    if [ -f "$candidate" ]; then
        LOG_FILE="$candidate"
        break
    fi
done
[ -n "$LOG_FILE" ] || fail "Launcher log not found under $CACHE_DIR/codex-desktop"

grep -q "Webview server is ready" "$LOG_FILE" || fail "Webview readiness was not logged"
grep -q "Webview origin verified" "$LOG_FILE" || fail "Webview origin verification was not logged"
grep -q "launcher_phase=electron_spawned" "$LOG_FILE" || fail "Electron spawn was not logged"
grep -q "Browser Use plugin cache synced" "$LOG_FILE" || fail "Browser Use plugin cache sync was not logged"
grep -q "Chrome plugin cache synced" "$LOG_FILE" || fail "Chrome plugin cache sync was not logged"
grep -q "Computer Use plugin cache synced" "$LOG_FILE" || fail "Computer Use plugin cache sync was not logged"
grep -q "Read Aloud plugin cache synced" "$LOG_FILE" || fail "Read Aloud plugin cache sync was not logged"

info "Electron launch smoke passed"
