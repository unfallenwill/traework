#!/usr/bin/env bash
# Build .deb and .rpm for TRAE SOLO (one arch) from a macOS DMG.
#
#   DMG="/path/to/TRAE_Work-darwin-x64.dmg" ./packaging/build.sh
#
# Env:
#   PRODUCT_VERSION  upstream version (auto-detected from the DMG if unset)
#   DMG              path to a local DMG
#   DMG_URL          URL to download the DMG from (used if DMG is unset)
#   The ByteDance Electron runtime is vendored in the repository; refresh it
#   separately with scripts/vendor_linux_runtime.sh when the donor changes.
#   ARCH             target arch (default: x64)
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib_common.sh
. "$ROOT/scripts/lib_common.sh"

ARCH="${ARCH:-x64}"
DMG="${DMG:-}"
DMG_URL="${DMG_URL:-}"
PRODUCT_VERSION="${PRODUCT_VERSION:-}"
require_cmd curl nfpm perl node 7z python3

resolve_arch "$ARCH"   # exports TRAE_DEB_ARCH, TRAE_RPM_ARCH, TRAE_NPM_ARCH, TRAE_ELECTRON_ARCH

# ---- Resolve the DMG --------------------------------------------------------
if [ -z "$DMG" ]; then
  [ -n "$DMG_URL" ] || die "Provide DMG=<path> or DMG_URL=<url>."
  mkdir -p "$TRAE_CACHE_DIR"
  DMG="$TRAE_CACHE_DIR/trae-solo.dmg"
  info "Downloading DMG from $DMG_URL ..."
  curl -fL --retry 3 -o "$DMG" "$DMG_URL"
fi
[ -f "$DMG" ] || die "DMG not found: $DMG"

BUILD="$ROOT/build"
DIST="$ROOT/dist"
PAYLOAD="$BUILD/payload"
mkdir -p "$DIST" "$BUILD/scripts"

# ---- Build the runnable Linux app -------------------------------------------
info "==> Building app (arch=$ARCH) from $DMG"
rm -rf "$PAYLOAD"
"$ROOT/install.sh" --dmg "$DMG" --install-dir "$PAYLOAD" --arch "$ARCH"

# ---- Version ----------------------------------------------------------------
if [ -z "$PRODUCT_VERSION" ]; then
  # Official CDN URLs carry the release version in /stable/<version>/darwin/.
  # Prefer that authoritative release identifier over the stale macOS
  # CFBundleShortVersionString (older TRAE Work DMGs reported 0.1.36 there).
  if [ -n "$DMG_URL" ]; then
    PRODUCT_VERSION="$(printf '%s\n' "$DMG_URL" | sed -nE 's#^.*/stable/([^/]+)/darwin/.*#\1#p' | head -1)"
  fi
  if [ -z "$PRODUCT_VERSION" ]; then
    PRODUCT_VERSION="$(node -e "console.log(require('$PAYLOAD/build-info.json').upstream_version)")"
  fi
fi
ELECTRON_VERSION="$(node -e "console.log(require('$PAYLOAD/build-info.json').electron_version)")"
info "Packaging TRAE SOLO $PRODUCT_VERSION (Electron $ELECTRON_VERSION) $TRAE_DEB_ARCH/$TRAE_RPM_ARCH"

# ---- Icons ------------------------------------------------------------------
# install.sh copies the upstream .icns into payload/Resources; re-render into
# the packaging icons tree so the generated .deb/.rpm carry a full hicolor set.
ICNS="$PAYLOAD/Resources/TRAE SOLO.icns"
if [ -f "$ICNS" ]; then
  TRAE_PKG_NAME="$TRAE_PKG_NAME" "$ROOT/packaging/extract-icon.sh" "$ICNS" >/dev/null
fi
# Also accept the modern location some DMGs use.
ICNS2="$PAYLOAD/resources/TRAE SOLO.icns"
if [ ! -f "$ICNS" ] && [ -f "$ICNS2" ]; then
  TRAE_PKG_NAME="$TRAE_PKG_NAME" "$ROOT/packaging/extract-icon.sh" "$ICNS2" >/dev/null
fi

# ---- Render templates (perl ${VAR}) -----------------------------------------
render() { perl -pe 's/\$\{(\w+)\}/defined $ENV{$1} ? $ENV{$1} : ""/ge' "$1" > "$2"; }

PKG_NAME="$TRAE_PKG_NAME" \
DISPLAY="$TRAE_DISPLAY" WMCLASS="$TRAE_WMCLASS" \
TRAE_SCHEME="$TRAE_SCHEME" \
INSTALL_PREFIX="$TRAE_INSTALL_PREFIX" \
VERSION="$PRODUCT_VERSION" ELECTRON_VERSION="$ELECTRON_VERSION" \
NFPM_ARCH="$TRAE_DEB_ARCH" \
  render "$ROOT/packaging/templates/nfpm.yaml.tmpl" "$BUILD/nfpm.yaml"
PKG_NAME="$TRAE_PKG_NAME" DISPLAY="$TRAE_DISPLAY" WMCLASS="$TRAE_WMCLASS" \
TRAE_SCHEME="$TRAE_SCHEME" \
  render "$ROOT/packaging/templates/desktop.tmpl" "$BUILD/$TRAE_PKG_NAME.desktop"
PKG_NAME="$TRAE_PKG_NAME" INSTALL_PREFIX="$TRAE_INSTALL_PREFIX" \
  render "$ROOT/packaging/templates/wrapper.tmpl" "$BUILD/wrapper"
INSTALL_PREFIX="$TRAE_INSTALL_PREFIX" \
  render "$ROOT/packaging/templates/postinst.tmpl" "$BUILD/scripts/postinst"
INSTALL_PREFIX="$TRAE_INSTALL_PREFIX" \
  render "$ROOT/packaging/templates/prerm.tmpl" "$BUILD/scripts/prerm"
INSTALL_PREFIX="$TRAE_INSTALL_PREFIX" \
  render "$ROOT/packaging/templates/postrm.tmpl" "$BUILD/scripts/postrm"
chmod +x "$BUILD/wrapper" "$BUILD/scripts/postinst" "$BUILD/scripts/prerm" "$BUILD/scripts/postrm"

# ---- Package ----------------------------------------------------------------
DEB_NAME="${TRAE_PKG_NAME}_${PRODUCT_VERSION}_${TRAE_DEB_ARCH}.deb"
RPM_NAME="${TRAE_PKG_NAME}-${PRODUCT_VERSION}.${TRAE_RPM_ARCH}.rpm"

info "==> Building .deb"
( cd "$ROOT" && nfpm package --config build/nfpm.yaml --packager deb --target "$DIST/$DEB_NAME" )
info "==> Building .rpm"
( cd "$ROOT" && nfpm package --config build/nfpm.yaml --packager rpm --target "$DIST/$RPM_NAME" )

( cd "$DIST" && sha256sum "$DEB_NAME" "$RPM_NAME" > "checksums_${TRAE_PKG_NAME}_${PRODUCT_VERSION}_${TRAE_DEB_ARCH}.txt" )

info "==> Built:"
ls -lh "$DIST/$DEB_NAME" "$DIST/$RPM_NAME" "$DIST/checksums_${TRAE_PKG_NAME}_${PRODUCT_VERSION}_${TRAE_DEB_ARCH}.txt"
