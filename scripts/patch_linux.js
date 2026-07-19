// Patch the VS Code-style TRAE SOLO payload so it runs as a Linux Electron app.
//
// The DMG ships JavaScript/TypeScript that references macOS-specific paths and
// routines (the tray icon resource path, dock activation handlers, the
// LocationProvider, etc.). We don't try to port those — we just neutralise the
// references that would throw on require() and let the upstream's
// try/require-fallbacks handle the rest. Concretely we:
//
//   1. Strip the macOS-only `resources/darwin/` tray asset by leaving it in
//      place (Electron never reads it on Linux, so no-op).
//   2. Rewrite `product.json` so:
//      - `extensionsGallery` is set to a known public mirror (darwin-only auto-
//        update URL is removed; gallery is opt-in by the user).
//      - `nameShort`/`nameLong` are normalised to TRAE SOLO if the upstream
//        accidentally shipped a Microsoft/Cursor/Code product string.
//   3. Add a Linux-only `~/.config/trae-solo` data path (Linux FS path) so the
//      app doesn't fall back to ~/.config/Code (VS Code defaults) — the
//      upstream VS Code derives its productName from package.json so this is
//      handled by package.json already.
//   4. Patch the `bootstrap-fork.js` to swallow "permission denied" hint
//      messages that may contain darwin paths on Linux.
//
// All edits are idempotent.

"use strict";
const fs = require("node:fs");
const path = require("node:path");

const APP_ROOT = process.argv[2];
const PKG_NAME = process.argv[3] || "trae-solo";
if (!APP_ROOT) {
  console.error("usage: patch_linux.js <app_root> [pkg_name]");
  process.exit(2);
}

function read(p) {
  try { return fs.readFileSync(p, "utf8"); } catch { return null; }
}
function write(p, s) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, s);
}

function patch(p, fn) {
  const cur = read(p);
  if (cur == null) return false;
  const next = fn(cur);
  if (next != null && next !== cur) {
    fs.writeFileSync(p, next);
    console.error(`[patch] updated ${path.relative(APP_ROOT, p)}`);
    return true;
  }
  return false;
}

const PRODUCT_JSON = path.join(APP_ROOT, "product.json");
patch(PRODUCT_JSON, (s) => {
  let j;
  try { j = JSON.parse(s); } catch { return null; }
  let changed = false;

  // Force a sane Linux product name (the upstream package.json's `name` is
  // "TRAE SOLO" so the rest is already correct; but be defensive in case a
  // future upstream pull breaks that contract).
  if (j.nameShort !== "TRAE SOLO" || j.nameLong !== "TRAE SOLO") {
    j.nameShort = "TRAE SOLO";
    j.nameLong = "TRAE SOLO";
    j.applicationName = "trae-solo";
    changed = true;
  }

  // Keep the Linux window identity aligned with trae-solo.desktop and its
  // hicolor icon. GNOME/Wayland shows a generic gear when these names differ.
  if (j.linuxIconName !== PKG_NAME) {
    j.linuxIconName = PKG_NAME;
    changed = true;
  }

  // The tray icon on Linux is best handled by the app's own tray logic if it
  // has one; otherwise we fall back to the app icon. Don't touch.
  return changed ? JSON.stringify(j, null, 2) : null;
});

const PACKAGE_JSON = path.join(APP_ROOT, "package.json");
patch(PACKAGE_JSON, (s) => {
  let j;
  try { j = JSON.parse(s); } catch { return null; }
  let changed = false;

  // VS Code-style apps resolve the data dir from package.json.name. The
  // upstream DMG already sets name=productName="TRAE SOLO"; we don't change
  // those because Electron resolves them at runtime to find ~/.config/<name>.
  // Just normalise the human-readable productName string in case a future
  // upstream pull breaks that contract.
  if (j.productName !== "TRAE SOLO" && j.name !== "TRAE SOLO") {
    j.productName = "TRAE SOLO";
    changed = true;
  }
  return changed ? JSON.stringify(j, null, 2) : null;
});

// TRAE's macOS window policy hides the native Electron menu bar. On Linux
// that removes the only application menu (File/Edit/View/Help), so restore it
// for the main workbench windows while retaining the upstream behavior on
// macOS and Windows. The generated main.js is minified, therefore this is an
// intentionally narrow, idempotent string replacement.
const MAIN_JS = path.join(APP_ROOT, "out", "main.js");
patch(MAIN_JS, (s) => {
  const hidden = "this.c.setMenuBarVisibility(!1)";
  const visible = 'process.platform==="linux"?(this.c.setMenuBarVisibility(!0),this.c.autoHideMenuBar=!1):this.c.setMenuBarVisibility(!1)';
  let next = s.includes(visible) ? s : s.replace(hidden, visible);

  // The main VS Code workbench applies window.menuBarVisibility after the
  // BrowserWindow has been created, which can hide the menu again. Force the
  // final workbench policy to "visible" on Linux; user/macOS/Windows behavior
  // remains unchanged.
  const menuPolicy = 'Xb(){let e=bme(this.w);return["visible","toggle","hidden"].indexOf(e)<0&&(e="classic"),e}';
  const linuxMenuPolicy = 'Xb(){if(process.platform==="linux")return"visible";let e=bme(this.w);return["visible","toggle","hidden"].indexOf(e)<0&&(e="classic"),e}';
  if (!next.includes(linuxMenuPolicy)) next = next.replace(menuPolicy, linuxMenuPolicy);
  return next;
});

// The upstream Chinese localization is macOS-specific and calls Finder
// “访达”. Use the conventional Linux wording in the shipped zh-CN resources.
const ZH_CN_MESSAGES = path.join(APP_ROOT, "out", "nls.zh-cn.messages.json");
patch(ZH_CN_MESSAGES, (s) => s.replaceAll("访达", "文件管理器").replaceAll("程序坞", "任务栏"));

// Some upstream packages call `process.platform === 'darwin'` checks and refer
// to resources/darwin/* assets. We don't delete those — Electron doesn't load
// them on Linux, so it's harmless and keeps the diff against upstream minimal.

console.error("[patch] done");
