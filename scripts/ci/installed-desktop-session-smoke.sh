#!/bin/bash
set -Eeuo pipefail

APP_DIR="/opt/codex-desktop"
JSON_OUT=""
RUN_LAUNCH=0
TIMEOUT_SECONDS="${CODEX_DESKTOP_SESSION_SMOKE_TIMEOUT:-25}"
PORT_START="${CODEX_DESKTOP_SESSION_SMOKE_PORT_START:-5595}"
PORT_END="${CODEX_DESKTOP_SESSION_SMOKE_PORT_END:-5599}"
RESULTS_FILE="$(mktemp)"

usage() {
    cat <<'HELP'
Usage: scripts/ci/installed-desktop-session-smoke.sh [--launch] [--json PATH] [--app-dir /opt/codex-desktop]

Validates an installed Codex Desktop Linux package from inside the real user
desktop session. The default checks are non-launching and verify installed
files, updater state, desktop/session signals, plugin doctors, and staged
resources. --launch starts the packaged launcher with the real user profile for
a bounded smoke run so bundled plugin cache sync and Chrome native-host
manifest installation can be verified.

Environment:
  CODEX_DESKTOP_SESSION_SMOKE_TIMEOUT=25
  CODEX_DESKTOP_SESSION_SMOKE_PORT_START=5595
  CODEX_DESKTOP_SESSION_SMOKE_PORT_END=5599
  CODEX_DESKTOP_SESSION_REQUIRE_COMPUTER_USE_READY=1
  CODEX_DESKTOP_SESSION_REQUIRE_READ_ALOUD_READY=1
HELP
}

record() {
    local name="$1"
    local status="$2"
    local detail="${3:-}"
    printf '%s\t%s\t%s\n' "$name" "$status" "$detail" >> "$RESULTS_FILE"
    printf '[%s] %s' "$status" "$name"
    if [ -n "$detail" ]; then
        printf ' - %s' "$detail"
    fi
    printf '\n'
}

pass() { record "$1" "pass" "${2:-}"; }
fail() { record "$1" "fail" "${2:-}"; }
warn() { record "$1" "warn" "${2:-}"; }
skip() { record "$1" "skip" "${2:-}"; }

truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

linux_plugin_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf '%s\n' "x64" ;;
        aarch64|arm64) printf '%s\n' "arm64" ;;
        *) uname -m ;;
    esac
}

valid_json() {
    python3 - "$1" <<'PY' >/dev/null 2>&1
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    json.load(handle)
PY
}

pid_belongs_to_smoke_app() {
    local pid="$1"
    local exe cwd cmdline
    [ -d "/proc/$pid" ] || return 1
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    if [ "$exe" = "$APP_DIR/electron" ]; then
        return 0
    fi
    cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    [ "$cwd" = "$APP_DIR/content/webview" ] && [[ "$cmdline" == *"http.server"* ]]
}

json_query() {
    local file="$1"
    local expression="$2"
    python3 - "$file" "$expression" <<'PY'
import json
import sys

path, expression = sys.argv[1:3]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

value = data
for part in expression.split("."):
    if not part:
        continue
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break

if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
PY
}

write_report() {
    local output="$1"
    python3 - "$RESULTS_FILE" "$output" <<'PY'
import json
import os
import platform
import sys
from pathlib import Path

results_path, output_path = sys.argv[1:3]
checks = []
with open(results_path, "r", encoding="utf-8") as handle:
    for line in handle:
        name, status, detail = line.rstrip("\n").split("\t", 2)
        checks.append({"name": name, "status": status, "detail": detail})

report = {
    "schema_version": 1,
    "platform": {
        "system": platform.system(),
        "machine": platform.machine(),
        "desktop_session": os.environ.get("XDG_SESSION_DESKTOP"),
        "session_type": os.environ.get("XDG_SESSION_TYPE"),
        "current_desktop": os.environ.get("XDG_CURRENT_DESKTOP"),
        "display": os.environ.get("DISPLAY"),
        "wayland_display": os.environ.get("WAYLAND_DISPLAY"),
        "xdg_runtime_dir": os.environ.get("XDG_RUNTIME_DIR"),
    },
    "summary": {
        "pass": sum(1 for item in checks if item["status"] == "pass"),
        "warn": sum(1 for item in checks if item["status"] == "warn"),
        "fail": sum(1 for item in checks if item["status"] == "fail"),
        "skip": sum(1 for item in checks if item["status"] == "skip"),
    },
    "checks": checks,
}
Path(output_path).parent.mkdir(parents=True, exist_ok=True)
Path(output_path).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
PY
}

