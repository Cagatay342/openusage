#!/usr/bin/env bash
# Build and install the OpenUsage Linux daemon as a systemd --user service.
#
#   script/install_linux_daemon.sh            build, install, enable and start
#   script/install_linux_daemon.sh --no-service   build and install the binary only
#
# Everything lands under the invoking user's home; no root required.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/spikes/windows-core"
# The XDG spec says a relative value must be ignored; the daemon follows that, so the installer
# must too or the two disagree about where things live.
xdg_dir() {
    local value="$1" fallback="$2"
    if [[ "$value" == /* ]]; then printf '%s\n' "$value"; else printf '%s\n' "$HOME/$fallback"; fi
}
INSTALL_DIR="$(xdg_dir "${XDG_DATA_HOME:-}" ".local/share")/openusage"
BIN_LINK_DIR="$HOME/.local/bin"
UNIT_DIR="$(xdg_dir "${XDG_CONFIG_HOME:-}" ".config")/systemd/user"
RESOURCE_BUNDLE="OpenUsageCore_OpenUsageCore.resources"

install_service=true
[[ "${1:-}" == "--no-service" ]] && install_service=false

if ! command -v swift >/dev/null 2>&1; then
    echo "error: 'swift' not found on PATH. Install a Swift 6.2+ toolchain (https://swift.org/install/linux)." >&2
    exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
    # Not fatal: only Cursor's desktop state DB needs it, and the cursor-agent CLI stores tokens in JSON.
    echo "warning: 'sqlite3' not found — Cursor's desktop state DB cannot be read. Install with: sudo apt install sqlite3" >&2
fi

echo "==> Building openusage-daemon (release)"
swift build --package-path "$PACKAGE_DIR" -c release --product openusage-daemon

BUILD_DIR="$(swift build --package-path "$PACKAGE_DIR" -c release --show-bin-path)"

echo "==> Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$BIN_LINK_DIR"
install -m 0755 "$BUILD_DIR/openusage-daemon" "$INSTALL_DIR/openusage-daemon"
# SwiftPM resolves Bundle.module next to the executable, so the resource bundle has to travel with it;
# without this the daemon serves no dashboard once the build directory is cleaned.
rm -rf "${INSTALL_DIR:?}/$RESOURCE_BUNDLE"
cp -r "$BUILD_DIR/$RESOURCE_BUNDLE" "$INSTALL_DIR/"
ln -sf "$INSTALL_DIR/openusage-daemon" "$BIN_LINK_DIR/openusage-daemon"

if [[ "$install_service" == false ]]; then
    echo "==> Installed. Run: $BIN_LINK_DIR/openusage-daemon --help"
    exit 0
fi

echo "==> Installing systemd --user service"
mkdir -p "$UNIT_DIR"
# Escape the replacement so a path containing sed metacharacters cannot corrupt the unit.
exec_path_escaped="$(printf '%s' "$INSTALL_DIR/openusage-daemon" | sed -e 's/[\\&|]/\\\\&/g')"
sed "s|@EXEC_PATH@|$exec_path_escaped|g" \
    "$REPO_ROOT/script/openusage.service" > "$UNIT_DIR/openusage.service"
grep -q '@EXEC_PATH@' "$UNIT_DIR/openusage.service" && {
    echo "error: failed to substitute the executable path into the unit" >&2; exit 1; }
chmod 0644 "$UNIT_DIR/openusage.service"
systemctl --user daemon-reload
systemctl --user enable --now openusage.service

# Without lingering, the service stops when the last login session ends.
if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]]; then
    echo
    echo "note: user lingering is off, so the service stops when you log out. Enable it with:"
    echo "    sudo loginctl enable-linger $USER"
fi

echo
echo "==> Done. Dashboard: http://127.0.0.1:6736"
echo "    Status: systemctl --user status openusage"
echo "    Logs:   journalctl --user -u openusage -f"
