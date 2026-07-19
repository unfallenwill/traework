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

# $1 = path to the donor official Trae-linux-x64.deb
# $2 = install root dir (the future /opt/trae-solo)
electron_install() {
  local deb="$1" dest="$2"
  [ -f "$deb" ] || die "Donor Electron .deb not found: $deb
  Trae needs ByteDance's patched Electron (it imports aha* from 'electron').
  Pass --electron-deb /path/to/Trae-linux-x64.deb (or set TRAE_ELECTRON_DEB)."

  mkdir -p "$dest"
  require_cmd dpkg-deb find

  # Reusable extraction scratch under the cache dir (avoids leaking mktemp dirs
  # on die(); re-runs just re-extract over the top).
  local scratch="$TRAE_CACHE_DIR/_electron_runtime"
  rm -rf "$scratch"; mkdir -p "$scratch"
  info "Unpacking donor Electron from ${deb##*/} ..."
  dpkg-deb -x "$deb" "$scratch/root" || die "dpkg-deb extraction failed for $deb"

  # Locate the runtime dir. Official Trae installs under /usr/share/trae; we
  # auto-detect via icudtl.dat (always shipped next to the Electron binary) and
  # allow TRAE_DEB_RUNTIME_DIR to override for future layout changes.
  local root="$scratch/root"
  local runtime="${TRAE_DEB_RUNTIME_DIR:-}"
  if [ -z "$runtime" ]; then
    runtime="$(find "$root" -type f -name icudtl.dat -printf '%h\n' 2>/dev/null | head -1)"
    [ -n "$runtime" ] || die "No Electron runtime found inside $deb (missing icudtl.dat)."
  else
    runtime="$root/${runtime#/}"
  fi
  info "Runtime dir: ${runtime#$root}"

  # Find the Electron binary (donor names it 'trae'; stock would be 'electron').
  local bin=""
  local cand
  for cand in "$runtime/trae" "$runtime/electron"; do
    [ -f "$cand" ] && { bin="$cand"; break; }
  done
  [ -n "$bin" ] || die "Electron binary not found in $runtime"

  # Guardrail: refuse a non-fork donor. Stock Electron would reintroduce the
  # ahaDeviceService SyntaxError, so fail loudly rather than ship a broken app.
  if ! grep -aq 'ahaNet' "$bin" || ! grep -aq 'ahaDeviceService' "$bin"; then
    die "Donor $deb does not look like ByteDance's patched Electron
  (binary lacks the ahaNet/ahaDeviceService symbols). Stock Electron cannot
  host Trae's payload. Use the official Trae-linux-x64.deb as --electron-deb."
  fi

  # Copy the runtime tree, EXCLUDING the donor's app payload + packaging extras:
  #   resources/  -> we stage the DMG payload into resources/app ourselves
  #   node_modules/ -> DMG payload carries its own (native-swapped) node_modules
  #   bin/        -> trae-solo's launcher replaces the CLI shim
  info "Copying Electron runtime -> $dest"
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in
      resources|node_modules|bin) continue ;;   # provided by DMG payload / launcher
    esac
    cp -a "$runtime/$name" "$dest/"
  done < <(find "$runtime" -mindepth 1 -maxdepth 1 -printf '%f\n')

  # Rename the binary so the launcher's `exec $SCRIPT_DIR/electron` resolves.
  if [ -f "$dest/trae" ] && [ ! -e "$dest/electron" ]; then
    mv "$dest/trae" "$dest/electron"
    [ -f "$dest/trae.asc" ] && mv "$dest/trae.asc" "$dest/electron.asc"
  elif [ -f "$dest/trae" ] && [ -f "$dest/electron" ]; then
    rm -f "$dest/trae" "$dest/trae.asc"
  fi

  chmod +x "$dest/electron" "$dest/chrome-sandbox" "$dest/chrome_crashpad_handler" 2>/dev/null || true
  [ -x "$dest/electron" ] || die "Electron binary not executable after install: $dest/electron"
  if [ ! -f "$dest/chrome-sandbox" ]; then
    warn "chrome-sandbox missing from donor; launcher will fall back to --no-sandbox."
  fi

  info "Electron runtime installed (forked build, aha* exports present)."
}
