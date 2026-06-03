# Treemap "Explorer" Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a GrandPerspective-style squarified treemap "Explorer" tab that visualizes the whole disk as size-proportional, file-kind-colored rectangles with drill-down, reveal-in-Finder, and move-to-Trash.

**Architecture:** An on-demand pass builds an aggregated directory tree (`FileNode`) across the scan roots, cached to disk. A pure squarified layout (`TreemapLayout`) turns a node's children into rectangles, rendered with SwiftUI `Canvas` (cushion shading, file-kind colors). A `@MainActor` `ExplorerViewModel` owns the tree + drill-down stack. Tail-collapsing folds tiny files into "N small items" tiles for scale.

**Tech Stack:** Swift 5.9 / SwiftUI (macOS 14), SwiftPM, XCTest. Build: `swift build`. Test: `swift test`. Reuses `ScanRootsBuilder`, `DeleteEngine`, `ScanDataStore`, `MemoryPressureMonitor`, `Formatters`, `CancellationToken`.

**Design doc:** `docs/plans/2026-06-03-treemap-explorer-design.md`

**Conventions:** TDD for pure logic (run test → see it fail → implement → see it pass → commit). SwiftUI views are verified by building + running the app (no unit tests). Keep each commit green (`swift build && swift test`).

---

## Task 1: FileKind mapping (extension → kind + color)

**Files:**
- Create: `StorageAI/Services/FileKind.swift`
- Test: `Tests/StorageAITests/FileKindTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest
import SwiftUI
@testable import StorageAI

final class FileKindTests: XCTestCase {
    func testCommonExtensionsMapToExpectedKinds() {
        XCTAssertEqual(FileKind.forExtension("jpg"), .image)
        XCTAssertEqual(FileKind.forExtension("PNG"), .image)      // case-insensitive
        XCTAssertEqual(FileKind.forExtension("mp4"), .video)
        XCTAssertEqual(FileKind.forExtension("mp3"), .audio)
        XCTAssertEqual(FileKind.forExtension("swift"), .code)
        XCTAssertEqual(FileKind.forExtension("zip"), .archive)
        XCTAssertEqual(FileKind.forExtension("pdf"), .document)
        XCTAssertEqual(FileKind.forExtension("app"), .application)
        XCTAssertEqual(FileKind.forExtension("xyzunknown"), .other)
        XCTAssertEqual(FileKind.forExtension(""), .other)
    }

    func testEveryKindHasADistinctColorAndLabel() {
        let kinds = FileKind.allCases
        XCTAssertEqual(Set(kinds.map(\.label)).count, kinds.count)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter FileKindTests`
Expected: FAIL to compile ("cannot find 'FileKind'").

**Step 3: Write minimal implementation**

```swift
import SwiftUI

enum FileKind: String, CaseIterable {
    case image, video, audio, code, archive, document, application, folder, other

    var label: String {
        switch self {
        case .image: return "Images"
        case .video: return "Video"
        case .audio: return "Audio"
        case .code: return "Code"
        case .archive: return "Archives"
        case .document: return "Documents"
        case .application: return "Apps"
        case .folder: return "Folders"
        case .other: return "Other"
        }
    }

    var color: Color {
        switch self {
        case .image: return .purple
        case .video: return .pink
        case .audio: return .orange
        case .code: return .blue
        case .archive: return .brown
        case .document: return .teal
        case .application: return .green
        case .folder: return Color.secondary.opacity(0.5)
        case .other: return .gray
        }
    }

    private static let map: [String: FileKind] = {
        var m: [String: FileKind] = [:]
        for e in ["jpg","jpeg","png","gif","heic","heif","raw","tiff","tif","bmp","webp","svg","icns"] { m[e] = .image }
        for e in ["mp4","mov","avi","mkv","m4v","webm","mpg","mpeg","wmv","flv"] { m[e] = .video }
        for e in ["mp3","aac","flac","wav","m4a","aiff","ogg","alac"] { m[e] = .audio }
        for e in ["swift","m","mm","h","hpp","c","cc","cpp","py","js","ts","jsx","tsx","java","kt","go","rs","rb","php","cs","json","xml","yml","yaml","sh","sql"] { m[e] = .code }
        for e in ["zip","gz","tar","tgz","bz2","xz","7z","rar","dmg","pkg","iso"] { m[e] = .archive }
        for e in ["pdf","doc","docx","xls","xlsx","ppt","pptx","txt","md","rtf","pages","numbers","key","csv","epub"] { m[e] = .document }
        for e in ["app","ipa","apk"] { m[e] = .application }
        return m
    }()

    static func forExtension(_ ext: String) -> FileKind {
        map[ext.lowercased()] ?? .other
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter FileKindTests`
Expected: PASS (2 tests).

