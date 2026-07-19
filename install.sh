#!/usr/bin/env bash
# Build a runnable Linux TRAE SOLO app from an official macOS DMG.
#
#   ./install.sh --dmg /path/to/TRAE_Work-darwin-x64.dmg \
#               --install-dir build/trae-solo
#
# Pipeline: extract DMG -> stage resources/ -> adapt app.asar paths ->
# process native addons -> install matching Linux Electron -> write start.sh.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ROOT="$SCRIPT_DIR"
# shellcheck source=scripts/lib_common.sh
. "$SCRIPT_DIR/scripts/lib_common.sh"
# shellcheck source=scripts/lib_dmg.sh
. "$SCRIPT_DIR/scripts/lib_dmg.sh"
# shellcheck source=scripts/lib_native.sh
. "$SCRIPT_DIR/scripts/lib_native.sh"
# shellcheck source=scripts/lib_electron.sh
. "$SCRIPT_DIR/scripts/lib_electron.sh"
# shellcheck source=scripts/lib_linux.sh
. "$SCRIPT_DIR/scripts/lib_linux.sh"

DMG=""
INSTALL_DIR="$SCRIPT_DIR/build/trae-solo"
ARCH="x64"   # internal default; only x64 is supported

usage() {
  cat <<EOF
Usage: $0 --dmg <path> [--install-dir <dir>]
  --dmg <path>          macOS DMG to convert (or set TRAE_UPSTREAM_DMG_URL)
  --install-dir <dir>   output dir (default: build/trae-solo)
  --arch <x64>          target Linux architecture (default: x64)

The patched Electron runtime and Linux native overlay are read from:
  $TRAE_VENDOR_DIR
Refresh them once with scripts/vendor_linux_runtime.sh <official-trae.deb>.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dmg)         DMG="$2"; shift 2 ;;
    --electron-deb)
      die "--electron-deb is no longer a per-build input.
Run scripts/vendor_linux_runtime.sh '$2' once, then build without this flag." ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --arch)        ARCH="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

require_cmd 7z curl perl node python3 file strings find
resolve_arch "$ARCH"

[ -f "$TRAE_VENDOR_DIR/manifest.json" ] || die "Vendored ByteDance runtime missing at $TRAE_VENDOR_DIR.
Run scripts/vendor_linux_runtime.sh /path/to/Trae-linux-x64.deb once."
info "Vendored Linux runtime: $TRAE_VENDOR_DIR"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

info "==> Resolving DMG"
DMG_PATH="$(dmg_resolve "$DMG")"

info "==> Extracting DMG"
APP="$(dmg_extract "$DMG_PATH" "$WORK/dmg")"
CONTENTS="$APP/Contents"

info "==> Detecting versions"
ELECTRON_VERSION="$(dmg_detect_electron "$APP")"
APP_VERSION="$(dmg_app_version "$APP")"
APP_DISPLAY="$(dmg_app_display_name "$APP")"
PAYLOAD_VERSION="$(node -p "require('$CONTENTS/Resources/app/package.json').version" 2>/dev/null || true)"
info "$APP_DISPLAY $APP_VERSION (payload $PAYLOAD_VERSION) / Electron $ELECTRON_VERSION / target linux-$TRAE_ELECTRON_ARCH"

# Cross-check the DMG Trae version against the donor .deb. The aha* API surface
# is stable within a Trae release line, but a drift is worth warning about.
DONOR_VER="$(node -p "require('$TRAE_VENDOR_DIR/manifest.json').source_package_version" 2>/dev/null || true)"
DONOR_APP_VER="$(node -p "require('$TRAE_VENDOR_DIR/manifest.json').donor_app_version" 2>/dev/null || true)"
if [ -n "$DONOR_APP_VER" ] && [ "$DONOR_APP_VER" = "$PAYLOAD_VERSION" ]; then
  info "Native ABI version match: DMG payload $PAYLOAD_VERSION == Linux donor $DONOR_APP_VER"
fi

info "==> Staging app resources -> $INSTALL_DIR"
rm -rf "$INSTALL_DIR"; mkdir -p "$INSTALL_DIR/resources"
# TRAE SOLO ships app.asar as a directory tree (not a packed archive) inside
# Contents/Resources/app/. Mirror Contents/Resources so every path the app
# resolves via process.resourcesPath (= $INSTALL_DIR/resources) is intact.
cp -a "$CONTENTS/Resources/." "$INSTALL_DIR/resources/"

info "==> Applying Linux adaptation patches"
APP_ROOT="$INSTALL_DIR/resources/app"
[ -d "$APP_ROOT" ] || die "Expected app/ payload at $APP_ROOT, not found"
node "$SCRIPT_DIR/scripts/patch_linux.js" "$APP_ROOT" "$TRAE_PKG_NAME"

info "==> Stubbing aha* APIs the donor Electron dropped"
node "$SCRIPT_DIR/scripts/patch_aha_shim.js" "$APP_ROOT"

info "==> Installing vendored ByteDance forked Linux Electron"
electron_install "$INSTALL_DIR"

info "==> Replacing DMG platform components with vendored Linux builds"
linux_overlay_install "$APP_ROOT" "$TRAE_VENDOR_DIR"
linux_prune_foreign_binaries "$APP_ROOT"
linux_validate_payload "$APP_ROOT" "$INSTALL_DIR"

info "==> Writing launcher"
cp "$SCRIPT_DIR/launcher/start.sh.template" "$INSTALL_DIR/start.sh"
chmod +x "$INSTALL_DIR/start.sh" "$INSTALL_DIR/electron" 2>/dev/null || true

info "==> Writing build-info.json"
cat > "$INSTALL_DIR/build-info.json" <<EOF
{
  "product": "TRAE SOLO",
  "upstream_version": "$APP_VERSION",
  "payload_version": "$PAYLOAD_VERSION",
  "electron_version": "$ELECTRON_VERSION",
  "electron_source": "vendor/bytedance-electron-linux-x64/runtime",
  "donor_deb_version": "$DONOR_VER",
  "target_arch": "linux-$TRAE_ELECTRON_ARCH",
  "app_id": "$TRAE_APP_ID",
  "unofficial": true
}
EOF

info "==> Done. Launch with: $INSTALL_DIR/start.sh"
