import Foundation

enum FileTreeBuilder {
    struct Progress { let filesScanned: Int; let currentPath: String }

    /// Build an aggregated tree for `root` (runs off the caller's thread via a detached task).
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

        if values?.isSymbolicLink == true { return nil } // don't follow symlinks (cycles / double count)

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
            return FileNode(name: url.lastPathComponent, url: url, isDirectory: true,
                            children: collapseTail(kids, parentURL: url))
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
            kept.append(FileNode(name: "\(tailCount) small items", url: parentURL,
                                 sizeBytes: tailBytes, isDirectory: false))
        } else if tailCount == 1, let only = kids.first(where: { !$0.isDirectory && $0.sizeBytes < threshold }) {
            kept.append(only) // a single small file isn't worth collapsing
        }
        return kept
    }
}