**Step 5: Commit**

```bash
git add StorageAI/Services/FileKind.swift Tests/StorageAITests/FileKindTests.swift
git commit -m "feat(explorer): file-kind extension->kind/color mapping"
```

---

## Task 2: FileNode model + size aggregation

**Files:**
- Create: `StorageAI/Models/FileTree.swift`
- Test: `Tests/StorageAITests/FileNodeTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest
@testable import StorageAI

final class FileNodeTests: XCTestCase {
    func testFolderAggregatesChildrenSizes() {
        let a = FileNode(name: "a.jpg", url: URL(fileURLWithPath: "/x/a.jpg"), sizeBytes: 100, isDirectory: false)
        let b = FileNode(name: "b.mp4", url: URL(fileURLWithPath: "/x/b.mp4"), sizeBytes: 250, isDirectory: false)
        let dir = FileNode(name: "x", url: URL(fileURLWithPath: "/x"), isDirectory: true, children: [a, b])
        XCTAssertEqual(dir.sizeBytes, 350)
        XCTAssertEqual(dir.kind, .folder)
        XCTAssertEqual(a.kind, .image)
    }

    func testSubtractRemovesNodeAndUpdatesAncestors() {
        let a = FileNode(name: "a", url: URL(fileURLWithPath: "/x/a"), sizeBytes: 100, isDirectory: false)
        let b = FileNode(name: "b", url: URL(fileURLWithPath: "/x/b"), sizeBytes: 250, isDirectory: false)
        let dir = FileNode(name: "x", url: URL(fileURLWithPath: "/x"), isDirectory: true, children: [a, b])
        dir.removeChild(a)
        XCTAssertEqual(dir.children?.count, 1)
        XCTAssertEqual(dir.sizeBytes, 250)
    }
}
```

**Step 2: Run** `swift test --filter FileNodeTests` → FAIL (no `FileNode`).

**Step 3: Implement**

```swift
import Foundation

final class FileNode {
    let name: String
    let url: URL
    let isDirectory: Bool
    private(set) var sizeBytes: Int64
    private(set) var children: [FileNode]?
    weak var parent: FileNode?
    let kind: FileKind

    // File initializer
    init(name: String, url: URL, sizeBytes: Int64, isDirectory: Bool) {
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.children = isDirectory ? [] : nil
        self.kind = isDirectory ? .folder : FileKind.forExtension(url.pathExtension)
    }

    // Folder initializer with children (sizes aggregated)
    convenience init(name: String, url: URL, isDirectory: Bool, children: [FileNode]) {
        self.init(name: name, url: url, sizeBytes: 0, isDirectory: isDirectory)
        self.children = children
        for c in children { c.parent = self }
        self.sizeBytes = children.reduce(0) { $0 + $1.sizeBytes }
    }

    func addChild(_ node: FileNode) {
        node.parent = self
        children?.append(node)
        sizeBytes += node.sizeBytes
    }

    /// Set size directly (used by the builder while aggregating bottom-up).
    func setSize(_ bytes: Int64) { sizeBytes = bytes }

    /// Remove a child and propagate the size delta up the ancestor chain.
    func removeChild(_ node: FileNode) {
        guard var kids = children, let idx = kids.firstIndex(where: { $0 === node }) else { return }
        let delta = node.sizeBytes
        kids.remove(at: idx)
        children = kids
        var n: FileNode? = self
        while let cur = n { cur.sizeBytes = max(0, cur.sizeBytes - delta); n = cur.parent }
    }
}
```

