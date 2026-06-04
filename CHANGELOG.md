# Changelog

All notable changes to Storage AI are documented here.

## [2.13.0] — 2026-06-04

The biggest release yet: a new treemap **Explorer**, a deep quality pass that fixed
66 reviewed findings across security, performance, state management, and UX, and a
permissions overhaul so macOS stops re-asking for access.

### ✨ New — Explorer (treemap visualization)

- **GrandPerspective-style squarified treemap** of your whole disk — or any folder via
  *Open Folder…* — where bigger tiles mean more space.
- **Drill down** by clicking folders, with breadcrumb navigation back up.
- **Hover** any tile for name/size details; **right-click** to Reveal in Finder or Move to Trash.
- **Colorful by design**: every folder gets a stable hue (the same folder looks the same
  everywhere, across launches) and files are colored by type across 12 categories —
  including new **Design**, **Data**, **Disk Images**, and **Fonts** kinds.
- **Fast and memory-bounded**: a single ~30s walk indexes folder sizes for the whole disk
  while the app settles at a few dozen MB of memory; levels materialize lazily as you drill.
- The treemap survives tab switches — no rebuilding when you come back.

### 🗑 Fixed — Deletes & app cleanup

- **Honest freed-space reporting**: trashing a folder previously reported "Moved Zero KB
  to Trash" because only the folder's own stat size was counted. Contents are now summed.
- **App cleanup actually visible**: per-app Clean Cache / Remove App Data dedupe their
  target paths (no more phantom "skipped" items) and surface the *reason* when something
  can't be removed (e.g. permissions).
- **Refresh button** on the Applications view — the list is cached between scans and can
  now be re-analyzed on demand.
- Cleanup messages clarify that space returns when the Trash is emptied.
- Everything still goes to the **Trash — never permanently deleted** — guarded by a
  safety allowlist that refuses system paths, volume roots, and your home directory.

### 📊 Fixed — Scanning & state

- **Category drill-down works during and after partial scans**: the scanner now streams
  its live top-files snapshot into the UI, so cancelled or interrupted scans keep their
  file lists (previously they only appeared after a fully completed scan).
- Real per-category file counts persist across launches (interrupted scans no longer
  show "0 files").
- Live scan updates flow directly from the scan service to every view (no more stale
  ticks or missed updates), and quitting mid-scan saves progress reliably.

### 🔐 Fixed — Permissions (no more repeat prompts)

- The build/install pipeline signs with a **stable code-signing identity**, so macOS
  remembers your permission grants across app updates (ad-hoc-signed builds previously
  reset Full Disk Access and folder permissions on every update).
- Added proper **usage descriptions** for Desktop/Documents/Downloads/external/network
  volumes and media library prompts.
- **Media analysis skips Photos/Music libraries** entirely — no more surprise
  "Apple Music / media library" prompt, and app-managed media is never touched.

### 🤖 Improved — AI recommendations

- Recommendations are **grounded in your actual scan results** (real apps, real folders,
  real sizes) instead of generic advice; media tips are actionable.
- Ollama model downloads can be **cancelled mid-stream**; suggestions auto-load when
  cached scan data is present.
- Selectable model, capped response sizes, and a hardened local HTTP client.

### 🧰 Quality & internals

- 66-finding deep review resolved: safe delete engine, crash-safe media compression,
  faster duplicate detection, parallel app attribution, atomic cache writes, memory-leak
  fixes, accessibility labels, Dynamic Type font scaling, and much more.
- **46 unit tests** covering the delete engine's safety guards, treemap layout, scan
  aggregation, file classification, and persistence.
- Hardened Runtime entitlements with a notarization-ready signing pipeline
  (`scripts/create-dmg.sh`), plus `scripts/dev-install.sh` for local builds.
- The in-app memory readout now reports the true physical footprint (matching Xcode's
  gauge) instead of RSS, which over-counted freed pages.

---

## [2.4.0] and earlier

- App cleanup actions (clean cache / remove data / uninstall) from app details
- Auto Ollama setup; menu bar extra; pause & resume scans; auto-save progress
- Live file counts and scan time estimation
