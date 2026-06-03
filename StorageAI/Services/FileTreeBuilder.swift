import Foundation

enum FileTreeBuilder {
    struct Progress { let filesScanned: Int; let currentPath: String }

    /// Beyond this depth a folder collapses into a single sized tile (no children) — keeps deep
    /// trees (node_modules, site-packages) from exploding node count/memory.
    private static let maxDepth = 10

    /// Build an aggregated tree for `root` (runs off the caller's thread via a detached task).
    /// Files below an adaptive per-folder threshold are aggregated WITHOUT allocating a node each
    /// (the long tail of tiny files is what would otherwise blow up memory on a full-disk build).
    static func build(root: URL,
                      token: CancellationToken,
                      progress: @escaping (Progress) -> Void) async -> FileNode? {
        await Task.detached(priority: .utility) {
            var counter = 0
            return buildSync(url: root, depth: 0, token: token, counter: &counter, progress: progress)
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
                if let n = buildSync(url: r, depth: 1, token: token, counter: &counter, progress: progress) {
                    children.append(n)
                }
            }
            guard !token.isCancelled, !children.isEmpty else { return nil }
            let root = FileNode(name: "All Locations", url: URL(fileURLWithPath: "/"), isDirectory: true, children: children)
            root.isSynthetic = true
            return root
        }.value
    }

    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey]

    private static func buildSync(url: URL, depth: Int, token: CancellationToken,
                                  counter: inout Int,
                                  progress: @escaping (Progress) -> Void) -> FileNode? {
        if token.isCancelled { return nil }
        let values = try? url.resourceValues(forKeys: keys)
        if values?.isSymbolicLink == true { return nil } // don't follow symlinks (cycles / double count)

        guard values?.isDirectory == true else {
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            return FileNode(name: url.lastPathComponent, url: url, sizeBytes: size, isDirectory: false)
        }

        // Depth cap: collapse this (deep) folder into one sized tile without building children.
        if depth >= maxDepth {
            return FileNode(name: url.lastPathComponent, url: url, sizeBytes: quickSize(url, token: token), isDirectory: true)
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            return FileNode(name: url.lastPathComponent, url: url, sizeBytes: 0, isDirectory: true)
        }

        var folderNodes: [FileNode] = []
        var files: [(name: String, url: URL, size: Int64)] = []
        for child in entries {
            if token.isCancelled { return nil }
            let cv = try? child.resourceValues(forKeys: keys)
            if cv?.isSymbolicLink == true { continue }
            if cv?.isDirectory == true {
                if let n = buildSync(url: child, depth: depth + 1, token: token, counter: &counter, progress: progress) {
                    folderNodes.append(n)
                }
            } else {
                counter += 1
                if counter % 4000 == 0 { progress(Progress(filesScanned: counter, currentPath: child.path)) }
                files.append((child.lastPathComponent, child, Int64(cv?.totalFileAllocatedSize ?? cv?.fileSize ?? 0)))
            }
        }

        // Adaptive threshold from the folder total. BOTH small files and small subfolders fold
        // into one "N small items" tile — folding folders (discarding their already-collapsed
        // subtree) is what bounds the retained tree on a full-disk build. The threshold scales
        // per level, so granularity increases as you drill into a folder.
        let total = folderNodes.reduce(0) { $0 + $1.sizeBytes } + files.reduce(0) { $0 + $1.size }
        let threshold = max(Int64(64_000), Int64(Double(total) * 0.002))
        var kept: [FileNode] = []
        var tailBytes: Int64 = 0
        var tailCount = 0
        var lone: FileNode?

        for fn in folderNodes {
            if fn.sizeBytes >= threshold {
                kept.append(fn)
            } else {
                tailBytes += fn.sizeBytes; tailCount += 1; lone = fn   // node discarded unless it's the only tail item
            }
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
            kept.append(lone)                       // a single small item isn't worth aggregating
        } else if tailCount > 1 {
            let agg = FileNode(name: "\(tailCount) small items", url: url, sizeBytes: tailBytes, isDirectory: false)
            agg.isSynthetic = true                  // aggregate of many items; not a single deletable thing
            kept.append(agg)
        }

        return FileNode(name: url.lastPathComponent, url: url, isDirectory: true, children: kept)
    }

    /// Sum the allocated size of a subtree without building nodes (used past the depth cap).
    private static func quickSize(_ url: URL, token: CancellationToken) -> Int64 {
        let sizeKeys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: sizeKeys,
                                                      options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        var i = 0
        for case let f as URL in en {
            i += 1
            if i % 4096 == 0 && token.isCancelled { break }
            let v = try? f.resourceValues(forKeys: Set(sizeKeys))
            guard v?.isRegularFile == true else { continue }
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
        }
        return total
    }
}