cleanup() {
    if [ "${RUN_LAUNCH:-0}" -eq 1 ]; then
        local state_root="${XDG_STATE_HOME:-$HOME/.local/state}/codex-desktop/instances"
        local state_base pid_file pid port
        for port in $(seq "$PORT_START" "$PORT_END"); do
            state_base="$state_root/port-$port"
            for pid_file in "$state_base/app.pid" "$state_base/webview.pid"; do
                if [ -f "$pid_file" ]; then
                    pid="$(cat "$pid_file" 2>/dev/null || true)"
                    if [ -n "$pid" ] && pid_belongs_to_smoke_app "$pid"; then
                        kill "$pid" >/dev/null 2>&1 || true
                    fi
                fi
            done
        done
        for port in $(seq "$PORT_START" "$PORT_END"); do
            for pid in $(pgrep -f "$APP_DIR/electron .*instances/port-$port" 2>/dev/null || true); do
                kill "$pid" >/dev/null 2>&1 || true
            done
        done
        sleep 0.2
        for port in $(seq "$PORT_START" "$PORT_END"); do
            for pid in $(pgrep -f "$APP_DIR/electron .*instances/port-$port" 2>/dev/null || true); do
                kill -9 "$pid" >/dev/null 2>&1 || true
            done
        done
    fi
    rm -f "$RESULTS_FILE"
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --launch)
            RUN_LAUNCH=1
            ;;
        --json)
            shift
            [ $# -gt 0 ] || { echo "--json requires a path" >&2; exit 2; }
            JSON_OUT="$1"
            ;;
        --app-dir)
            shift
            [ $# -gt 0 ] || { echo "--app-dir requires a path" >&2; exit 2; }
            APP_DIR="$1"
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

APP_DIR="$(readlink -f "$APP_DIR" 2>/dev/null || printf '%s\n' "$APP_DIR")"
JSON_OUT="${JSON_OUT:-${PWD}/dist/desktop-session-smoke.json}"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CHROME_PLUGIN_DIR="$APP_DIR/resources/plugins/openai-bundled/plugins/chrome"
PLUGIN_ARCH="$(linux_plugin_arch)"
COMPUTER_USE_BIN="$APP_DIR/resources/plugins/openai-bundled/plugins/computer-use/bin/codex-computer-use-linux"
READ_ALOUD_BIN="$APP_DIR/resources/plugins/openai-bundled/plugins/read-aloud/bin/codex-read-aloud-linux"

if [ -d "$APP_DIR" ]; then
    pass "installed app directory" "$APP_DIR"
else
    fail "installed app directory" "$APP_DIR missing"
fi

for executable in \
    /usr/bin/codex-desktop \
    /usr/bin/codex-update-manager \
    "$APP_DIR/start.sh" \
    "$APP_DIR/resources/node-runtime/bin/node" \
    "$CHROME_PLUGIN_DIR/extension-host/linux/$PLUGIN_ARCH/extension-host" \
    "$COMPUTER_USE_BIN" \
    "$READ_ALOUD_BIN" \
    "$APP_DIR/resources/read-aloud/kokoro-stdin"
do
    if [ -x "$executable" ]; then
        pass "executable $(basename "$executable")" "$executable"
    else
        fail "executable $(basename "$executable")" "$executable missing or not executable"
    fi
done

for file in \
    "$APP_DIR/resources/app.asar" \
    "$APP_DIR/.codex-linux/build-info.json" \
    "$APP_DIR/update-builder/install.sh" \
    "$APP_DIR/update-builder/linux-features/features.json" \
    /usr/lib/systemd/user/codex-update-manager.service \
    /usr/share/applications/codex-desktop.desktop \
    /usr/share/polkit-1/actions/com.github.ilysenko.codex-desktop-linux.update.policy
do
    if [ -f "$file" ]; then
        pass "file $(basename "$file")" "$file"
    else
        fail "file $(basename "$file")" "$file missing"
    fi
done

if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    pass "display server" "DISPLAY=${DISPLAY:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
else
    fail "display server" "DISPLAY or WAYLAND_DISPLAY is required for GUI parity validation"
fi

if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
    pass "XDG runtime dir" "$XDG_RUNTIME_DIR"
else
    fail "XDG runtime dir" "XDG_RUNTIME_DIR is missing or not a directory"
fi

if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || [ -S "${XDG_RUNTIME_DIR:-}/bus" ]; then
    pass "session bus" "${DBUS_SESSION_BUS_ADDRESS:-${XDG_RUNTIME_DIR:-}/bus}"
else
    warn "session bus" "D-Bus session bus not detected; systemd --user and portal checks may fail"
fi

if command -v systemctl >/dev/null 2>&1; then
    service_state="$(systemctl --user is-enabled codex-update-manager.service 2>/dev/null || true)/$(systemctl --user is-active codex-update-manager.service 2>/dev/null || true)"
    case "$service_state" in
        enabled/active|enabled/inactive|disabled/active|static/active)
            pass "update manager user service" "$service_state"
            ;;
        *)
            warn "update manager user service" "$service_state"
            ;;
    esac
