#!/usr/bin/env bash
# Shared constants, logging, and helpers for the TRAE SOLO Linux build.
# Sourced by install.sh and scripts/lib_*.sh. Do not execute directly.
# shellcheck shell=bash

set -o pipefail

# ---- Identity (overridable via env) ----
: "${TRAE_APP_ID:=com.trae.solo.app}"
: "${TRAE_PKG_NAME:=trae-solo}"
: "${TRAE_DISPLAY:=TRAE SOLO}"
: "${TRAE_WMCLASS:=trae-solo}"
: "${TRAE_BIN:=trae-solo}"
: "${TRAE_INSTALL_PREFIX:=/opt/trae-solo}"      # in-package path used by nfpm templates
: "${TRAE_SCHEME:=solo}"
: "${TRAE_ELECTRON_FALLBACK:=39.2.7}"
# IMPORTANT: Trae's main-process JS imports proprietary extensions (ahaNet,
# ahaDeviceService, ahaReporter, ahaIpc, ahaDoctor, ahaPerf, ...) from the
# `electron` module. Those exports exist ONLY in ByteDance's patched Electron
# (@aha-kit/electron) — upstream electron/electron does NOT provide them and
# crashes at ESM import ("...does not provide an export named 'ahaDeviceService'").
# The only public source of the fork's Linux build is the official Trae Linux
# package. We extract that runtime from the donor .deb below.
: "${TRAE_ELECTRON_DEB:=}"                     # donor official Trae-linux-x64.deb (REQUIRED runtime source)
: "${TRAE_DEB_RUNTIME_DIR:=}"                  # override runtime subdir inside the deb (default: auto-detect)
: "${TRAE_UPSTREAM_DMG_URL:=}"                  # set for CI auto-download; empty => require --dmg
: "${TRAE_CACHE_DIR:=$HOME/.cache/trae-solo-linux}"

# ---- Logging ----
_log() { printf '%s\n' "$*" >&2; }
info() { _log "[info] $*"; }
warn() { _log "[warn] $*"; }
die()  { _log "[error] $*"; exit 1; }

# ---- Helpers ----
# Fail if any of the listed commands is missing.
require_cmd() {
  local missing=() c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [ "${#missing[@]}" -eq 0 ] || die "Missing required commands: ${missing[*]}"
}

# Map a friendly arch token to npm/electron/deb/rpm arch strings.
# $1 = x64 ; exports TRAE_ELECTRON_ARCH TRAE_NPM_ARCH TRAE_DEB_ARCH TRAE_RPM_ARCH
resolve_arch() {
  case "$1" in
    x64|amd64)
      TRAE_ELECTRON_ARCH=x64 TRAE_NPM_ARCH=x64 TRAE_DEB_ARCH=amd64 TRAE_RPM_ARCH=x86_64 ;;
    *)
      die "Unknown arch '$1' (only x64 is supported)" ;;
  esac
  export TRAE_ELECTRON_ARCH TRAE_NPM_ARCH TRAE_DEB_ARCH TRAE_RPM_ARCH
}
