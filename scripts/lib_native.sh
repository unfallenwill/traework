#!/usr/bin/env bash
# Native-module handling for the TRAE SOLO Linux build.
#
# The TRAE DMG only ships macOS prebuilt binaries for every native addon
# (none of them include a Linux .so/.node in the published asar). We can't
# compile from source in this environment without distro dev libraries
# (libx11-dev, libxkbfile-dev, libkrb5-dev, libsecret-1-dev, ...), so the
# strategy here is:
#
#   1. Strip macOS/Windows-only addons so they don't load a darwin .node on
#      Linux.
#   2. For every addon that has a Linux prebuild published on npm, install
#      the same version with --include=optional so the matching
#      linux-x64-glibc prebuild (or napi-v3 binary) is dropped into our tree.
#   3. Only attempt source rebuilds for the modules whose prebuilds don't
#      match Electron's Node ABI (rare — most VS Code native deps use
#      napi-v3 which Electron exposes natively).
#
# This means a "native rebuild" pass becomes "fresh npm install of the same
# version" for modules whose upstream already publishes Linux prebuilds,
# which is exactly what we want for a host swap.
# electron_install must run before this file is sourced — we keep the
# unpacked Linux Electron available for any source-rebuild fallback.
# shellcheck shell=bash

# Strip modules that have no Linux equivalent. The DMG's compiled JS usually
# references them behind `try { require(...) } catch {}`, so removing the
# directory turns a darwin .node load into a synchronous throw — but Electron
# catches the throw and treats it as "feature not available on this platform".
native_strip_macos() {
  local root="$1"
  local d
  for d in \
      "@vscode/windows-mutex" \
      "windows-foreground-love" \
      "@vscode/deviceid"; do
    if [ -d "$root/$d" ]; then
      info "  removing macOS/Windows-only addon: $d"
      rm -rf "$root/$d"
    fi
  done
}

# @vscode/sudo-prompt uses gksudo on Linux, but the upstream wraps it in a
# feature-detect. No replacement is needed when gksudo/pkexec exist; on distro
# installs the postinst figures this out.
native_stub_mac_permissions() {
  return 0
}

# The upstream package uses an internal `@byted-fe/ripgrep-{darwin-x64,linux-x64}`
# split that is not on the public npm registry. The darwin prebuild is shipped
# in the DMG; on Linux the editor will fall back to its own search engine,
# which downloads a ripgrep binary at runtime.
native_install_ripgrep_linux() {
  return 0
}

# Modules whose upstream prebuilt Linux binaries we'd like to install. Order
# doesn't matter; --include=optional picks up the matching platform subpackage.
TRAE_NATIVE_MODULES_DEFAULT=(
  node-pty
  @vscode/sqlite3
  @vscode/spdlog
  @parcel/watcher
  native-keymap
  native-watchdog
  @vscode/policy-watcher
  kerberos
  native-is-elevated
)

