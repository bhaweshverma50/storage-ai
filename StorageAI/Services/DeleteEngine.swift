import Foundation

enum DeleteEngine {
    /// Rich result of a delete/preview operation.
    /// We NEVER permanently delete: items are moved to the Trash (recoverable) or, if that
    /// fails, left in place and reported under `failed`.
    struct Outcome {
        struct FailedItem {
            let url: URL
            let reason: String
        }

        /// Items moved to Trash (or, in dry-run, the items that *would* be trashed).
        var trashed: [URL] = []
        /// Items that could not be trashed; left untouched on disk.
        var failed: [FailedItem] = []
        /// Items rejected by the safety guard (outside allowed roots / critical system paths).
        var blocked: [URL] = []
        /// Best-effort sum of trashed file sizes (0 when not computed).
        var freedBytes: Int64 = 0

        var trashedCount: Int { trashed.count }
        var failedCount: Int { failed.count }
        var blockedCount: Int { blocked.count }
        var didTrashNothing: Bool { trashed.isEmpty }
    }

    /// Well-known directories whose *contents* we clear, never the directory itself.
    /// (Includes Downloads so selecting it never trashes the whole folder as one item.)
    private static let contentsOnlyRelativePaths: [String] = [
        "Library/Caches",
        "Library/Logs",
        "Library/Containers",
        "Library/Application Support",
        "Downloads",
        ".Trash"
    ]

    // MARK: - Path normalization

    private static func normalized(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isSameOrDescendant(_ url: URL, of root: URL) -> Bool {
        let p = normalized(url)
        let r = normalized(root)
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    // MARK: - Safety guards

    /// Paths that must NEVER be deleted under any circumstances: filesystem root,
    /// volume roots, the user's home directory itself, and core OS trees.
    static func isCriticalSystemPath(_ url: URL) -> Bool {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let path = resolved.path

        if path.isEmpty || path == "/" { return true }

        // "/" -> ["/"]; "/Volumes" -> ["/", "Volumes"]; "/Volumes/Ext" -> ["/", "Volumes", "Ext"]
        let comps = resolved.pathComponents
        if comps.count <= 1 { return true }
        if comps.count <= 3, comps.first == "/", comps.dropFirst().first == "Volumes" { return true }

        // The home directory itself (but not its descendants).
        let home = normalized(FileManager.default.homeDirectoryForCurrentUser)
        if path == home { return true }

        // Core OS trees that should never be touched by this app.
        let criticalRoots = ["/System", "/usr", "/bin", "/sbin", "/private/var", "/private/etc", "/cores", "/Library"]
        for root in criticalRoots where path == root || path.hasPrefix(root + "/") {
            return true
        }
        return false
    }

    /// Positive allowlist for cleanup-target deletion: a path is acceptable only if it lies
    /// under one of the known-safe cleanup roots (and is not a critical system path).
    static func isWithinCleanupRoots(_ url: URL) -> Bool {
        if isCriticalSystemPath(url) { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            "Library/Caches",
            "Library/Logs",
            "Library/Containers",
            "Library/Group Containers",
            "Library/Application Support",
            "Library/Developer",
            "Downloads",
            ".Trash"
        ].map { home.appendingPathComponent($0) }

        return roots.contains { isSameOrDescendant(url, of: $0) }
    }

    private static func isContentsOnlyDirectory(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return contentsOnlyRelativePaths.contains { rel in
            normalized(url) == normalized(home.appendingPathComponent(rel))
        }
    }

    // MARK: - Trashing (never permanent)

    /// Move a single item to the Trash. On failure we DO NOT fall back to a permanent
    /// delete — the item is left in place and the failure recorded.
    private static func trashOne(_ url: URL, into outcome: inout Outcome) {
        let fm = FileManager.default
        let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]))
            .flatMap { Int64($0.totalFileAllocatedSize ?? $0.fileSize ?? 0) } ?? 0
        do {
            try fm.trashItem(at: url, resultingItemURL: nil)
            outcome.trashed.append(url)
            outcome.freedBytes += size
        } catch {
            outcome.failed.append(.init(url: url, reason: error.localizedDescription))
        }
    }

    private static func deleteContents(of directory: URL, dryRun: Bool, into outcome: inout Outcome) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in contents {
            if dryRun {
                outcome.trashed.append(item)
            } else {
                trashOne(item, into: &outcome)
            }
        }
    }

    // MARK: - Public API

    /// Delete (move to Trash) the contents/items of the given cleanup targets.
    /// All target paths are validated against the cleanup allowlist; anything outside it is
    /// reported under `blocked` rather than deleted.
    static func delete(targets: [CleanupTarget], dryRun: Bool) -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default

        for target in targets {
            for path in target.paths {
                guard fm.fileExists(atPath: path.path) else { continue }

                guard isWithinCleanupRoots(path) else {
                    outcome.blocked.append(path)
                    continue
                }

                if isContentsOnlyDirectory(path) {
                    deleteContents(of: path, dryRun: dryRun, into: &outcome)
                } else if dryRun {
                    outcome.trashed.append(path)
                } else {
                    trashOne(path, into: &outcome)
                }
            }
        }
        return outcome
    }

    /// Move user-selected files (e.g. from the category/media browsers) to the Trash.
    /// Uses only the critical-system-path guard so any ordinary user file is deletable,
    /// while `/`, system trees and the home directory itself are always refused.
    @discardableResult
    static func trashFiles(_ urls: [URL], dryRun: Bool = false) -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default
        for url in urls {
            guard fm.fileExists(atPath: url.path) else { continue }
            guard !isCriticalSystemPath(url) else {
                outcome.blocked.append(url)
                continue
            }
            if dryRun {
                outcome.trashed.append(url)
            } else {
                trashOne(url, into: &outcome)
            }
        }
        return outcome
    }
}
