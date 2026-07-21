#!/usr/bin/env bash
set -euo pipefail

# Resolve the current TRAE Work macOS x64 DMG URL.
#
# Order of preference:
#   1. TRAE_DMG_URL env var       — explicit pin, used for reproducible CI.
#   2. JSON manifest API          — TRAE's public release manifest endpoint,
#                                  the source the official site hydrates from.
#                                  Picks the x64 entry for the preferred region.
#   3. Legacy HTML scrape         — last-resort fallback for older sites; the
#                                  official page is now JS-rendered, so this
#                                  rarely succeeds.
#
# The manifest endpoint is queried anonymously with a browser UA; no auth is
# required and there are no required query parameters.
#
# Region preference (first match wins): sg, va, us. The historical TRAE Work
# release lives under the `va` (US) bucket on the official CDN; `sg` is the
# overseas catch-all.
#
# Env:
#   TRAE_DMG_URL        — optional exact DMG URL, overrides discovery
#   TRAE_DOWNLOAD_PAGE  — optional URL for the legacy HTML scrape fallback
#   TRAE_REGION         — preferred manifest region (default: va)

if [ -n "${TRAE_DMG_URL:-}" ]; then
  printf '%s\n' "${TRAE_DMG_URL}"
  exit 0
fi

# ---- Manifest API -----------------------------------------------------------
# Endpoint discovered by tracing the public website's JS bundles
# (https://www.trae.ai/download hydrates from this JSON via React Query).
# Path: body.data.solo.darwin.download[?].intel (x64 DMG URL).
MANIFEST_URL="${TRAE_MANIFEST_URL:-https://icube-normal.trae.ai/icube/api/v1/native/version/trae/latest}"
PREFERRED_REGION="${TRAE_REGION:-va}"

if manifest_json="$(curl -fsSL --max-time 30 -A 'Mozilla/5.0' "$MANIFEST_URL" 2>/dev/null)"; then
  url="$(
    printf '%s' "$manifest_json" \
      | jq -r --arg pref "$PREFERRED_REGION" '
          .data.solo.darwin.download
          | (map(select(.region == $pref)) + . + [])
          | .[0].intel // empty
        ' 2>/dev/null || true
  )"
  if [ -n "$url" ] && [ "$url" != "null" ]; then
    printf '%s\n' "$url"
    exit 0
  fi
  echo "resolve-version: manifest at $MANIFEST_URL did not expose a macOS x64 DMG" >&2
else
  echo "resolve-version: failed to fetch $MANIFEST_URL" >&2
fi

# ---- Legacy HTML scrape fallback -------------------------------------------
# The official site is now a JS-rendered SPA, so the inline HTML rarely carries
# direct .dmg links anymore. This branch is preserved for older deployments
# and as a last-resort hint if the manifest endpoint ever disappears.
DOWNLOAD_PAGE="${TRAE_DOWNLOAD_PAGE:-https://www.trae.ai/download}"
if html="$(curl -fsSL --max-time 30 -A 'Mozilla/5.0' "$DOWNLOAD_PAGE" 2>/dev/null)"; then
  url="$(printf '%s' "$html" | grep -Eo 'https?[^"'"'"'<> ]+\.dmg[^"'"'"'<> ]*' | grep -Ei 'trae|work|solo' | head -1 || true)"
  if [ -n "$url" ]; then
    printf '%s\n' "$url"
    exit 0
  fi
fi

echo "resolve-version: could not discover a TRAE Work DMG URL" >&2
echo "Set TRAE_DMG_URL to the official TRAE Work x64 DMG URL." >&2
exit 1
