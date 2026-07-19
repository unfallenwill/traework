# AGENTS.md — Implementation details for AI agents and contributors

This document explains the moving parts of the conversion pipeline and the
gotchas that bit me while writing it. If you are an AI agent picking this
project up, read this before changing anything.

## TL;DR

`install.sh` runs a four-step pipeline:

1. **Extract DMG** with `7z` (UDIF/HFS+) into a tmp dir.
2. **Stage** `Contents/Resources/` into `build/<install-dir>/resources/`,
   preserving the macOS layout that the upstream code expects under
   `process.resourcesPath`.
3. **Patch + adapt** the payload:
   - drop macOS/Windows-only addons (`@vscode/windows-mutex`,
     `windows-foreground-love`, `@vscode/deviceid`);
   - replace each native addon's darwin `.node` with the matching linux
     prebuild fetched from npm;
   - run `scripts/patch_linux.js` to enforce the correct `productName` in
     `product.json` and `package.json`;
   - run `scripts/patch_aha_shim.js` to no-op-stub the `aha*` Electron APIs
     the donor dropped (`ahaAccessibility`, `ahaCustomException`) — see
     [Why stock Electron can't host Trae](#why-stock-electron-cant-host-trae).
4. **Install ByteDance's forked Linux Electron** extracted from the official
   `Trae-linux-x64.deb` (the DMG's own Framework is Mach-O; stock
   `electron/electron` lacks the `aha*` exports Trae imports). The donor's
   `trae` binary is renamed to `electron` (`RPATH=$ORIGIN` keeps
   `libaha_net.so` / `libsscronet.so` resolving); its `resources/app`,
   `node_modules`, and `bin/` are NOT copied — the DMG provides the payload.
   Then drop a self-locating launcher next to it.

`packaging/build.sh` renders `packaging/templates/*` with the detected
version, fills the rendered desktop entry / wrapper / scripts into `build/`,
then invokes `nfpm package --packager deb` and `nfpm package --packager rpm`.

## Why the workflow is split into four libs

`scripts/lib_*.sh` are grep-friendly standalone functions, modeled on
`minimax-code-linux`:

| File | Responsibility |
|---|---|
| `lib_common.sh` | constants (TRAE_PKG_NAME, TRAE_APP_ID, TRAE_INSTALL_PREFIX, ...), `require_cmd`, `resolve_arch`, logging |
| `lib_dmg.sh`   | locate/download DMG, 7z-extract, parse Info.plist via python3 `plistlib` |
| `lib_electron.sh` | download matching Linux Electron zip from `electron/electron` releases |
| `lib_native.sh` | the tricky one: darwin `.node` → linux prebuild replacement |

`lib_native.sh` runs in four phases:

1. **Strip** windows-only addons (`native_strip_macos`).
2. **noop** for ripgrep/fd (`native_install_ripgrep_linux`) — the upstream
   `@byted-fe/ripgrep-linux-x64` package isn't on the public npm registry,
   so we let the editor fall back to its own search-engine logic at runtime.
3. **Stage** a clean `build/native-build/` working dir.
4. **Install + cp-back** each entry in `TRAE_NATIVE_MODULES_DEFAULT` via
   `npm install --include=optional`, then move the package tree (and, for
   scoped packages like `@parcel/watcher`, all sibling subpackages under
   the same scope so platform-specific variants resolve) into the app's
   `node_modules`.

Scoping matters: when we copy `@parcel/watcher` we MUST also copy
`@parcel/watcher-linux-x64-glibc` because the latter is a sibling inside
`node_modules/@parcel/`, not nested inside `@parcel/watcher/`. The runtime
require chain is
`require('@parcel/watcher')` → `require('@parcel/watcher-linux-x64-glibc')`
and the second hop walks up `node_modules/` looking for the scoped
package.

## Why stock Electron can't host Trae

This is the single most important gotcha and the reason `lib_electron.sh` does
NOT download from `electron/electron`.

Trae's main-process JS hard-imports ByteDance-private extensions from the
`electron` module:

```js
import { ahaNet, ahaDeviceService, ahaReporter, ahaIpc, ahaDoctor,
         ahaPerf, ahaDebugger, ahaExtension, ahaFileSystem, ahaProcess,
         ahaOOMCollectHeapSnapshot, ahaRpcClient, ahaVersion, ... } from "electron";
```

These `aha*` exports are not part of upstream Electron. They are added by
ByteDance's patched Electron fork (`@aha-kit/electron`) and are backed by
proprietary shared libraries shipped next to the binary — `libaha_net.so`
(TTNet networking), `libsscronet.so`, `liblogifier_retrieval.so`,
`libsimplelog.so`. Stock `electron/electron` does not export them, so the
very first such import fails at ESM link time with a fatal, uncatchable
`SyntaxError: ... does not provide an export named 'ahaDeviceService'` and
the main process dies before any window opens. You cannot add named ESM
exports to the `electron` built-in from JS land, and stubbing `ahaNet` /
`ahaDeviceService` would break networking + auth (Trae routes AI requests
and login through TTNet, reads device identity from `ahaDeviceService`).

The fork's Linux build is not on npm (`@aha-kit/electron` → 404) and the
DMG only ships a Mach-O Framework. The one public source is the official
Trae Linux package, whose `/usr/share/trae` tree contains the patched
`trae` binary (`RPATH=$ORIGIN`) plus the `.so` libs. `electron_install()`
extracts that tree, renames `trae` → `electron`, and copies everything
EXCEPT `resources/`, `node_modules/`, `bin/` (the DMG supplies the payload).

### Version drift + the `aha*` shim

The DMG ("TRAE SOLO" 1.107.1) imports 2 `aha*` APIs the plain "Trae" 1.107.1
donor dropped — `ahaAccessibility`, `ahaCustomException` (observability /
accessibility, NOT networking). Without handling, this surfaces as
`... does not provide an export named 'ahaCustomException'`. Since ESM named
imports can't be retrofitted onto the built-in, `patch_aha_shim.js` creates
`node_modules/__aha-electron-shim/` (a `Proxy`-backed no-op module) and
rewrites only the affected `import{...}from"electron"` statements to pull
those 2 names from the shim; all real co-imported names stay on `electron`.
The upstream code already guards `if(!k3) return warn('unavailable')`, so
the stubs are safe. Override the list with `TRAE_AHA_STUBS=a,b`.

## Why we didn't use `@electron/rebuild`

The DMG ships a *stripped* addon tree: every native addon has only its
compiled `.node` and any licensing/README files. No `binding.gyp`, no
`src/`, no prebuild script. Running `electron-rebuild` against that tree
walks the prod deps in `package.json`, finds them, and immediately fails
because `node-addon-api` (a transitive dep of most of them) isn't in the
scope of the foreign `node_modules`.

The codex-desktop-linux team hit the same wall in 2024 and converged on
a "build in a clean staging dir" approach: `npm install --ignore-scripts`
in a throwaway dir, then `electron-rebuild` against Electron headers.
That works for modules whose upstream publishes gyp+src tarballs but
still requires distro dev libraries (`libxkbfile-dev`, `libx11-dev`,
`libsecret-1-dev`, `libkrb5-dev`) being present at build time.

Our install environment lacks sudo, so we **don't** rebuild. We install
fresh from npm with `--include=optional` and let prebuild-install fetch
the matching linux prebuild. This works for 7/8 of the listed native
modules; `native-keymap` is the exception because it ships only sources.
We surface that as a warning instead of failing the build, because the
upstream Electron catches the require() throw and degrades gracefully.

## Templates

`packaging/templates/*.tmpl` use `${VAR}` syntax that's expanded by a tiny
inline `perl -pe 's/\$\{(\w+)\}/...'` (no need to depend on `envsubst`
or `gomplate`). `build.sh` exports the variables before invoking
`render`. Keep the perl one-liner intact — it intentionally doesn't quote
vars, so empty values get rendered as empty strings (not literal `undef`).

## Adding the `chrome-sandbox` setuid hint

Linux Electron refuses to start under most kernels unless `chrome-sandbox`
is setuid root (`4755`). The package postinst reasserts that mode:
`chmod 4755 ${INSTALL_PREFIX}/chrome-sandbox`.

If you run the unpacked `build/<dir>/` outside a `sudo chown`, the
launcher detects that and falls back to `--no-sandbox`. See
`launcher/start.sh.template` for the `if [ -u "$SCRIPT_DIR/chrome-sandbox" ]`
heuristic.

## Useful diagnostic commands

```bash
# Show every native module's ELF/Mach-O/PE file type
find build/trae-solo/resources/app/node_modules -name "*.node" \
  -exec file {} \;

# Force a clean rebuild
rm -rf build/

# Only re-do the native swap (skip the DMG re-extract)
TRAE_NATIVE_REBUILD_LIST="node-pty,@vscode/sqlite3,@vscode/spdlog" \
  ./install.sh --dmg /path/to/TRAE_Work-darwin-x64.dmg \
              --install-dir build/trae-solo

# Inspect the produced .deb
dpkg-deb --info dist/trae-solo_0.1.36_amd64.deb
dpkg-deb -c dist/trae-solo_0.1.36_amd64.deb | grep -E 'start\.sh|chrome-sandbox|trae\.png|trae-solo\.desktop'

# Equivalent for the .rpm (when rpm is available)
rpm -qpi dist/trae-solo-0.1.36.x86_64.rpm
rpm -qpl dist/trae-solo-0.1.36.x86_64.rpm
```

## What I'd add next

- CI: this pipeline is small enough to run on GitHub Actions. A weekly
  cron should call `TRAE_CONFIG_URL` against TRAE's web common_config
  endpoint (modeled on minimax-code's `resolve-version.sh`); when a new
  version appears, build .deb + .rpm on `ubuntu-latest` and
  `fedora-latest`, attach to a tag-driven Release.
- The DMG has a release-time signature directory (`_CodeSignature/` and
  signature forks on `.icns`/`.node`/`.nib`). Those get happily copied
  along with everything else under `Contents/Resources/`. The Mac code-
  signatures are inert on Linux — Electron never validates them — but
  they bloat the package by a few MB. A `find build ... -name
  '*:com.apple.cs.*'` strip pass could shave weight.
- ARM64 port. The Electron 39 zip is published for `linux-arm64`; we
  only need `TRAE_NATIVE_REBUILD_LIST` to also include
  `@parcel/watcher-linux-arm64-glibc` and a corresponding `arm64` switch
  in `resolve_arch`.