**Step 4: Run** `swift test --filter FileNodeTests` → PASS.

**Step 5: Commit** `feat(explorer): FileNode tree model with size aggregation`

---

## Task 3: Squarified treemap layout (pure algorithm)

**Files:**
- Create: `StorageAI/Services/TreemapLayout.swift`
- Test: `Tests/StorageAITests/TreemapLayoutTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest
import CoreGraphics
@testable import StorageAI

final class TreemapLayoutTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 600, height: 400)

    func testTilesCoverRectAreaWithoutOverlap() {
        let items = [("a", 6.0), ("b", 6.0), ("c", 4.0), ("d", 3.0), ("e", 2.0), ("f", 1.0)]
        let tiles = TreemapLayout.squarify(items.map { (id: $0.0, weight: $0.1) }, in: rect)
        XCTAssertEqual(tiles.count, items.count)
        let area = tiles.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        XCTAssertEqual(area, Double(rect.width * rect.height), accuracy: 1.0) // tiles tile the rect
        for t in tiles {  // all within bounds
            XCTAssertTrue(rect.insetBy(dx: -0.5, dy: -0.5).contains(t.rect))
        }
    }

    func testAreaIsProportionalToWeight() {
        let tiles = TreemapLayout.squarify([(id: "big", weight: 3.0), (id: "small", weight: 1.0)], in: rect)
        let big = tiles.first { $0.id == "big" }!.rect
        let small = tiles.first { $0.id == "small" }!.rect
        let ratio = Double(big.width * big.height) / Double(small.width * small.height)
        XCTAssertEqual(ratio, 3.0, accuracy: 0.05)
    }

    func testIgnoresZeroAndNegativeWeights() {
        let tiles = TreemapLayout.squarify([(id: "a", weight: 1.0), (id: "z", weight: 0.0)], in: rect)
        XCTAssertEqual(tiles.map(\.id), ["a"])
    }

    func testEmptyOrZeroRectReturnsNoTiles() {
        XCTAssertTrue(TreemapLayout.squarify([(id: "a", weight: 1.0)], in: .zero).isEmpty)
        XCTAssertTrue(TreemapLayout.squarify([], in: rect).isEmpty)
    }
}
```

**Step 2: Run** `swift test --filter TreemapLayoutTests` → FAIL.

**Step 3: Implement** (standard squarified algorithm, Bruls et al.)

```swift
import CoreGraphics

enum TreemapLayout {
    struct Tile<ID> { let id: ID; let rect: CGRect }

    static func squarify<ID>(_ items: [(id: ID, weight: Double)], in rect: CGRect) -> [Tile<ID>] {
        let positive = items.filter { $0.weight > 0 }
        guard !positive.isEmpty, rect.width > 0, rect.height > 0 else { return [] }

        let totalWeight = positive.reduce(0) { $0 + $1.weight }
        let totalArea = Double(rect.width) * Double(rect.height)
        let scaled = positive.map { (id: $0.id, area: $0.weight / totalWeight * totalArea) }

        var tiles: [Tile<ID>] = []
        var free = rect
        var row: [(id: ID, area: Double)] = []

        func shortest(_ r: CGRect) -> Double { Double(min(r.width, r.height)) }

        func worst(_ row: [(id: ID, area: Double)], _ side: Double) -> Double {
            guard !row.isEmpty, side > 0 else { return .greatestFiniteMagnitude }
            let s = row.reduce(0) { $0 + $1.area }
            let rmax = row.map(\.area).max() ?? 0
            let rmin = row.map(\.area).min() ?? 0
            guard s > 0, rmin > 0 else { return .greatestFiniteMagnitude }
            let side2 = side * side, s2 = s * s
            return max(side2 * rmax / s2, s2 / (side2 * rmin))
        }

        func place(_ row: [(id: ID, area: Double)]) {
            let s = row.reduce(0) { $0 + $1.area }
            guard s > 0 else { return }
            if free.width >= free.height {
                let colW = CGFloat(s / Double(free.height))
                var y = free.minY
                for it in row {
                    let h = CGFloat(it.area / s) * free.height
                    tiles.append(Tile(id: it.id, rect: CGRect(x: free.minX, y: y, width: colW, height: h)))
                    y += h
                }
                free = CGRect(x: free.minX + colW, y: free.minY, width: free.width - colW, height: free.height)
            } else {
                let rowH = CGFloat(s / Double(free.width))
                var x = free.minX
                for it in row {
                    let w = CGFloat(it.area / s) * free.width
                    tiles.append(Tile(id: it.id, rect: CGRect(x: x, y: free.minY, width: w, height: rowH)))
                    x += w
                }
                free = CGRect(x: free.minX, y: free.minY + rowH, width: free.width, height: free.height - rowH)
            }
        }

        var i = 0
        while i < scaled.count {
            let candidate = scaled[i]
            let side = shortest(free)
            if row.isEmpty || worst(row, side) >= worst(row + [candidate], side) {
                row.append(candidate); i += 1
            } else {
                place(row); row = []
            }
        }
        if !row.isEmpty { place(row) }
        return tiles
    }
}
```

