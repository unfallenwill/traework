#!/usr/bin/env bash
# Install (or report the install commands for) the build dependencies for
# the TRAE SOLO Linux packaging pipeline.
#
# Tested on Debian 12 / Ubuntu 24.04+. For Fedora / RHEL, see the comments
# in this file.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
say()  { printf '%b\n' "$*"; }
warn() { say "${YELLOW}[warn]${NC} $*"; }
ok()   { say "${GREEN}[ok]${NC}   $*"; }
fail() { say "${RED}[err]${NC}  $*"; }

detect_family() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

FAMILY="$(detect_family)"
say "Detected distro family: ${FAMILY}"

need_sudo() {
  if [ "$(id -u)" -eq 0 ]; then echo ""; return; fi
  if command -v sudo >/dev/null 2>&1; then echo "sudo"; return; fi
  echo "DOAS_OR_ROOT"
}

SU="$(need_sudo)"

case "$FAMILY" in
  debian|ubuntu|pop|elementary|linuxmint)
    say "Installing Debian-family build deps (curl, p7zip-full, perl, nodejs, npm, build-essential)..."
    $SU apt-get update
    $SU apt-get install -y curl p7zip-full perl nodejs npm build-essential
    # nfpm
    if ! command -v nfpm >/dev/null 2>&1; then
      say "Installing nfpm via Go (or download binary)..."
      if command -v go >/dev/null 2>&1; then
        $SU go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest
        ok "Installed nfpm at \$(go env GOPATH)/bin/nfpm"
      else
        warn "Go not found. Install nfpm manually: https://nfpm.goreleaser.com/install/"
      fi
    fi
    ;;
  fedora|rhel|rocky|almalinux|centos)
    say "Installing Fedora-family build deps (curl, p7zip, p7zip-plugins, perl, nodejs, rpm-build, @development-tools)..."
    $SU dnf install -y curl p7zip p7zip-plugins perl nodejs npm rpm-build make gcc-c++ @development-tools
    if ! command -v nfpm >/dev/null 2>&1; then
      warn "Install nfpm manually (go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest)"
    fi
    ;;
  arch|manjaro|endeavouros)
    say "Installing Arch build deps..."
    $SU pacman -S --needed curl p7zip perl nodejs npm gcc make
    if ! command -v nfpm >/dev/null 2>&1; then
      warn "Install nfpm manually (pacman -S nfpm or go install)."
    fi
    ;;
  *)
    warn "Unknown distro '$FAMILY'. Install: curl p7zip perl nodejs npm + a C toolchain + nfpm."
    ;;
esac

ok "Done. Re-run '$SU env' or open a new shell if nfpm wasn't found in PATH."
