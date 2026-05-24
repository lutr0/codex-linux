#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_FEDORA_IMAGE="docker.io/library/fedora:42@sha256:99e203b80b1c3d8f7e161ec10a68fd02b081ef83a3963553e513c82846b97814"
IMAGE="${CI_RPM_INSTALL_IMAGE:-$DEFAULT_FEDORA_IMAGE}"

usage() {
    cat <<'HELP'
Usage: scripts/ci/fedora-rpm-install-smoke.sh [dist/codex-desktop-*.rpm]

Installs a built Codex Desktop RPM into a fresh Fedora container and verifies
the installed native package surface: launcher, update manager, systemd user
unit, polkit policy, update-builder bundle, managed Node.js runtime, bundled
Chrome/Computer Use/Read Aloud plugin binaries, and updater status JSON.

Environment:
  CI_CONTAINER_ENGINE=docker|podman
  CI_RPM_INSTALL_IMAGE=docker.io/library/fedora:42@sha256:99e203b80...
  CI_SKIP_PULL=1
HELP
}

info() {
    echo "[fedora-rpm-smoke] $*" >&2
}

error() {
    echo "[fedora-rpm-smoke][ERROR] $*" >&2
    exit 1
}

container_engine() {
    if [ -n "${CI_CONTAINER_ENGINE:-}" ]; then
        command -v "$CI_CONTAINER_ENGINE" >/dev/null 2>&1 || error "CI_CONTAINER_ENGINE is not available: $CI_CONTAINER_ENGINE"
        printf '%s\n' "$CI_CONTAINER_ENGINE"
        return
    fi
    if command -v docker >/dev/null 2>&1; then
        printf '%s\n' docker
        return
    fi
    if command -v podman >/dev/null 2>&1; then
        printf '%s\n' podman
        return
    fi
    error "Docker or Podman is required. Install one, or set CI_CONTAINER_ENGINE."
}

