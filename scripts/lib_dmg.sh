#!/usr/bin/env bash
# DMG handling: locate/download, extract, and metadata detection.
# Pattern learned from codex-desktop-linux / minimax-code-linux: 7z reads the
# UDIF/HFS+ image directly; the bundled Electron version is read from the
# framework Info.plist; the marketing version comes from the app's Info.plist.
# shellcheck shell=bash

# Resolve the DMG to use. If $1 is an existing path, use it; otherwise download
# from $TRAE_UPSTREAM_DMG_URL. Echoes the local DMG path.
dmg_resolve() {
  local dmg="${1:-}"
  if [ -n "$dmg" ] && [ -f "$dmg" ]; then echo "$dmg"; return 0; fi
  [ -n "$TRAE_UPSTREAM_DMG_URL" ] || die "No DMG provided. Pass --dmg <path> or set TRAE_UPSTREAM_DMG_URL."
  mkdir -p "$TRAE_CACHE_DIR"
  local dest="$TRAE_CACHE_DIR/trae-solo.dmg"
  info "Downloading DMG from $TRAE_UPSTREAM_DMG_URL ..."
  curl -fL --retry 3 --connect-timeout 30 -o "$dest" "$TRAE_UPSTREAM_DMG_URL" \
    || die "DMG download failed"
  echo "$dest"
}

# Extract a DMG into $2 and echo the path to the *.app bundle inside it.
dmg_extract() {
  local dmg="$1" dest="$2"
  mkdir -p "$dest"
  info "Extracting DMG with 7z ..."
  local log="$dest/7z-extract.log"
  # 7z reads UDIF/HFS+ directly. It often exits non-zero on these images even
  # when extraction succeeds, so we check for the app bundle rather than the rc.
  7z x -y -bd -o"$dest" "$dmg" >"$log" 2>&1 || warn "7z reported errors (often benign for UDIF); see $log"
  local app
  # The DMG has a top-level directory (e.g. "TRAE Work/") containing the .app.
  app="$(find "$dest" -mindepth 2 -maxdepth 6 -name "*.app" -type d 2>/dev/null | head -1 || true)"
  [ -n "$app" ] || die "No .app bundle found inside DMG extraction"
  info "Found app bundle: $(basename "$app")"
  echo "$app"
}

# Read a value from a (binary or XML) Info.plist via python3 plistlib.
# $1 = plist path, $2 = key
_plist_get() {
  python3 - "$1" "$2" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    v = plistlib.load(f).get(sys.argv[2], "")
print("" if v is None else (v if isinstance(v, str) else str(v)))
PY
}

# Detect the Electron version the app was built with. Echoes e.g. 39.2.7.
dmg_detect_electron() {
  local app="$1"
  local plist="$app/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources/Info.plist"
  local v=""
  [ -f "$plist" ] && v="$(_plist_get "$plist" CFBundleVersion)"
  if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    info "Detected Electron: $v"; echo "$v"; return 0
  fi
  warn "Could not detect Electron from framework plist; using fallback $TRAE_ELECTRON_FALLBACK"
  echo "$TRAE_ELECTRON_FALLBACK"
}

# Read the app's marketing version, e.g. 0.1.36.
dmg_app_version() {
  local app="$1" v
  v="$(_plist_get "$app/Contents/Info.plist" CFBundleShortVersionString)"
  [ -n "$v" ] && echo "$v" || echo "0.0.0"
}

# Read the app's display name (CFBundleDisplayName).
dmg_app_display_name() {
  local app="$1" v
  v="$(_plist_get "$app/Contents/Info.plist" CFBundleDisplayName)"
  [ -n "$v" ] && echo "$v" || echo "TRAE SOLO"
}
