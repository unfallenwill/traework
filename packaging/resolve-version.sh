#!/usr/bin/env bash
set -euo pipefail

# Resolve TRAE Work's current macOS DMG. The official site is a dynamic page,
# so keep an explicit URL override for reproducible CI and parse direct DMG
# links when the site exposes them in HTML/embedded JSON.
DOWNLOAD_PAGE="${TRAE_DOWNLOAD_PAGE:-https://www.trae.ai/download}"
if [ -n "${TRAE_DMG_URL:-}" ]; then
  printf '%s\n' "${TRAE_DMG_URL}"
  exit 0
fi

html="$(curl -fsSL --max-time 30 -A 'Mozilla/5.0' "$DOWNLOAD_PAGE")"
url="$(printf '%s' "$html" | grep -Eo 'https?[^"'"'"'<> ]+\.dmg[^"'"'"'<> ]*' | grep -Ei 'trae|work|solo' | head -1 || true)"
if [ -z "$url" ]; then
  echo "resolve-version: official download page did not expose a direct DMG URL" >&2
  echo "Set TRAE_DMG_URL to the official TRAE Work x64 DMG URL." >&2
  exit 1
fi
printf '%s\n' "$url"
