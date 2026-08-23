import Foundation

enum DeleteEngine {
    /// Rich result of a delete/preview operation.
    /// Items are moved to the Trash (recoverable) or, if that fails, left in place and
    /// reported under `failed`. The sole exception is emptying `~/.Trash` itself, which is
    /// unrecoverable and reported separately under `deletedPermanently` — `trashItem` on a
    /// file that is already in the Trash silently succeeds and frees nothing, so a real
    /// "Empty Trash" has to remove those files outright.
    struct Outcome {
        struct FailedItem {
            let url: URL
            let reason: String
        }

        /// Items moved to Trash (or, in dry-run, the items that *would* be trashed).
        var trashed: [URL] = []
        /// Items removed permanently — only ever direct children of `~/.Trash`.
        /// (In dry-run, the items that *would* be permanently removed.)
        var deletedPermanently: [URL] = []
        /// Items that could not be trashed; left untouched on disk.
        var failed: [FailedItem] = []
        /// Items rejected by the safety guard (outside allowed roots / critical system paths).
        var blocked: [URL] = []
        /// Best-effort sum of removed file sizes (0 when not computed).
        var freedBytes: Int64 = 0

        /// Everything that actually left its original location, however it was removed.
        /// Use this for space accounting; use the two arrays above for user-facing wording.
        var removed: [URL] { trashed + deletedPermanently }

        var trashedCount: Int { trashed.count }
        var permanentCount: Int { deletedPermanently.count }
        var removedCount: Int { trashed.count + deletedPermanently.count }
        var failedCount: Int { failed.count }
        var blockedCount: Int { blocked.count }
        var didTrashNothing: Bool { trashed.isEmpty && deletedPermanently.isEmpty }
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
        // Compare case-insensitively: the default APFS volume is case-insensitive, so
        // "/SYSTEM/Library" or "/Private/var" resolve to the same protected files as
        // their canonical spellings and must be blocked too.
        let path = resolved.path.lowercased()

        if path.isEmpty || path == "/" { return true }

        // "/" -> ["/"]; "/Volumes" -> ["/", "Volumes"]; "/Volumes/Ext" -> ["/", "Volumes", "Ext"]
        let comps = resolved.pathComponents
        if comps.count <= 1 { return true }
        if comps.count <= 3, comps.first == "/", comps.dropFirst().first?.lowercased() == "volumes" { return true }

        // The home directory itself (but not its descendants).
        let home = normalized(FileManager.default.homeDirectoryForCurrentUser)
        if path == home.lowercased() { return true }

        // Core OS trees that should never be touched by this app. "/var" and "/tmp" are
        // listed explicitly because resolvingSymlinksInPath maps "/private/var/..." to
        // "/var/..." (and "/private/tmp/..." to "/tmp/..."), which would otherwise slip
        // past the "/private/var" prefix.
        let criticalRoots = ["/system", "/usr", "/bin", "/sbin", "/private/var", "/private/etc", "/var", "/tmp", "/cores", "/library"]
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
        // Case-insensitive on purpose: on the default (case-insensitive) APFS volume,
        // "~/library/Caches" is the same directory as "~/Library/Caches". Missing the match
        // would trash the whole folder instead of just its contents, so erring toward
        // contents-only is the safe direction. (`isWithinCleanupRoots` stays case-SENSITIVE —
        // loosening an allowlist errs the other way.)
        let target = normalized(url).lowercased()
        return contentsOnlyRelativePaths.contains { rel in
            target == normalized(home.appendingPathComponent(rel)).lowercased()
        }
    }

    /// Our own persisted state lives in `~/Library/Application Support/com.spacelens.app`
    /// (and, pre-migration, the same name under `~/Library/Caches`) — both of which are
    /// inside cleanup targets. Never clear it as part of a cleanup, or the app deletes its
    /// own scan history out from under itself mid-session.
    private static let ownStateDirectoryName = "com.spacelens.app"

    // MARK: - Trashing (never permanent)

    /// A directory's own stat size is ~0 — sum its contents so freedBytes is honest
    /// (otherwise trashing a multi-GB app-data folder reports "freed Zero KB").
    private static func sizeOnDisk(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey])
        return values?.isDirectory == true
            ? FileIndexer.sizeOfPath(url)
            : values.flatMap { Int64($0.totalFileAllocatedSize ?? $0.fileSize ?? 0) } ?? 0
    }

    /// `~/.Trash` — the one location where "move to Trash" is a no-op, so emptying it
    /// requires outright removal (this is what Finder's Empty Trash does).
    private static func isUserTrashDirectory(_ url: URL) -> Bool {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        return normalized(url).lowercased() == normalized(trash).lowercased()
    }

    /// Move a single item to the Trash. On failure we DO NOT fall back to a permanent
    /// delete — the item is left in place and the failure recorded.
    private static func trashOne(_ url: URL, into outcome: inout Outcome) {
        let size = sizeOnDisk(of: url)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            outcome.trashed.append(url)
            outcome.freedBytes += size
        } catch {
            outcome.failed.append(.init(url: url, reason: error.localizedDescription))
        }
    }

    /// PERMANENT, unrecoverable removal — the only such path in this app. Restricted to
    /// direct children of `~/.Trash`, because `trashItem` cannot empty the Trash (it
    /// silently succeeds and frees nothing for a file already in there).
    ///
    /// The parent check is re-verified here rather than trusted from the caller: this is the
    /// one operation that cannot be undone, so it re-asserts its own precondition and
    /// reports anything else as `blocked` instead of deleting it.
    private static func removePermanently(_ url: URL, into outcome: inout Outcome) {
        guard isUserTrashDirectory(url.deletingLastPathComponent()),
              !isCriticalSystemPath(url) else {
            outcome.blocked.append(url)
            return
        }
        let size = sizeOnDisk(of: url)
        do {
            try FileManager.default.removeItem(at: url)
            outcome.deletedPermanently.append(url)
            outcome.freedBytes += size
        } catch {
            outcome.failed.append(.init(url: url, reason: error.localizedDescription))
        }
    }

    private static func deleteContents(of directory: URL, dryRun: Bool, into outcome: inout Outcome) {
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            // A TCC-protected or unreadable folder must not look like a successful no-op:
            // surface it so the UI reports what was skipped instead of claiming success.
            outcome.failed.append(.init(url: directory, reason: "Couldn't read folder contents: \(error.localizedDescription)"))
            return
        }
        // Emptying the Trash can't be done by trashing — those items need real removal.
        let isEmptyingTrash = isUserTrashDirectory(directory)

        for item in contents {
            if item.lastPathComponent.caseInsensitiveCompare(ownStateDirectoryName) == .orderedSame {
                continue
            }
            switch (dryRun, isEmptyingTrash) {
            case (true, true): outcome.deletedPermanently.append(item)
            case (true, false): outcome.trashed.append(item)
            case (false, true): removePermanently(item, into: &outcome)
            case (false, false): trashOne(item, into: &outcome)
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
        // App-data path discovery can yield the same folder via app name AND bundle id —
        // process each unique path once so outcomes don't report phantom skips.
        var seen = Set<String>()

        for target in targets {
            for path in target.paths {
                guard seen.insert(normalized(path)).inserted else { continue }
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
        var seen = Set<String>()
        for url in urls {
            guard seen.insert(normalized(url)).inserted else { continue }
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
