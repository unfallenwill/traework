#!/usr/bin/env bash
# Apply Linux-native components vendored from the official Trae Linux package
# and reject critical macOS binaries before packaging.
# shellcheck shell=bash

linux_overlay_install() {
  local app_root="$1" vendor="$2"
  local overlay="$vendor/app-overlay"
  local replace_paths="$vendor/overlay-replace-paths.txt"
  [ -d "$overlay" ] || die "Vendored Linux overlay missing: $overlay"
  [ -f "$replace_paths" ] || die "Vendored overlay manifest missing: $replace_paths"

  local donor_app_version app_version
  donor_app_version="$(node -p "require('$vendor/manifest.json').donor_app_version" 2>/dev/null || true)"
  app_version="$(node -p "require('$app_root/package.json').version" 2>/dev/null || true)"
  if [ -n "$donor_app_version" ] && [ -n "$app_version" ] && [ "$donor_app_version" != "$app_version" ]; then
    if [ "${TRAE_ALLOW_VENDOR_VERSION_MISMATCH:-0}" != 1 ]; then
      die "Linux overlay version mismatch: donor=$donor_app_version, DMG=$app_version
Set TRAE_ALLOW_VENDOR_VERSION_MISMATCH=1 only after verifying the private ABI."
    fi
    warn "Using mismatched Linux overlay: donor=$donor_app_version, DMG=$app_version"
  fi

  info "Applying vendored Linux native overlay"
  local rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in
      /*|*../*) die "Unsafe overlay replacement path: $rel" ;;
    esac
    rm -rf "$app_root/$rel"
  done < "$replace_paths"
  cp -a "$overlay/." "$app_root/"

  # Some Linux IPC probes can emit an empty message during startup. The
  # upstream shared process assumes a base64 string and crashes on undefined,
  # taking settings/webview services with it. Treat that probe as an empty
  # frame; normal IPC messages are unchanged.
  local shared_process="$app_root/out/vs/code/electron-utility/sharedProcess/sharedProcessMain.js"
  if [ -f "$shared_process" ]; then
    perl -0pi -e 's/Buffer\.from\(h,"base64"\)/Buffer.from(h ?? "","base64")/g' "$shared_process"
  fi

  # Remove packages/assets that can only run on macOS. Linux alternatives were
  # installed above where they exist.
  rm -rf \
    "$app_root/node_modules/@byted-fe/fd-darwin-x64" \
    "$app_root/node_modules/@byted-fe/ripgrep-darwin-x64" \
    "$app_root/extensions/byted-solo.builtin-mcp/node_modules/@byted-solo/mac-computer-use" \
    "$app_root/extensions/byted-solo.builtin-mcp/node_modules/koffi/build/koffi/darwin_x64"
  find "$app_root/node_modules/@aha-kit" -mindepth 1 -maxdepth 1 -type d -name '*darwin*' -exec rm -rf {} + 2>/dev/null || true
  find "$app_root/extensions/byted-solo.integrations-extended/dist" -maxdepth 2 -type f \
    \( -name '*darwin*' -o -name '*:com.apple.cs.*' \) -delete 2>/dev/null || true

  # TRAE WORK bundles macOS ffmpeg/ffprobe executables. The Linux package uses
  # distro ffmpeg through these stable app-local shims.
  linux_write_tool_shim "$app_root/bin/ffmpeg" ffmpeg
  linux_write_tool_shim "$app_root/bin/ffprobe" ffprobe

  # The upstream .icns is the authoritative TRAE WORK icon. packaging/build.sh
  # renders it for hicolor; put the same image where VS Code's Linux main
  # process expects its BrowserWindow icon.
  local packaged_icon="$ROOT/packaging/icons/trae-solo/hicolor/512x512/apps/trae-solo.png"
  if [ -f "$packaged_icon" ]; then
    mkdir -p "$app_root/resources/linux"
    cp -a "$packaged_icon" "$app_root/resources/linux/code.png"
  fi
}

linux_write_tool_shim() {
  local target="$1" tool="$2"
  mkdir -p "$(dirname "$target")"
  rm -f "$target"
  cat > "$target" <<EOF
#!/bin/sh
command -v $tool >/dev/null 2>&1 || {
  echo "TRAE SOLO requires the '$tool' system package" >&2
  exit 127
}
exec $tool "\$@"
EOF
  chmod 0755 "$target"
}

linux_prune_foreign_binaries() {
  local app_root="$1" removed=0 kind file_path
  info "Pruning remaining Mach-O/PE binaries from Linux payload"
  while IFS= read -r -d '' file_path; do
    kind="$(file -b "$file_path" 2>/dev/null || true)"
    case "$kind" in
      Mach-O*|PE32*)
        rm -f "$file_path"
        removed=$((removed + 1))
        ;;
    esac
  done < <(find "$app_root" -type f -print0)
  info "Removed $removed foreign executable/native-addon files"
}

linux_validate_payload() {
  local app_root="$1" install_root="$2"
  local -a required=(
    "$install_root/electron"
    "$app_root/modules/ai-agent/libai_agent.so"
    "$app_root/modules/ckg/binary/libckg.so"
    "$app_root/modules/browser-bridge/browser-bridge"
    "$app_root/modules/sandbox/trae-sandbox"
    "$app_root/node_modules/node-pty/build/Release/pty.node"
    "$app_root/node_modules/native-keymap/build/Release/keymapping.node"
    "$app_root/node_modules/registry-js/build/Release/registry.node"
  )
  local f kind
  for f in "${required[@]}"; do
    [ -f "$f" ] || die "Required Linux component missing: $f"
    kind="$(file -b "$f")"
    case "$kind" in
      ELF\ 64-bit*) ;;
      *) die "Required component is not a Linux ELF: $f ($kind)" ;;
    esac
  done

  local foreign
  foreign="$(find "$app_root" -type f -print0 | xargs -0 -r file | grep -E 'Mach-O|PE32' | head -20 || true)"
  [ -z "$foreign" ] || die "Foreign binaries remain in Linux payload:
$foreign"
  info "Linux payload validation passed"
}