**Step 4: Run** `swift test --filter TreemapLayoutTests` → PASS.

**Step 5: Commit** `feat(explorer): squarified treemap layout algorithm`

---

## Task 4: FileTreeBuilder (recursive walk + tail-collapse)

**Files:**
- Create: `StorageAI/Services/FileTreeBuilder.swift`
- Test: `Tests/StorageAITests/FileTreeBuilderTests.swift`

**Step 1: Write the failing test** (builds a tree over a real temp dir; verifies aggregation + tail-collapse)

```swift
import XCTest
@testable import StorageAI

final class FileTreeBuilderTests: XCTestCase {
    private func makeTempTree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ExplorerTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(count: 500_000).write(to: root.appendingPathComponent("big.bin"))        // 500 KB
        try Data(count: 10).write(to: root.appendingPathComponent("tiny1.txt"))           // tail
        try Data(count: 10).write(to: root.appendingPathComponent("tiny2.txt"))           // tail
        try Data(count: 300_000).write(to: root.appendingPathComponent("sub/m.bin"))      // 300 KB
        return root
    }

    func testBuildsAggregatedTree() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let node = await FileTreeBuilder.build(root: root, token: CancellationToken(), progress: { _ in })
        XCTAssertNotNil(node)
        // total ~= 500000 + 300000 + 20 (tiny) == 800020
        XCTAssertEqual(node!.sizeBytes, 800_020, accuracy: 2_000)
        // 'sub' folder aggregates its child
        let sub = node!.children?.first { $0.name == "sub" }
        XCTAssertEqual(sub?.sizeBytes, 300_000, accuracy: 2_000)
    }

    func testTailCollapsesSmallFilesIntoAggregate() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let node = await FileTreeBuilder.build(root: root, token: CancellationToken(), progress: { _ in })
        // tiny1.txt + tiny2.txt fall below threshold -> collapsed into one synthetic node
        let names = Set(node!.children?.map(\.name) ?? [])
        XCTAssertFalse(names.contains("tiny1.txt"))
        XCTAssertTrue(node!.children?.contains { $0.name.contains("small item") } ?? false)
        XCTAssertTrue(names.contains("big.bin"))   // big files retained
    }

    func testCancellationReturnsNil() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = CancellationToken(); token.cancel()
        let node = await FileTreeBuilder.build(root: root, token: token, progress: { _ in })
        XCTAssertNil(node)
    }
}
```

**Step 2: Run** `swift test --filter FileTreeBuilderTests` → FAIL.

**Step 3: Implement**

