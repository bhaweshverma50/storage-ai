# Treemap "Explorer" — Design

Status: approved 2026-06-03
Branch: deep-review-fixes

## Goal

Add a GrandPerspective-style **squarified treemap** to Storage AI: a spatial,
size-proportional view of disk usage where every file/folder is a rectangle whose
area is proportional to its bytes, nested by folder. It must be efficient, easy to
use, modern, and helpful — covering the whole disk with drill-down into any folder,
plus the ability to open an arbitrary folder.

## Decisions (approved)

- **Scope:** full-disk treemap across all scan roots (Home, /Applications, dev dirs,
  +System if `includeSystem`), **plus** drill-down into any folder, **plus** an
  "Open Folder…" action to treemap an arbitrary directory.
- **Interactions:** drill-down (zoom), reveal in Finder, move to Trash, info on
  hover/select.
- **Coloring:** by file-kind (image/video/audio/code/archive/doc/app/other) with a
  legend; folders tinted neutral.
- **Tail-collapsing:** within each folder, files below an adaptive threshold
  (`max(64 KB, 0.1% of folder size)`) collapse into one synthetic "N small items"
  tile. Bounds memory/nodes and removes visual noise. (Future: optional "show all
  files" toggle.)
- **Tab name:** "Explorer" (icon `square.grid.3x3.fill`).
- **Persistence:** the built tree is cached to disk for instant reopen, with a
  "Rebuild" action + staleness check.

## Approach

GrandPerspective-faithful squarified treemap, adapted to this SwiftUI app:

- **On-demand tree build, cached to disk.** The main scan stays lean (it only keeps
  top-1000 files/category via `FileHeap`, no hierarchy). When the Explorer tab is
  opened, a dedicated pass builds the full directory tree, shows progress, and
  persists it. Rebuilding every visit would be too slow; folding tree-building into
  the main scan would bloat every scan's memory even when the treemap is never used.
  On-demand + cache is the efficient middle.
- **`Canvas` rendering.** Immediate-mode `Canvas` draws thousands of rectangles
  GPU-fast with cushion shading (GrandPerspective's signature look), modern rounded
  edges, file-kind colors, and a hover highlight. A flat `[(CGRect, FileNode)]` list
  backs cursor hit-testing.

## Components (all new; isolated from existing code)

- `Models/FileTree.swift` — `FileNode` (reference type: name, url, sizeBytes,
  isDirectory, children, kind). Built off-main, handed to MainActor when ready.
- `Services/FileTreeBuilder.swift` — recursive walk → aggregated tree with
  `CancellationToken`, progress callback, memory-pressure awareness
  (`MemoryPressureMonitor`), and tail-collapsing. Persists via `ScanDataStore`.
- `Services/TreemapLayout.swift` — pure **squarified** layout (Bruls et al.):
  `layout(nodes:in:) -> [TreemapTile]`. Fully unit-testable (TDD).
- `Services/FileKind.swift` — extension → kind + color + legend entries.
  Unit-testable.
- `Views/ExplorerView.swift` + `TreemapCanvas` — Canvas renderer, breadcrumb bar,
  hover info overlay, color legend, "Open Folder…", "Rebuild".
- `Models/ExplorerViewModel.swift` (`@MainActor ObservableObject`) — owns the tree,
  current root (drill-down stack), build/loading/error state.

## Data flow

1. Open Explorer tab → ViewModel loads cached tree if present & fresh; else builds.
2. `FileTreeBuilder` walks roots (reuse `ScanRootsBuilder`) → `FileNode` tree with
   aggregated sizes; tail-collapses small files; reports progress; persists result.
3. `TreemapLayout` computes tiles for the current root, recursing only into
   rectangles large enough to see (≥~3 pt); deeper detail computed lazily on
   drill-down.
4. `TreemapCanvas` draws tiles (kind color + cushion shading) and keeps the flat
   tile list for hit-testing.
5. Hover → info overlay; click folder → push root (breadcrumb); right-click →
   reveal / move-to-Trash (via `DeleteEngine.trashFiles`), then the tree subtracts
   the freed bytes up the ancestors and re-lays-out (no rescan).

## Error handling

- Build failures / permission-denied subtrees: skipped via enumerator errorHandler
  (counted, not fatal); surface a non-fatal note if large portions were unreadable
  (mirrors the Full Disk Access advisory).
- Delete failures: surfaced via the existing `DeleteEngine.Outcome` (trashed /
  failed / blocked); tree only updated for actually-trashed items.
- Cancellation: leaving the tab or pressing Cancel stops the build cooperatively.

## Performance

- Off-main build + cancellation + memory-pressure throttle.
- Tail-collapsing bounds node count and RAM.
- Layout recurses only into visible-sized rectangles; lazy deeper detail.
- Persisted tree → instant reopen.
- `Canvas` (not per-tile Views) for thousands of rectangles.

## Testing (TDD where pure)

- `TreemapLayout`: tiles exactly tile the rect, areas ∝ sizes, bounded aspect
  ratios, deterministic.
- `FileNode` aggregation: parent bytes == Σ children.
- Tail-collapse: collapsed aggregate size == Σ collapsed files; big files retained.
- `FileKind` mapping: representative extensions map to expected kinds/colors.

## Integration

New `NavigationItem.explorer` case + detail branch in `DashboardView`. Nothing
existing changes beyond that. Reuses `ScanRootsBuilder`, `DeleteEngine`,
`ScanDataStore`, `MemoryPressureMonitor`, `Formatters`.

## Phasing

1. `FileNode` + `FileTreeBuilder` (+ persistence) + tests.
2. `TreemapLayout` (squarified) + `FileKind` + tests.
3. `TreemapCanvas` render + breadcrumb + legend.
4. Hover/info + drill-down.
5. Reveal in Finder + Move to Trash + live tree update.
6. Wire the "Explorer" sidebar tab; verify by running the app.