else
    warn "update manager user service" "systemctl missing"
fi

if command -v codex-update-manager >/dev/null 2>&1; then
    status_json="$(mktemp)"
    if codex-update-manager status --json > "$status_json"; then
        if valid_json "$status_json"; then
            installed_version="$(json_query "$status_json" "installed_version" 2>/dev/null || true)"
            pass "update manager status" "installed_version=${installed_version:-unknown}"
        else
            fail "update manager status" "status command emitted invalid JSON"
        fi
    else
        fail "update manager status" "codex-update-manager status --json failed"
    fi
    rm -f "$status_json"
else
    fail "update manager status" "codex-update-manager missing from PATH"
fi

start_help="$(mktemp)"
if "$APP_DIR/start.sh" --help >"$start_help" 2>&1; then
    if grep -q -- '--wayland' "$start_help"; then
        pass "launcher help" "Wayland/X11 switches available"
    else
        fail "launcher help" "help output missing Wayland switch"
    fi
else
    fail "launcher help" "start.sh --help failed"
fi
rm -f "$start_help"

if [ -f "$APP_DIR/update-builder/linux-features/features.json" ]; then
    feature_list="$(json_query "$APP_DIR/update-builder/linux-features/features.json" "enabled" 2>/dev/null || true)"
    if python3 - "$APP_DIR/update-builder/linux-features/features.json" <<'PY'
import json
import sys
enabled = json.load(open(sys.argv[1], encoding="utf-8")).get("enabled")
raise SystemExit(0 if enabled == ["read-aloud", "read-aloud-mcp"] else 1)
PY
    then
        pass "default Linux feature profile" "read-aloud,read-aloud-mcp"
    else
        warn "default Linux feature profile" "unexpected enabled list: ${feature_list:-unknown}"
    fi
fi

if [ -x "$READ_ALOUD_BIN" ]; then
    read_aloud_json="$(mktemp)"
    if "$READ_ALOUD_BIN" doctor > "$read_aloud_json"; then
        if valid_json "$read_aloud_json"; then
            runner_exists="$(json_query "$read_aloud_json" "kokoro.runner.exists" 2>/dev/null || true)"
            available="$(json_query "$read_aloud_json" "available" 2>/dev/null || true)"
            if [ "$runner_exists" = "true" ]; then
                pass "Read Aloud doctor" "backend available=${available:-false}"
            else
                fail "Read Aloud doctor" "Kokoro runner not staged"
            fi
            if [ "$available" = "true" ] || ! truthy "${CODEX_DESKTOP_SESSION_REQUIRE_READ_ALOUD_READY:-0}"; then
                :
            else
                fail "Read Aloud ready" "No speech backend ready"
            fi
        else
            fail "Read Aloud doctor" "doctor emitted invalid JSON"
        fi
    else
        fail "Read Aloud doctor" "doctor command failed"
    fi
    rm -f "$read_aloud_json"
else
    fail "Read Aloud doctor" "backend missing"
fi