latest_rpm() {
    python3 - "$REPO_DIR/dist" <<'PY'
import sys
from pathlib import Path

dist = Path(sys.argv[1])
matches = sorted(
    dist.glob("codex-desktop-*.rpm"),
    key=lambda path: path.stat().st_mtime,
    reverse=True,
) if dist.is_dir() else []
if matches:
    print(matches[0])
PY
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
if [ "$#" -gt 1 ]; then
    error "Pass at most one RPM path; omit it to test the newest dist/codex-desktop-*.rpm"
fi

RPM_PATH="${1:-}"
if [ -z "$RPM_PATH" ]; then
    RPM_PATH="$(latest_rpm)"
fi
[ -n "$RPM_PATH" ] || error "No RPM path provided and no dist/codex-desktop-*.rpm artifact found"
[ -f "$RPM_PATH" ] || error "RPM not found: $RPM_PATH"

RPM_REAL="$(realpath "$RPM_PATH")"
REPO_REAL="$(realpath "$REPO_DIR")"
case "$RPM_REAL" in
    "$REPO_REAL"/*) ;;
    *) error "RPM must live under the repository so it can be mounted into the Fedora container: $RPM_REAL" ;;
esac
RPM_REL="${RPM_REAL#$REPO_REAL/}"
ENGINE="$(container_engine)"

if [ "${CI_SKIP_PULL:-0}" != "1" ]; then
    info "Pulling $IMAGE"
    "$ENGINE" pull "$IMAGE" >/dev/null
fi

info "Installing $RPM_REL in $IMAGE"
"$ENGINE" run --rm \
    -i \
    -v "$REPO_REAL:/work:ro" \
    -w /work \
    "$IMAGE" \
    bash -s -- "$RPM_REL" <<'CONTAINER'
set -Eeuo pipefail

rpm_path="$1"

fail() {
    echo "[fedora-rpm-smoke][FAIL] $*" >&2
    exit 1
}

assert_file() {
    [ -f "$1" ] || fail "Expected file: $1"
}

assert_executable() {
    [ -x "$1" ] || fail "Expected executable: $1"
}

assert_json_file() {
    python3 - "$1" <<'PY' || exit 1
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    json.load(handle)
PY
}

linux_plugin_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf '%s\n' "x64" ;;
        aarch64|arm64) printf '%s\n' "arm64" ;;
        *) uname -m ;;
    esac
}

dnf install -y "./$rpm_path"

rpm -q codex-desktop
rpm -q rpm-build cargo rust

assert_executable /usr/bin/codex-desktop
assert_executable /usr/bin/codex-update-manager
assert_file /usr/lib/systemd/user/codex-update-manager.service
assert_file /usr/share/polkit-1/actions/com.github.ilysenko.codex-desktop-linux.update.policy

assert_executable /opt/codex-desktop/start.sh
assert_file /opt/codex-desktop/resources/app.asar
assert_executable /opt/codex-desktop/resources/node-runtime/bin/node
assert_file /opt/codex-desktop/.codex-linux/build-info.json

assert_file /opt/codex-desktop/update-builder/install.sh
assert_file /opt/codex-desktop/update-builder/linux-features/features.json
assert_file /opt/codex-desktop/update-builder/scripts/lib/linux-features.js

plugin_arch="$(linux_plugin_arch)"
assert_executable "/opt/codex-desktop/resources/plugins/openai-bundled/plugins/chrome/extension-host/linux/$plugin_arch/extension-host"
assert_executable /opt/codex-desktop/resources/plugins/openai-bundled/plugins/computer-use/bin/codex-computer-use-linux
assert_executable /opt/codex-desktop/resources/plugins/openai-bundled/plugins/read-aloud/bin/codex-read-aloud-linux
assert_executable /opt/codex-desktop/resources/read-aloud/kokoro-stdin

/opt/codex-desktop/start.sh --help >/tmp/codex-start-help.txt
grep -q -- '--wayland' /tmp/codex-start-help.txt || fail "Launcher help did not include Wayland support"

/usr/bin/codex-update-manager status --json >/tmp/codex-update-status.json
assert_json_file /tmp/codex-update-status.json

/opt/codex-desktop/resources/plugins/openai-bundled/plugins/read-aloud/bin/codex-read-aloud-linux doctor >/tmp/read-aloud-doctor.json
assert_json_file /tmp/read-aloud-doctor.json

/opt/codex-desktop/resources/plugins/openai-bundled/plugins/computer-use/bin/codex-computer-use-linux doctor >/tmp/computer-use-doctor.json
assert_json_file /tmp/computer-use-doctor.json

python3 - <<'PY'
import json
from pathlib import Path

features = json.loads(Path("/opt/codex-desktop/update-builder/linux-features/features.json").read_text())
enabled = features.get("enabled")
if enabled != ["read-aloud", "read-aloud-mcp"]:
    raise SystemExit(f"unexpected packaged feature profile: {enabled!r}")

status = json.loads(Path("/tmp/codex-update-status.json").read_text())
if status.get("status") not in {"idle", "error"}:
    raise SystemExit(f"unexpected updater status: {status.get('status')!r}")
if not status.get("installed_version"):
    raise SystemExit("updater status did not report installed_version")

read_aloud = json.loads(Path("/tmp/read-aloud-doctor.json").read_text())
if read_aloud.get("platform") != "linux":
    raise SystemExit("Read Aloud doctor did not report linux platform")
runner = read_aloud.get("kokoro", {}).get("runner", {})
if runner.get("exists") is not True or runner.get("executable") is not True:
    raise SystemExit(f"Read Aloud Kokoro runner is not staged correctly: {runner!r}")

computer_use = json.loads(Path("/tmp/computer-use-doctor.json").read_text())
readiness = computer_use.get("readiness", {})
if readiness.get("can_register_mcp_tools") is not True:
    raise SystemExit("Computer Use doctor cannot register MCP tools")
PY

echo "[fedora-rpm-smoke] Fedora RPM install smoke passed"
CONTAINER