```swift
import Foundation

enum FileTreeBuilder {
    struct Progress { let filesScanned: Int; let currentPath: String }

    /// Build an aggregated tree for `root`, off the caller's responsibility to run off-main.
    /// Files below an adaptive per-folder threshold collapse into one "N small items" node.
    static func build(root: URL,
                      token: CancellationToken,
                      progress: @escaping (Progress) -> Void) async -> FileNode? {
        await Task.detached(priority: .utility) {
            var counter = 0
            return buildSync(url: root, token: token, counter: &counter, progress: progress)
        }.value
    }

    /// Build a synthetic root containing several top-level roots (whole-disk view).
    static func buildAll(roots: [URL],
                         token: CancellationToken,
                         progress: @escaping (Progress) -> Void) async -> FileNode? {
        await Task.detached(priority: .utility) {
            var counter = 0
            var children: [FileNode] = []
            for r in roots {
                if token.isCancelled { return nil }
                if let n = buildSync(url: r, token: token, counter: &counter, progress: progress) {
                    children.append(n)
                }
            }
            guard !token.isCancelled, !children.isEmpty else { return nil }
            return FileNode(name: "All Locations", url: URL(fileURLWithPath: "/"), isDirectory: true, children: children)
        }.value
    }

    private static func buildSync(url: URL, token: CancellationToken,
                                  counter: inout Int,
                                  progress: @escaping (Progress) -> Void) -> FileNode? {
        if token.isCancelled { return nil }
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        let values = try? url.resourceValues(forKeys: keys)

        if values?.isSymbolicLink == true { return nil } // don't follow symlinks (avoid cycles/double count)

        if values?.isDirectory == true {
            guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys),
                                                            options: [.skipsHiddenFiles]) else {
                return FileNode(name: url.lastPathComponent, url: url, sizeBytes: 0, isDirectory: true)
            }
            var kids: [FileNode] = []
            for child in entries {
                if token.isCancelled { return nil }
                if let n = buildSync(url: child, token: token, counter: &counter, progress: progress) {
                    kids.append(n)
                }
            }
            let folder = FileNode(name: url.lastPathComponent, url: url, isDirectory: true, children: collapseTail(kids, parentURL: url))
            return folder
        } else {
            counter += 1
            if counter % 2000 == 0 { progress(Progress(filesScanned: counter, currentPath: url.path)) }
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            return FileNode(name: url.lastPathComponent, url: url, sizeBytes: size, isDirectory: false)
        }
    }

    /// Collapse files (not folders) below max(64KB, 0.1% of folder total) into one synthetic node.
    private static func collapseTail(_ kids: [FileNode], parentURL: URL) -> [FileNode] {
        let total = kids.reduce(0) { $0 + $1.sizeBytes }
        let threshold = max(Int64(64_000), Int64(Double(total) * 0.001))
        var kept: [FileNode] = []
        var tailBytes: Int64 = 0
        var tailCount = 0
        for k in kids {
            if !k.isDirectory && k.sizeBytes < threshold {
                tailBytes += k.sizeBytes; tailCount += 1
            } else {
                kept.append(k)
            }
        }
        if tailCount > 1 {
            let agg = FileNode(name: "\(tailCount) small items",
                               url: parentURL, sizeBytes: tailBytes, isDirectory: false)
            kept.append(agg)
        } else if tailCount == 1, let only = kids.first(where: { !$0.isDirectory && $0.sizeBytes < threshold }) {
            kept.append(only) // a single small file isn't worth collapsing
        }
        return kept
    }
}
```

Note: `inout` across the recursive calls within a single detached task is fine (single-threaded build). `collapseTail` runs after children are built so `total` is known.

**Step 4: Run** `swift test --filter FileTreeBuilderTests` → PASS.

**Step 5: Commit** `feat(explorer): directory tree builder with tail-collapse + cancellation`

---

## Task 5: ExplorerViewModel (tree ownership, drill-down, build/load state)

**Files:**
- Create: `StorageAI/Models/ExplorerViewModel.swift`

No unit test (MainActor + filesystem + UI state); verified by running. Keep logic thin.

**Step 1: Implement**