if [ -x "$COMPUTER_USE_BIN" ]; then
    computer_use_json="$(mktemp)"
    if "$COMPUTER_USE_BIN" doctor > "$computer_use_json"; then
        if valid_json "$computer_use_json"; then
            can_register="$(json_query "$computer_use_json" "readiness.can_register_mcp_tools" 2>/dev/null || true)"
            can_query_windows="$(json_query "$computer_use_json" "readiness.can_query_windows" 2>/dev/null || true)"
            can_send_input="$(json_query "$computer_use_json" "readiness.can_send_development_input" 2>/dev/null || true)"
            if [ "$can_register" = "true" ]; then
                pass "Computer Use doctor" "can_query_windows=${can_query_windows:-false} can_send_development_input=${can_send_input:-false}"
            else
                fail "Computer Use doctor" "cannot register MCP tools"
            fi
            if truthy "${CODEX_DESKTOP_SESSION_REQUIRE_COMPUTER_USE_READY:-0}" && { [ "$can_query_windows" != "true" ] || [ "$can_send_input" != "true" ]; }; then
                fail "Computer Use ready" "window targeting or development input is not ready"
            fi
        else
            fail "Computer Use doctor" "doctor emitted invalid JSON"
        fi
    else
        fail "Computer Use doctor" "doctor command failed"
    fi
    rm -f "$computer_use_json"
else
    fail "Computer Use doctor" "backend missing"
fi

if [ "$RUN_LAUNCH" -eq 1 ]; then
    if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        fail "packaged launcher smoke" "cannot launch without DISPLAY or WAYLAND_DISPLAY"
    else
        log_dir="${XDG_CACHE_HOME:-$HOME/.cache}/codex-desktop"
        launch_marker="$(mktemp)"
        touch "$launch_marker"
        status=0
        CODEX_CLI_PATH="${CODEX_CLI_PATH:-/bin/true}" \
        CODEX_UPDATE_MANAGER_SKIP_SYSTEM_CLI_LOOKUP=1 \
        CODEX_MULTI_LAUNCH=1 \
        CODEX_MULTI_LAUNCH_PORT_RANGE="$PORT_START-$PORT_END" \
            timeout "$TIMEOUT_SECONDS" /usr/bin/codex-desktop --safe-mode -- --no-sandbox || status=$?
        launch_log=""
        for candidate in "$log_dir/launcher-port-$PORT_START.log" "$log_dir/launcher.log" "$log_dir"/launcher-port-*.log; do
            if [ -f "$candidate" ] && [ "$candidate" -nt "$launch_marker" ]; then
                launch_log="$candidate"
                break
            fi
        done
        rm -f "$launch_marker"
        if [ "$status" -ne 0 ] && [ "$status" -ne 124 ]; then
            fail "packaged launcher smoke" "launcher exited with status $status"
        elif [ -n "$launch_log" ] && grep -q "launcher_phase=electron_spawned" "$launch_log"; then
            pass "packaged launcher smoke" "Electron spawned; log=$launch_log"
        else
            fail "packaged launcher smoke" "Electron spawn not recorded under $log_dir"
        fi
    fi
else
    skip "packaged launcher smoke" "rerun with --launch to verify real-profile cache sync and native-host manifests"
fi

if [ "$RUN_LAUNCH" -eq 1 ]; then
    for plugin in browser chrome computer-use read-aloud; do
        if [ -L "$CODEX_HOME_DIR/plugins/cache/openai-bundled/$plugin/latest" ]; then
            pass "plugin cache $plugin" "$CODEX_HOME_DIR/plugins/cache/openai-bundled/$plugin/latest"
        else
            fail "plugin cache $plugin" "latest symlink missing"
        fi
    done

    extension_json="$CHROME_PLUGIN_DIR/scripts/extension-id.json"
    host_name="$(json_query "$extension_json" "extensionHostName" 2>/dev/null || true)"
    extension_id="$(json_query "$extension_json" "extensionId" 2>/dev/null || true)"
    for manifest_dir in \
        "$HOME/.config/google-chrome/NativeMessagingHosts" \
        "$HOME/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts" \
        "$HOME/.config/chromium/NativeMessagingHosts"
    do
        manifest_path="$manifest_dir/$host_name.json"
        if [ -f "$manifest_path" ] && grep -q "chrome-extension://$extension_id/" "$manifest_path"; then
            pass "Chrome native host manifest" "$manifest_path"
        else
            fail "Chrome native host manifest" "$manifest_path missing or mismatched"
        fi
    done
else
    skip "plugin cache and Chrome native host manifests" "rerun with --launch"
fi

write_report "$JSON_OUT"
echo "Wrote desktop-session smoke report: $JSON_OUT"

fail_count="$(python3 - "$RESULTS_FILE" <<'PY'
import sys
print(sum(1 for line in open(sys.argv[1], encoding="utf-8") if "\tfail\t" in line))
PY
)"

if [ "$fail_count" -gt 0 ]; then
    exit 1
fi
