import Foundation

/// Lazy treemap data source. One walk computes every folder's total size into a compact index
/// (no file/tree retention → bounded memory); the view then materializes ONE level at a time on
/// demand, taking subfolder sizes from the index (instant) and file sizes from a fresh listing.
enum FileTreeBuilder {
    struct Progress { let filesScanned: Int; let currentPath: String }

    /// Only SIGNIFICANT folders are cached. A dev disk can have millions of folders
    /// (node_modules nesting), so caching every one is itself gigabytes — we cache folders
    /// >= `cacheFloor` and size the (small) rest on demand via `quickSize`, which is cheap
    /// precisely because they're small.
    private static let cacheFloor: Int64 = 8_000_000   // 8 MB

    /// Significant folder path (standardized) → total allocated bytes. Bounded to thousands of
    /// entries (only big folders), so it stays a few MB even for a whole disk.
    final class SizeIndex: @unchecked Sendable {
        var sizes: [String: Int64] = [:]
        /// Cached size if significant; otherwise compute it on demand (the folder is small → fast).
        func size(of url: URL) -> Int64 {
            if let cached = sizes[url.standardizedFileURL.path] { return cached }
            return FileTreeBuilder.quickSize(url)
        }
    }

    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isSymbolicLinkKey]

    /// Protected media-library package bundles (see ProtectedLibraryPaths). Descending into these
    /// triggers a blocking macOS privacy (TCC) prompt for Photos/Apple Music access, which would
    /// stall the walk — so we treat them as opaque leaves the same way the OS treats packages.
    private static func isProtectedLibrary(_ url: URL) -> Bool {
        ProtectedLibraryPaths.isProtectedBundle(url)
    }

    // MARK: - One-time size walk

    /// Walk `roots` once and record every folder's total size. Off-thread, cancellable. Retains
    /// only the size index — no per-file nodes, no tree.
    static func indexSizes(roots: [URL],
                           token: CancellationToken,
                           progress: @escaping (Progress) -> Void) async -> SizeIndex? {
        await Task.detached(priority: .utility) {
            let index = SizeIndex()
            var counter = 0
            for root in roots {
                if token.isCancelled { return nil }
                _ = sumFolder(root, index: index, token: token, counter: &counter, progress: progress)
            }
            return token.isCancelled ? nil : index
        }.value
    }

    @discardableResult
    private static func sumFolder(_ url: URL, index: SizeIndex, token: CancellationToken,
                                  counter: inout Int, progress: @escaping (Progress) -> Void) -> Int64 {
        if token.isCancelled { return 0 }
        guard let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            index.sizes[url.standardizedFileURL.path] = 0
            return 0
        }
        var total: Int64 = 0
        for child in entries {
            if token.isCancelled { return total }
            let v = try? child.resourceValues(forKeys: keys)
            if v?.isSymbolicLink == true { continue }   // don't follow symlinks (cycles / double count)
            if v?.isDirectory == true {
                if isProtectedLibrary(child) { continue }   // don't descend (would trigger a blocking TCC prompt)
                total += sumFolder(child, index: index, token: token, counter: &counter, progress: progress)
            } else {
                counter += 1
                if counter % 4000 == 0 { progress(Progress(filesScanned: counter, currentPath: child.path)) }
                total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
            }
        }
        // Only cache SIGNIFICANT folders; small ones are sized on demand (cheap) to keep the
        // index a few MB instead of gigabytes on a disk with millions of folders.
        if total >= cacheFloor { index.sizes[url.standardizedFileURL.path] = total }
        return total
    }

    /// Node-free subtree size (used to size small, uncached folders on demand — fast since small).
    static func quickSize(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                      options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: keys)
            if v?.isSymbolicLink == true { continue }
            if v?.isDirectory == true {
                if isProtectedLibrary(f) { en.skipDescendants() }   // don't enter protected media bundles
                continue
            }
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }

    // MARK: - Per-level materialization

    /// Build ONE level: the immediate children of `folderURL` as view nodes. Subfolder sizes come
    /// from `index` (instant); file sizes from this single directory read. Small files AND small
    /// subfolders fold into one "N small items" tile (the threshold scales per level). Returns
    /// nodes sorted largest-first. Cheap — no subtree walk — so it's safe to call on each drill.
    static func levelChildren(of folderURL: URL, index: SizeIndex) -> [FileNode] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
                at: folderURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [] }

        var folders: [FileNode] = []
        var files: [(name: String, url: URL, size: Int64)] = []
        for child in entries {
            let v = try? child.resourceValues(forKeys: keys)
            if v?.isSymbolicLink == true { continue }
            if v?.isDirectory == true {
                if isProtectedLibrary(child) { continue }   // skip protected media bundles (TCC)
                folders.append(FileNode(name: child.lastPathComponent, url: child,
                                        sizeBytes: index.size(of: child), isDirectory: true))
            } else {
                files.append((child.lastPathComponent, child, Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)))
            }
        }

        let total = folders.reduce(0) { $0 + $1.sizeBytes } + files.reduce(0) { $0 + $1.size }
        let threshold = max(Int64(64_000), Int64(Double(total) * 0.002))
        var kept: [FileNode] = []
        var tailBytes: Int64 = 0
        var tailCount = 0
        var lone: FileNode?

        for fn in folders {
            if fn.sizeBytes >= threshold { kept.append(fn) }
            else { tailBytes += fn.sizeBytes; tailCount += 1; lone = fn }
        }
        for f in files {
            if f.size >= threshold {
                kept.append(FileNode(name: f.name, url: f.url, sizeBytes: f.size, isDirectory: false))
            } else {
                tailBytes += f.size; tailCount += 1
                lone = FileNode(name: f.name, url: f.url, sizeBytes: f.size, isDirectory: false)
            }
        }
        if tailCount == 1, let lone {
            kept.append(lone)
        } else if tailCount > 1 {
            let agg = FileNode(name: "\(tailCount) small items", url: folderURL, sizeBytes: tailBytes, isDirectory: false)
            agg.isSynthetic = true
            kept.append(agg)
        }

        return kept.sorted { $0.sizeBytes > $1.sizeBytes }
    }
}