```swift
import SwiftUI

@MainActor
final class ExplorerViewModel: ObservableObject {
    enum State: Equatable { case idle, building(progress: String), ready, failed(String), empty }

    @Published private(set) var state: State = .idle
    @Published private(set) var rootStack: [FileNode] = []     // breadcrumb: last = current root
    @Published var selected: FileNode?

    private var fullRoot: FileNode?
    private var buildTask: Task<Void, Never>?
    private var token: CancellationToken?

    var currentRoot: FileNode? { rootStack.last }
    var breadcrumb: [FileNode] { rootStack }

    func buildIfNeeded(settings: AppSettings) {
        guard fullRoot == nil, case .idle = state else { return }
        rebuild(settings: settings)
    }

    func rebuild(settings: AppSettings) {
        buildTask?.cancel(); token?.cancel()
        let token = CancellationToken(); self.token = token
        state = .building(progress: "Scanning…")
        let roots = ScanRootsBuilder.roots(settings: settings)
        buildTask = Task { [weak self] in
            let node = await FileTreeBuilder.buildAll(roots: roots, token: token) { p in
                Task { @MainActor in
                    if case .building = self?.state { self?.state = .building(progress: p.currentPath) }
                }
            }
            await MainActor.run {
                guard let self, !token.isCancelled else { return }
                if let node, (node.children?.isEmpty == false) {
                    self.fullRoot = node
                    self.rootStack = [node]
                    self.state = .ready
                } else {
                    self.state = .empty
                }
            }
        }
    }

    func drillInto(_ node: FileNode) {
        guard node.isDirectory, (node.children?.isEmpty == false) else { return }
        rootStack.append(node)
        selected = nil
    }

    func navigate(to index: Int) {
        guard index >= 0, index < rootStack.count else { return }
        rootStack = Array(rootStack.prefix(index + 1))
        selected = nil
    }

    /// Remove a node after it was trashed; update sizes + re-derive current root.
    func didTrash(_ node: FileNode) {
        node.parent?.removeChild(node)
        if selected === node { selected = nil }
        // Re-publish (FileNode is a reference type; nudge SwiftUI)
        objectWillChange.send()
    }

    func cancel() { buildTask?.cancel(); token?.cancel() }
}
```

**Step 2: Build** `swift build` → succeeds.

**Step 3: Commit** `feat(explorer): ExplorerViewModel (tree, drill-down, build state)`

---

## Task 6: TreemapCanvas + ExplorerView (render, breadcrumb, legend, hover)

**Files:**
- Create: `StorageAI/Views/ExplorerView.swift`

No unit test; verify by building + running. Key pieces:

**TreemapCanvas** — a `View` taking `root: FileNode`, `selected`, callbacks `onHover(FileNode?)`, `onTap(FileNode)`, `onSecondary(FileNode, CGPoint)`:
- In `Canvas { ctx, size in ... }`: compute `let tiles = TreemapLayout.squarify(root.children.map { (id: ObjectIdentifier($0), weight: Double($0.sizeBytes)) }, in: CGRect(origin: .zero, size: size))`, keep a parallel `[(rect, node)]` via a dictionary `ObjectIdentifier->node`.
- Draw each tile: fill with `node.kind.color`, add a subtle cushion (a `LinearGradient`/overlay via `ctx.fill` with opacity gradient), 1px border, and the name + `Formatters.bytes` if the rect is large enough (> ~60×24).
- Recurse one extra level for folder tiles big enough (> ~80×80): squarify the folder's children inside its rect and draw them (gives the nested look) — but keep hit-testing at the top visible level for simplicity in v1 (drill-down handles deeper).
- Store the laid-out `[(CGRect, FileNode)]` in a `@State` for hit-testing.
- `.onContinuousHover { phase in ... }` → find tile under point → `onHover(node)`.
- `.gesture(TapGesture)` + a `.onTapGesture(coordinateSpace)` (use `SpatialTapGesture` on macOS 14) → tile under point → `onTap`.
- Right-click: wrap tiles in `.contextMenu` is awkward in Canvas; instead use a `SpatialTapGesture(count:1, button:?)` — on macOS, detect right-click via an `NSViewRepresentable` overlay OR a `.contextMenu` on the whole canvas that acts on `hoveredNode`. v1: `.contextMenu { Button("Reveal in Finder")…; Button("Move to Trash", role:.destructive)… }` keyed off the hovered/selected node.

