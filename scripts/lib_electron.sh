#!/usr/bin/env bash
# Install ByteDance's forked Linux Electron runtime into the install root.
#
# WHY THIS EXISTS (read before "simplifying" back to upstream Electron):
#
# Trae's main-process JS does `import { ahaNet, ahaDeviceService, ahaReporter,
# ahaIpc, ahaDoctor, ahaPerf, ... } from "electron"`. Those named exports are
# NOT part of upstream Electron — they are ByteDance proprietary extensions
# added by their patched Electron fork (@aha-kit/electron, v39.x). Stock
# electron/electron does not export them, so the very first such import fails
# at ESM link time with a fatal SyntaxError and the main process dies before
# any window opens ("无法启动"). The crash is unrecoverable: you cannot add
# named ESM exports to the `electron` built-in from JS land, and stubbing the
# APIs breaks networking/auth (Trae routes AI requests + login through ahaNet /
# TTNet and reads device identity from ahaDeviceService).
#
# The fork's Linux build is not on npm (@aha-kit/electron → 404) and the macOS
# DMG only ships a Mach-O Framework (unusable on Linux). The one public source
# is the official Trae Linux package: its /usr/share/trae tree contains the
# patched `trae` binary (RPATH=$ORIGIN) plus the ByteDance shared libraries the
# aha* APIs link/dlopen — libaha_net.so, libsscronet.so, liblogifier_retrieval.so,
# libsimplelog.so — alongside the usual Electron runtime files.
#
# So we unpack the donor .deb, copy that runtime tree into the install root,
# and rename `trae` -> `electron` so trae-solo's launcher ($SCRIPT_DIR/electron)
# finds it. We deliberately do NOT copy the donor's resources/ (its app payload,
# app-update.yml, completions/, linux/) or its node_modules/ / bin/: the DMG
# payload is staged into resources/app by install.sh, and packaging/ handles the
# rest. Renaming is safe because the binary resolves its libraries via $ORIGIN,
# not by its own filename.
# shellcheck shell=bash

# The donor is extracted once by scripts/vendor_linux_runtime.sh and committed
# under vendor/ with Git LFS. Normal builds copy that ready-to-run tree.
#
# $1 = install root dir (the future /opt/trae-solo)
electron_install() {
  local dest="$1"
  local runtime="$TRAE_VENDOR_DIR/runtime"
  local bin="$runtime/electron"
  [ -f "$TRAE_VENDOR_DIR/manifest.json" ] || die "Vendored runtime is missing.
Run: scripts/vendor_linux_runtime.sh /path/to/Trae-linux-x64.deb"
  [ -x "$bin" ] || die "Vendored Electron binary missing or not executable: $bin"
  mkdir -p "$dest"

  # Guardrail: refuse a non-fork donor. Stock Electron would reintroduce the
  # ahaDeviceService SyntaxError, so fail loudly rather than ship a broken app.
  if ! grep -aq 'ahaNet' "$bin" || ! grep -aq 'ahaDeviceService' "$bin"; then
    die "Vendored runtime does not look like ByteDance's patched Electron
  (binary lacks the ahaNet/ahaDeviceService symbols). Stock Electron cannot
  host Trae's payload. Refresh vendor/ from the official Trae Linux package."
  fi

  info "Copying vendored ByteDance Electron runtime -> $dest"
  cp -a "$runtime/." "$dest/"

  chmod +x "$dest/electron" "$dest/chrome-sandbox" "$dest/chrome_crashpad_handler" 2>/dev/null || true
  [ -x "$dest/electron" ] || die "Electron binary not executable after install: $dest/electron"
  if [ ! -f "$dest/chrome-sandbox" ]; then
    warn "chrome-sandbox missing from donor; launcher will fall back to --no-sandbox."
  fi

  TRAE_DONOR_VERSION="$(node -p "require('$TRAE_VENDOR_DIR/manifest.json').source_package_version" 2>/dev/null || true)"
  TRAE_DONOR_APP_VERSION="$(node -p "require('$TRAE_VENDOR_DIR/manifest.json').donor_app_version" 2>/dev/null || true)"
  export TRAE_DONOR_VERSION TRAE_DONOR_APP_VERSION
  info "Electron runtime installed from vendor/ (forked build, aha* exports present)."
}