# Read the version a module ships in the upstream DMG so we install the same
# one. Falls back to "latest" if the DMG doesn't carry it (rare for VS Code
# forks, but harmless).
native_read_version() {
  local pkg="$1" nm="$2"
  local scope_dir="$nm"
  local json_path
  if [[ "$pkg" == @*/* ]]; then
    scope_dir="$nm/${pkg%/*}"
    pkg="${pkg##*/}"
  fi
  json_path="$scope_dir/$pkg/package.json"
  if [ -f "$json_path" ]; then
    node -p "require('$json_path').version" 2>/dev/null || true
  fi
}

# Install a single module's Linux prebuild. Steps:
#   1. Stage a tiny package.json that declares only this module (with the
#      same version as the DMG), so npm resolves the right tarball.
#   2. `npm install --include=optional` so npm pulls the platform-specific
#      optionalDependencies (e.g. @parcel/watcher-linux-x64-glibc).
#   3. Move the installed tree into $nm/<path>.
#
# $1 = scratch dir (will be created)
# $2 = module spec (e.g. node-pty@1.1.0-beta43 or @vscode/sqlite3@5.1.7-vscode)
# $3 = target node_modules in the app
# $4 = install prefix (where electron lives; used for source-rebuild fallback)
native_install_one() {
  local scratch="$1" spec="$2" nm="$3" install_prefix="$4"
  local pkg="${spec%@*}"
  local ver="${spec##*@}"
  local scope="${pkg%/*}"

  mkdir -p "$scratch"
  cat > "$scratch/package.json" <<EOF
{ "private": true, "name": "trae-native-stage" }
EOF

  info "  installing $spec (+ prebuilt linux subpackages)"
  if ( cd "$scratch" \
       && npm install --no-audit --no-fund --silent --legacy-peer-deps --include=optional \
            "$spec" 2>&1 \
       | tail -8 ); then
    : # ok
  else
    warn "    npm install $spec failed; trying without version pin"
    ( cd "$scratch" \
      && npm install --no-audit --no-fund --silent --legacy-peer-deps --include=optional \
           "$pkg@latest" 2>&1 | tail -5 ) || warn "    fallback install $pkg@latest failed"
  fi

  # Move the installed tree into $nm.
  if [ -d "$scratch/node_modules/$pkg" ]; then
    local dest_dir="$nm/$scope"
    mkdir -p "$dest_dir"
    rm -rf "$dest_dir/${pkg##*/}"
    cp -a "$scratch/node_modules/$pkg" "$dest_dir/"
    info "    staged $spec -> $dest_dir/${pkg##*/}/"
  fi
}

# Build native modules in a clean staging dir against the unpacked Linux
# Electron, then copy the compiled .node binaries back into the app tree.
#
# $1 = app resources/app root (containing package.json + node_modules)
# $2 = install prefix (e.g. /opt/trae-solo or build/trae-solo) where electron lives
# $3 = electron version (e.g. 39.2.7)
# $4 = target arch (x64)
#
# This is intentionally a *fallback-first* strategy: most modules install
# clean from npm and pick up the matching linux prebuild. Anything that
# fails that path lands in $FAILED; we leave the DMG's macOS .node alone for
# those (a require() will throw, which the upstream code catches).
native_electron_rebuild() {
  local app_root="$1" install_prefix="$2" electron_ver="$3" arch="$4"
  local nm_dir="$app_root/node_modules"
  [ -d "$nm_dir" ] || die "node_modules not found at $nm_dir"

  local -a mods=()
  if [ -n "${TRAE_NATIVE_REBUILD_LIST:-}" ]; then
    IFS=',' read -r -a mods <<<"$TRAE_NATIVE_REBUILD_LIST"
  else
    mods=("${TRAE_NATIVE_MODULES_DEFAULT[@]}")
  fi
  info "==> Native module swap (darwin -> linux prebuilds)"
  info "    modules: ${mods[*]}"

  local scratch_root="$ROOT/build/native-build"
  rm -rf "$scratch_root"; mkdir -p "$scratch_root"

  local -a failed=() ok=()
  for pkg in "${mods[@]}"; do
    # Read upstream version so we install the same one.
    local ver; ver="$(native_read_version "$pkg" "$nm_dir")"
    local spec="$pkg"
    [ -n "$ver" ] && spec="$pkg@$ver"

    info "==> $spec"
    # Fresh scratch per module so npm doesn't carry over stale state.
    local scratch="$scratch_root/$pkg"
    rm -rf "$scratch"; mkdir -p "$scratch"

    if ( cd "$scratch" \
         && npm init -y >/dev/null 2>&1 \
         && npm install --no-audit --no-fund --silent --legacy-peer-deps \
              --include=optional "$spec" 2>&1 \
         | tail -10 ); then
      # Move the installed tree (and any sibling scoped package directory) over.
      # Scoped packages (e.g. @parcel/watcher) often pull platform-specific
      # sibling subpackages under the same scope (@parcel/watcher-linux-x64-glibc);
      # we copy the entire scope so they resolve at runtime.
      if [[ "$pkg" == @*/* ]]; then
        local scope="${pkg%/*}"
        if [ -d "$scratch/node_modules/$pkg" ]; then
          mkdir -p "$nm_dir/$scope"
          # Remove any *-linux-x64-* sibling too — we'll re-copy the whole scope.
          for sibling in "$scratch/node_modules/$scope"/*; do
            [ -d "$sibling" ] || continue
            local sname; sname="$(basename "$sibling")"
            rm -rf "$nm_dir/$scope/$sname"
          done
          cp -a "$scratch/node_modules/$scope/." "$nm_dir/$scope/"
          ok+=("$pkg")
        else
          warn "  $pkg not present in scratch"
          failed+=("$pkg")
        fi
      else
        if [ -d "$scratch/node_modules/$pkg" ]; then
          rm -rf "$nm_dir/$pkg"
          cp -a "$scratch/node_modules/$pkg" "$nm_dir/"
          ok+=("$pkg")
        else
          warn "  $pkg not present in scratch"
          failed+=("$pkg")
        fi
      fi
    else
      warn "  npm install $spec failed"
      failed+=("$pkg")
    fi
  done

  if [ "${#failed[@]}" -gt 0 ]; then
    warn "==> Modules without a Linux install: ${failed[*]}"
    warn "    Their require() will throw on Linux; the upstream code usually"
    warn "    catches that and degrades gracefully. For a fully populated"
    warn "    build, install the distro's -dev headers for libx11, libxkbfile,"
    warn "    libkrb5, libsecret and rerun with TRAE_NATIVE_REBUILD_LIST=..."
  fi
  info "==> Native module swap done (ok: ${#ok[@]}, missing: ${#failed[@]})"
}
