# Notice: TRAE SOLO is third-party proprietary software

> ⚠️ **Unofficial.** This project is **not** affiliated with, endorsed by, or
> sponsored by **SPRING (SG) PTE. LTD.** or **TRAE**. **TRAE SOLO is © SPRING (SG) PTE. LTD. All rights reserved.** The packages here are built from the **official macOS build** by extracting its cross-platform Electron payload and running it under the matching Linux Electron runtime. See [LICENSE](LICENSE).

If anything in this repository should not be distributed this way, please
open an issue.

## What this repository contains

- `install.sh`, `packaging/build.sh`, the `packaging/templates/*` files,
  `packaging/extract-icon.sh`, `scripts/lib_*.sh`, `scripts/patch_linux.js`,
  `launcher/start.sh.template`, `AGENTS.md`, `README.md`, this `NOTICE.md`,
  and `LICENSE` (the MIT part). All of these are MIT-licensed.

## What this repository does NOT contain

- TRAE SOLO source code.
- TRAE SOLO compiled binaries from any platform other than the user's own
  locally-downloaded macOS DMG, which the build pipeline converts to a
  Linux-ready directory at build time and embeds into the resulting `.deb`
  or `.rpm`. The build pipeline does **not** check in the converted tree,
  and `.gitignore` excludes the `build/` and `dist/` directories.

## Trademarks

"TRAE" and "TRAE SOLO" are trademarks of SPRING (SG) PTE. LTD., used
here for identification only.