**ExplorerView** layout:
```
VStack(spacing: 0) {
  header            // title + "Open Folder…" + "Rebuild" buttons
  breadcrumbBar     // ForEach(viewModel.breadcrumb) tappable -> navigate(to:)
  switch state {
    case .building(let p): ProgressView + p + Cancel
    case .empty:   "No data — run a scan or pick a folder"
    case .failed(let e): error
    case .ready:   TreemapCanvas(root: currentRoot) + infoOverlay(selected/hovered) + legend
    case .idle:    Color.clear.onAppear { buildIfNeeded(settings:) }
  }
}
```
- `infoOverlay`: path, `Formatters.bytes(size)`, kind label, modified date (read lazily).
- `legend`: `ForEach(FileKind.allCases)` chip with color + label.
- "Open Folder…": `NSOpenPanel` (canChooseDirectories) → `FileTreeBuilder.build(root:)` for that folder → set as root stack.

**Step: Build** `swift build` → succeeds (a `#Preview` with a small hand-built FileNode tree is fine).

**Commit** `feat(explorer): treemap Canvas view with breadcrumb, legend, hover info`

---

## Task 7: Reveal in Finder + Move to Trash + live update

**Files:**
- Modify: `StorageAI/Views/ExplorerView.swift`

**Step 1:** Context menu / action bar actions on the selected (or hovered) `FileNode`:
- Reveal: `NSWorkspace.shared.activateFileViewerSelecting([node.url])`.
- Move to Trash: confirmation alert → `let outcome = DeleteEngine.trashFiles([node.url])` →
  if `outcome.trashed.contains(where: { $0.path == node.url.path })` { `viewModel.didTrash(node)` } else surface `outcome.failed`/`blocked` message. Disable Trash for the synthetic "N small items" aggregate and the synthetic "All Locations" root.

**Step 2: Build + run** the app, open Explorer, trash a test file, confirm it's gone + tree/areas update.

**Commit** `feat(explorer): reveal-in-Finder + safe move-to-Trash with live tree update`

---

## Task 8: Wire the Explorer sidebar tab + verify by running

**Files:**
- Modify: `StorageAI/Views/DashboardView.swift` (NavigationItem enum + detailView switch)

**Step 1:** Add case to `NavigationItem`:
```swift
case explorer = "Explorer"
// icon:
case .explorer: return "square.grid.3x3.fill"
```
Place it after `.categories` (or wherever fits the order). Add to `detailView`:
```swift
case .explorer:
    ExplorerView()
        .environmentObject(appState)
```
`ExplorerView` creates its own `@StateObject ExplorerViewModel`; reads `appState.settings` for roots. It's under RootView's env injection so `scanService`/`ollamaSetupService` aren't required by it.

**Step 2:** `swift build && swift test` → green (23+ tests pass).

**Step 3: Verify by running** (use the `run` skill / install-and-launch flow): build release, install to `/Applications/Storage AI.app`, launch, click **Explorer**, confirm: tree builds with progress, treemap renders colored tiles, hover shows info, click drills in, breadcrumb climbs back, legend shows, reveal + trash work. Capture screenshots.

**Commit** `feat(explorer): add Explorer treemap tab to the dashboard`

---

## Definition of done

- All new unit tests pass (`FileKind`, `FileNode`, `TreemapLayout`, `FileTreeBuilder`).
- `swift build` + `swift build -c release` warning-clean; `swift test` green.
- Explorer tab verified in the running app: build → render → hover → drill-down → breadcrumb → reveal → trash → live update.
- Design doc + this plan committed under `docs/plans/`.

## Notes / risks

- **Memory at full-disk scale:** tail-collapsing + skipping symlinks bounds it; if still heavy, add a depth cap or a min-size prune in `buildSync`. Persisting the tree (design doc) is a follow-up optimization — v1 rebuilds on tab open with progress + Cancel, which is acceptable; add `ScanDataStore` persistence in a later task if reopen latency is annoying.
- **Right-click in Canvas:** if `.contextMenu` keyed off hovered node proves fiddly, fall back to a small action bar (Reveal / Trash buttons) operating on `selected`.
- **Cushion shading:** start with flat fills + border; add the gradient cushion once the layout/interaction is solid (purely cosmetic).
