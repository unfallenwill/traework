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

DMG=""
INSTALL_DIR="$SCRIPT_DIR/build/trae-solo"
ARCH="x64"   # internal default; only x64 is supported

usage() {
  cat <<EOF
Usage: $0 --dmg <path> --electron-deb <path> [--install-dir <dir>]
  --dmg <path>          macOS DMG to convert (or set TRAE_UPSTREAM_DMG_URL)
  --electron-deb <path> official Trae-linux-x64.deb = donor for the patched
                         Electron runtime (aha* exports). Or set TRAE_ELECTRON_DEB.
  --install-dir <dir>   output dir (default: build/trae-solo)
  --arch <x64>          target Linux architecture (default: x64)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dmg)         DMG="$2"; shift 2 ;;
    --electron-deb) TRAE_ELECTRON_DEB="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --arch)        ARCH="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

require_cmd 7z curl perl node npm python3 unzip tar file strings dpkg-deb find
resolve_arch "$ARCH"

# Resolve the donor Electron .deb -- REQUIRED. Trae imports proprietary aha*
# exports from 'electron' that exist only in ByteDance's patched Electron,
# which we extract from the official Trae Linux package. See lib_electron.sh.
if [ -z "${TRAE_ELECTRON_DEB:-}" ]; then
  for _d in "$TRAE_CACHE_DIR" "$HOME/下载" "$HOME/Downloads" "."; do
    _f="$(ls "$_d"/Trae-linux-x64*.deb "$_d"/trae_*_amd64.deb 2>/dev/null | head -1)"
    [ -n "$_f" ] && { TRAE_ELECTRON_DEB="$_f"; break; }
  done
fi
if [ -z "${TRAE_ELECTRON_DEB:-}" ] || [ ! -f "$TRAE_ELECTRON_DEB" ]; then
  die "Donor Electron .deb is required.
  Trae imports proprietary aha* APIs from 'electron' that only ByteDance's
  patched Electron provides. Pass --electron-deb /path/to/Trae-linux-x64.deb
  (or set TRAE_ELECTRON_DEB)."
fi
info "Donor Electron: $TRAE_ELECTRON_DEB"

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
info "$APP_DISPLAY $APP_VERSION / Electron $ELECTRON_VERSION / target linux-$TRAE_ELECTRON_ARCH"

# Cross-check the DMG Trae version against the donor .deb. The aha* API surface
# is stable within a Trae release line, but a drift is worth warning about.
DONOR_VER="$(dpkg-deb -f "$TRAE_ELECTRON_DEB" Version 2>/dev/null || true)"
if [ -n "$DONOR_VER" ] && [ -n "$APP_VERSION" ]; then
  case "$DONOR_VER" in
    "$APP_VERSION"|"$APP_VERSION"-*)
      info "Version match: DMG $APP_VERSION == donor $DONOR_VER" ;;
    *)
      warn "Version mismatch: DMG payload=$APP_VERSION, donor Electron=$DONOR_VER"
      warn "  aha* API drift between Trae versions may cause runtime errors." ;;
  esac
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

info "==> Stripping macOS/Windows-only addons (GUI)"
if [ -d "$APP_ROOT/node_modules" ]; then
  native_strip_macos "$APP_ROOT/node_modules"
  native_install_ripgrep_linux "$APP_ROOT/node_modules"
fi

info "==> Installing ByteDance forked Linux Electron (from donor .deb)"
electron_install "$TRAE_ELECTRON_DEB" "$INSTALL_DIR"

info "==> Rebuilding native modules against Linux Electron"
native_electron_rebuild "$APP_ROOT" "$INSTALL_DIR" "$ELECTRON_VERSION" "$TRAE_ELECTRON_ARCH"

info "==> Writing launcher"
cp "$SCRIPT_DIR/launcher/start.sh.template" "$INSTALL_DIR/start.sh"
chmod +x "$INSTALL_DIR/start.sh" "$INSTALL_DIR/electron" 2>/dev/null || true

info "==> Writing build-info.json"
cat > "$INSTALL_DIR/build-info.json" <<EOF
{
  "product": "TRAE SOLO",
  "upstream_version": "$APP_VERSION",
  "electron_version": "$ELECTRON_VERSION",
  "electron_source": "bytedance-fork (donor Trae-linux-x64.deb)",
  "donor_deb_version": "$DONOR_VER",
  "target_arch": "linux-$TRAE_ELECTRON_ARCH",
  "app_id": "$TRAE_APP_ID",
  "unofficial": true
}
EOF

info "==> Done. Launch with: $INSTALL_DIR/start.sh"
