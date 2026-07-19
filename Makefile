# trae-solo Makefile — one-shot driver for the conversion pipeline.
# Mirrors the conventions used in codex-desktop-linux / minimax-code-linux so
# you can `make bootstrap-native` / `make package` like the other projects.

# ---- Default target ---------------------------------------------------------
.PHONY: help
help:
	@echo "TRAE SOLO Linux packaging"
	@echo ""
	@echo "Build:"
	@echo "  make build-app        convert DMG -> build/trae-solo/ (runnable app)"
	@echo "  make package          build .deb + .rpm into dist/"
	@echo "  make all              build-app + package"
	@echo "  make deb              only the .deb"
	@echo "  make rpm              only the .rpm"
	@echo ""
	@echo "Run:"
	@echo "  make run-app          launch the converted app from build/trae-solo/"
	@echo "  make install-deps     install prerequisites (curl, 7z, perl, node, nfpm)"
	@echo "  make vendor-runtime   refresh vendored ByteDance runtime from ELECTRON_DEB"
	@echo ""
	@echo "Maintenance:"
	@echo "  make clean            drop build/ and dist/"

# ---- Configuration ----------------------------------------------------------
# Path to the upstream DMG. Override with `make build-app DMG=/path/to/foo.dmg`.
DMG ?= $(HOME)/下载/TRAE_Work-darwin-x64.dmg
ELECTRON_DEB ?= $(HOME)/下载/Trae-linux-x64 (3).deb
ARCH ?= x64
PRODUCT_VERSION ?=
INSTALL_DIR := build/trae-solo

# ---- Build ------------------------------------------------------------------
.PHONY: all build-app package deb rpm install-deps vendor-runtime run-app clean

vendor-runtime:
	./scripts/vendor_linux_runtime.sh "$(ELECTRON_DEB)"

all: build-app package

# Just convert the DMG into a runnable Linux app tree.
build-app:
	@if [ ! -f "$(DMG)" ]; then \
	  echo "[error] DMG not found: $(DMG)" >&2; \
	  echo "        Set DMG=/path/to/file.dmg" >&2; exit 2; \
	fi
	./install.sh --dmg "$(DMG)" --install-dir "$(INSTALL_DIR)" --arch $(ARCH)

# Full .deb + .rpm build. Runs build-app as a prerequisite.
package: build-app
	DMG="$(DMG)" ARCH=$(ARCH) PRODUCT_VERSION="$(PRODUCT_VERSION)" \
	  ./packaging/build.sh

deb: package
	@echo "[deb-only] use ARCH=$(ARCH) DMG=$(DMG) ./packaging/build.sh"

rpm: package
	@echo "[rpm-only] use ARCH=$(ARCH) DMG=$(DMG) ./packaging/build.sh"

run-app: build-app
	./$(INSTALL_DIR)/start.sh

# ---- Toolchain --------------------------------------------------------------
install-deps:
	@./scripts/install-deps.sh 2>/dev/null || \
	  echo "[hint] manually install: curl p7zip-full perl nodejs npm + go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest"

clean:
	rm -rf build/ dist/
	@echo "cleaned build/ and dist/"
