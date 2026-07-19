#!/usr/bin/env bash
# Extract hicolor icons from the upstream .icns inside the DMG.
#
# Usage: ./packaging/extract-icon.sh [<icns-path>]
#   <icns-path>  path to "TRAE SOLO.icns" (default: search build/payload)
#
# Needs Python 3 with Pillow (uses the OS package manager version, not a venv).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ICON_NAME="${TRAE_PKG_NAME:-trae-solo}"
ICON_DIR="$ROOT/packaging/icons/$ICON_NAME/hicolor"

ICNS="${1:-}"
if [ -z "$ICNS" ]; then
  # Look for the .icns in already-extracted payloads first.
  for cand in \
      "$ROOT/build/payload/Resources/TRAE SOLO.icns" \
      "$ROOT/build/payload/resources/TRAE SOLO.icns"; do
    if [ -f "$cand" ]; then ICNS="$cand"; break; fi
  done
fi
[ -n "$ICNS" ] && [ -f "$ICNS" ] || {
  echo "[error] No .icns found. Pass an explicit path or extract the DMG into build/payload first." >&2
  exit 1
}

python3 - "$ICNS" "$ICON_DIR" "$ICON_NAME" <<'PY'
import sys, os
from PIL import Image
icns, outdir, icon_name = sys.argv[1], sys.argv[2], sys.argv[3]
sizes = [16, 32, 48, 64, 128, 256, 512]
img = Image.open(icns).convert("RGBA")
for s in sizes:
    p = os.path.join(outdir, f"{s}x{s}", "apps", f"{icon_name}.png")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    img.resize((s, s), Image.LANCZOS).save(p, "PNG")
print(f"[icon] wrote {len(sizes)} sizes to {outdir}")
PY
