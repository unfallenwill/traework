#!/usr/bin/env bash
# One-time extraction of ByteDance's patched Linux Electron and the matching
# Linux-native TRAE components. The resulting vendor/ tree is the normal build
# input and is tracked with Git LFS; install.sh never needs to unpack the .deb.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib_common.sh
. "$SCRIPT_DIR/lib_common.sh"

DEB="${1:-${TRAE_ELECTRON_DEB:-}}"
[ -n "$DEB" ] && [ -f "$DEB" ] || die "Usage: $0 /path/to/Trae-linux-x64.deb"
require_cmd dpkg-deb find file grep sha256sum node

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
dpkg-deb -x "$DEB" "$WORK/root"

runtime="$(find "$WORK/root" -type f -name icudtl.dat -printf '%h\n' 2>/dev/null | head -1)"
[ -n "$runtime" ] || die "No Electron runtime found inside $DEB"
app="$runtime/resources/app"
[ -f "$app/package.json" ] || die "No resources/app payload found beside donor Electron"

bin="$runtime/trae"
[ -f "$bin" ] || bin="$runtime/electron"
[ -f "$bin" ] || die "No trae/electron binary found in $runtime"
grep -aq 'ahaNet' "$bin" && grep -aq 'ahaDeviceService' "$bin" ||
  die "The donor is not ByteDance's patched Electron (aha* symbols missing)"

stage="$WORK/bytedance-electron-linux-x64"
runtime_out="$stage/runtime"
overlay="$stage/app-overlay"
mkdir -p "$runtime_out" "$overlay"

info "Copying patched Electron runtime"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  case "$name" in
    resources|node_modules|bin) continue ;;
  esac
  cp -a "$runtime/$name" "$runtime_out/"
done < <(find "$runtime" -mindepth 1 -maxdepth 1 -printf '%f\n')
if [ -f "$runtime_out/trae" ]; then
  mv "$runtime_out/trae" "$runtime_out/electron"
  [ ! -f "$runtime_out/trae.asc" ] || mv "$runtime_out/trae.asc" "$runtime_out/electron.asc"
fi
chmod 0755 "$runtime_out/electron" "$runtime_out/chrome-sandbox" "$runtime_out/chrome_crashpad_handler" 2>/dev/null || true

replace_paths="$stage/overlay-replace-paths.txt"
: > "$replace_paths"
copy_replace() {
  local source_rel="$1" target_rel="${2:-$1}"
  [ -e "$app/$source_rel" ] || { warn "Donor overlay path missing: $source_rel"; return 0; }
  mkdir -p "$overlay/$(dirname "$target_rel")"
  cp -a "$app/$source_rel" "$overlay/$target_rel"
  printf '%s\n' "$target_rel" >> "$replace_paths"
}

info "Copying Linux modular services"
copy_replace modules/ai-agent
copy_replace modules/ckg
copy_replace modules/browser-bridge
copy_replace modules/sandbox

# These packages contain the native executables/addons from the official Linux
# build. Copying the complete package keeps its JS loader and native ABI in
# lockstep. This is more reliable than npm's occasionally missing prebuilds.
linux_packages=(
  windows-foreground-love
  registry-js
  node-pty
  native-watchdog
  native-keymap
  native-is-elevated
  kerberos
  @vscode/vsce-sign
  @vscode/sqlite3
  @vscode/spdlog
  @vscode/ripgrep
  @vscode/policy-watcher
  @vscode/native-watchdog
  @vscode/deviceid
  @parcel/watcher
  @byted-icube/trae-macos-native
  @byted-icube/trae-network-client-linux-x64-gnu
  @byted-fe/ripgrep-linux-x64
  @byted-fe/ripgrep-linux-musl-x64
  @byted-fe/fd-linux-x64
  @byted-fe/fd-linux-musl-x64
  @aha-kit/perf-sdk-linux-x64
  @aha-kit/net-linux-x64-gnu
  @aha-kit/ipc-linux-x64
)
info "Copying Linux native npm packages"
for pkg in "${linux_packages[@]}"; do
  copy_replace "node_modules/$pkg"
done

# Same extension and native dependency, but the plain Trae donor and TRAE SOLO
# use different extension directory prefixes. Only map the platform assets;
# the extension JS itself must continue to come from the SOLO DMG.
copy_replace \
  extensions/byted-solo.builtin-mcp/node_modules/koffi \
  extensions/byted-solo.builtin-mcp/node_modules/koffi

integration_src="extensions/byted-icube.integrations-extended/dist"
integration_dst="$overlay/extensions/byted-solo.integrations-extended/dist"
mkdir -p "$integration_dst/bundled"
for asset in skia.linux-x64-gnu.node skia.linux-x64-musl.node; do
  [ ! -f "$app/$integration_src/$asset" ] || cp -a "$app/$integration_src/$asset" "$integration_dst/"
done
for asset in "$app/$integration_src"/bundled/node-*-linux-x64.tar.xz; do
  [ -f "$asset" ] || continue
  cp -a "$asset" "$integration_dst/bundled/"
done

donor_version="$(dpkg-deb -f "$DEB" Version 2>/dev/null || true)"
donor_app_version="$(node -p "require('$app/package.json').version" 2>/dev/null || true)"
deb_sha256="$(sha256sum "$DEB" | awk '{print $1}')"
cat > "$stage/manifest.json" <<EOF
{
  "source_package": "$(basename "$DEB")",
  "source_package_version": "$donor_version",
  "source_package_sha256": "$deb_sha256",
  "donor_app_version": "$donor_app_version",
  "electron_version": "39.2.7",
  "target": "linux-x64",
  "contains": ["bytedance-electron-runtime", "trae-linux-native-overlay"]
}
EOF
( cd "$stage" && find runtime app-overlay -type f -print0 | sort -z | xargs -0 sha256sum ) > "$stage/files.sha256"

[ -x "$runtime_out/electron" ] || die "Vendored Electron is not executable"
file "$runtime_out/electron" | grep -q 'ELF 64-bit' || die "Vendored Electron is not an x86-64 ELF"
for required in \
  modules/ai-agent/libai_agent.so \
  modules/ckg/binary/libckg.so \
  modules/browser-bridge/browser-bridge \
  modules/sandbox/trae-sandbox; do
  [ -f "$overlay/$required" ] || die "Required Linux overlay component missing: $required"
done

vendor="$ROOT/vendor/bytedance-electron-linux-x64"
mkdir -p "$ROOT/vendor"
rm -rf "$vendor"
cp -a "$stage" "$vendor"

if ! git lfs version >/dev/null 2>&1; then
  warn "git-lfs is not installed. Install it before git add/commit; .gitattributes is already configured."
fi
info "Vendored runtime written to $vendor"
du -sh "$vendor"

