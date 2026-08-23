# Changelog

All notable changes to SpaceLens are documented here.

## [2.15.0] — 2026-08-23

A correctness release: a code review of the previous cycle's changes turned up several
places where the app reported numbers it hadn't actually earned. Everything below is a
fix to what SpaceLens *tells* you versus what it *did*.

### ⚠️ Changed — Emptying the Trash is now permanent

- **"Trash" cleanup previously freed nothing.** macOS `trashItem` on a file that is already
  in `~/.Trash` silently succeeds without moving anything, so the card reported "moved N
  items to Trash — X GB freed" while reclaiming zero bytes.
- Emptying the Trash now **deletes those files outright**, which is what Finder's Empty
  Trash does and the only way to actually reclaim the space. The confirmation dialog says
  so explicitly, and permanently-deleted items are counted separately from trashed ones so
  the success banner never calls them recoverable.
- Permanent removal is restricted to direct children of `~/.Trash` and re-verifies that
  precondition itself rather than trusting its caller. Every other delete path in the app
  is still a recoverable move-to-Trash.
- Note: this needs **Full Disk Access**. Without it the card now reports a failure instead
  of a silent success.

### 🐛 Fixed — scan accounting

- **Resumed scans no longer poison future time estimates.** A resume re-walks every root
  from scratch, but the previous partial's elapsed time was still carried over. Pairing
  recounted-from-zero bytes with stale elapsed understated throughput, and that figure was
  written into the persisted performance history — inflating the ETA of every later scan.
- **Cleanups now show up everywhere.** Freeing space from the Cleanup tab, an app's detail
  sheet, the Explorer, or the Media viewer updates the Overview chart, the category cards,
  the file counts, and the on-disk cache — previously those kept reporting pre-cleanup
  sizes until the next full scan.
- **Deleting files no longer fakes a scan timestamp.** Re-persisting after a deletion used
  to stamp "now" as the scan date and record every idle hour since the scan started as its
  duration, so the UI claimed you had "scanned just now".
- **A stalled scan says so.** If progress stops advancing for a few minutes — usually a
  pending permission prompt or a very slow subtree — an advisory appears instead of a UI
  that just looks frozen.
- Progress ticks are ordered, so a late-arriving update can no longer make progress jump
  backward or stick on a stale value.

### 🐛 Fixed — data safety and durability

- **Scan history survives disk pressure.** The cache moved from `~/Library/Caches` (which
  macOS purges, and which cleanup tools wipe) to `~/Library/Application Support`. Existing
  data is migrated on first launch.
- **SpaceLens no longer deletes its own scan history.** Its state directory sits inside two
  cleanup targets; clearing those now skips it.
- **Corrupt caches self-heal.** A torn or schema-changed cache file is discarded and rebuilt
  instead of failing on every launch, and all cache writes are atomic.
- **Unreadable folders are reported, not silently skipped.** A permission-protected folder
  during cleanup used to look like a successful no-op.
- **The system-path guard is case-insensitive.** On the default (case-insensitive) volume,
  `/SYSTEM/Library` and `/Private/var` reach the same protected files as their canonical
  spellings and are now refused too.

### 🐛 Fixed — everything else

- **Deleting media keeps your suggestions.** Trashing one file used to wipe the whole
  Suggestions section and the duplicate groups, and persist that empty result.
- **Media deletion routes through the safety guard** and reports what it couldn't remove,
  rather than swallowing failures.
- The DMG script **refuses to silently ad-hoc sign**. An ad-hoc DMG is blocked by Gatekeeper
  on every other Mac and loses permission grants on each rebuild. Use `ALLOW_AD_HOC=1` for
  a local-only build.
- Fixed a `URLSession` leak in the Ollama model downloader that persisted for the rest of
  the process lifetime.
- Removed the non-functional "Organize" button from the media action bar.

## [2.14.0] — 2026-06-04

### ✨ Rebrand: Storage AI is now SpaceLens

- **New name, same mission**: *see where your space went — and take it back.*
- **New app icon**: a magnifying lens over the treemap — the product in one glyph.
- Bundle identifier moved to `com.spacelens.app` (macOS will re-ask for permissions
  once after updating; grants then persist as before).
- Repository renamed to `bhaweshverma50/spacelens` — old GitHub URLs redirect.

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
