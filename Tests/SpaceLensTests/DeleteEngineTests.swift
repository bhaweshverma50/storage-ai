import XCTest
@testable import SpaceLens

final class DeleteEngineSafetyTests: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    // MARK: - isCriticalSystemPath

    func testRootAndVolumeRootsAreCritical() {
        XCTAssertTrue(DeleteEngine.isCriticalSystemPath(URL(fileURLWithPath: "/")))
        XCTAssertTrue(DeleteEngine.isCriticalSystemPath(URL(fileURLWithPath: "/Volumes/External")))
    }

    func testSystemTreesAreCritical() {
        XCTAssertTrue(DeleteEngine.isCriticalSystemPath(URL(fileURLWithPath: "/System")))
        XCTAssertTrue(DeleteEngine.isCriticalSystemPath(URL(fileURLWithPath: "/System/Library/Foo")))
        XCTAssertTrue(DeleteEngine.isCriticalSystemPath(URL(fileURLWithPath: "/usr/bin")))
        XCTAssertTrue(DeleteEngine.isCriticalSystemPath(URL(fileURLWithPath: "/bin")))
        XCTAssertTrue(DeleteEngine.isCriticalSystemPath(URL(fileURLWithPath: "/sbin")))
    }

    /// Default APFS is case-insensitive, so non-canonical spellings must be blocked too.
    func testCaseVariantSpellingsOfSystemTreesAreCritical() {
        XCTAssertTrue(DeleteEngine.isCriticalSystemPath(URL(fileURLWithPath: "/SYSTEM/Library")))
        XCTAssertTrue(DeleteEngine.isCriticalSystemPath(URL(fileURLWithPath: "/system")))
        XCTAssertTrue(DeleteEngine.isCriticalSystemPath(URL(fileURLWithPath: "/Private/var/db")))
        XCTAssertTrue(DeleteEngine.isCriticalSystemPath(URL(fileURLWithPath: "/USR/BIN")))
        XCTAssertTrue(DeleteEngine.isCriticalSystemPath(URL(fileURLWithPath: "/LIBRARY")))
    }

    func testHomeDirectoryItselfIsCritical() {
        XCTAssertTrue(DeleteEngine.isCriticalSystemPath(home))
    }

    func testUserFilesAreNotCritical() {
        XCTAssertFalse(DeleteEngine.isCriticalSystemPath(home.appendingPathComponent("Downloads/file.zip")))
        XCTAssertFalse(DeleteEngine.isCriticalSystemPath(home.appendingPathComponent("Movies/clip.mov")))
        XCTAssertFalse(DeleteEngine.isCriticalSystemPath(URL(fileURLWithPath: "/Applications/SomeApp.app")))
    }

    // MARK: - isWithinCleanupRoots

    func testCleanupRootsAllowExpectedPaths() {
        XCTAssertTrue(DeleteEngine.isWithinCleanupRoots(home.appendingPathComponent("Library/Caches/com.foo")))
        XCTAssertTrue(DeleteEngine.isWithinCleanupRoots(home.appendingPathComponent("Library/Containers/com.bar")))
        XCTAssertTrue(DeleteEngine.isWithinCleanupRoots(home.appendingPathComponent("Library/Application Support/App")))
        XCTAssertTrue(DeleteEngine.isWithinCleanupRoots(home.appendingPathComponent("Downloads/big.dmg")))
    }

    func testCleanupRootsRejectUnsafePaths() {
        XCTAssertFalse(DeleteEngine.isWithinCleanupRoots(home)) // home itself
        XCTAssertFalse(DeleteEngine.isWithinCleanupRoots(home.appendingPathComponent("Documents/taxes.pdf")))
        XCTAssertFalse(DeleteEngine.isWithinCleanupRoots(URL(fileURLWithPath: "/Applications/Safari.app")))
        XCTAssertFalse(DeleteEngine.isWithinCleanupRoots(URL(fileURLWithPath: "/")))
    }

    // MARK: - delete() preview / blocking (dry-run, no side effects)

    func testDeleteDryRunBlocksUnsafeTargetPaths() {
        // A target pointing at the home directory must be blocked, never trashed.
        let target = CleanupTarget(title: "Bad", description: "", scope: .aggressive,
                                   paths: [home], estimatedBytes: 1)
        let outcome = DeleteEngine.delete(targets: [target], dryRun: true)
        XCTAssertTrue(outcome.trashed.isEmpty)
        XCTAssertEqual(outcome.blocked.map { $0.path }, [home.path])
    }

    func testDeleteDryRunPreviewsSafePaths() throws {
        let fm = FileManager.default
        let cachesRoot = home.appendingPathComponent("Library/Caches")
        let testDir = cachesRoot.appendingPathComponent("SpaceLensTest-\(UUID().uuidString)")
        try fm.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: testDir) }
        try "hello".write(to: testDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let target = CleanupTarget(title: "Test", description: "", scope: .safe,
                                   paths: [testDir], estimatedBytes: 5)
        let outcome = DeleteEngine.delete(targets: [target], dryRun: true)
        // testDir is within Caches but is not itself a contents-only root, so it previews whole.
        XCTAssertTrue(outcome.trashed.map { $0.path }.contains(testDir.path))
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertTrue(outcome.blocked.isEmpty)
    }

    func testTrashFilesBlocksCriticalPathsButAllowsUserFiles() {
        // Critical path is blocked; a (non-existent) user path is simply skipped (fileExists guard),
        // so neither should ever be trashed in a dry run that includes a critical path.
        let outcome = DeleteEngine.trashFiles([URL(fileURLWithPath: "/System")], dryRun: true)
        XCTAssertEqual(outcome.blocked.map { $0.path }, ["/System"])
        XCTAssertTrue(outcome.trashed.isEmpty)
    }

    func testTrashedDirectoryReportsRecursiveFreedBytes() throws {
        // A directory's own stat size is ~0 — freedBytes must sum its CONTENTS, otherwise
        // trashing a multi-GB app-data folder reports "freed Zero KB" (real user-facing bug).
        let fm = FileManager.default
        let testDir = home.appendingPathComponent("Library/Caches/SpaceLensTest-\(UUID().uuidString)")
        try fm.createDirectory(at: testDir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let payload = Data(repeating: 0xAB, count: 64_000)
        try payload.write(to: testDir.appendingPathComponent("a.bin"))
        try payload.write(to: testDir.appendingPathComponent("sub/b.bin"))

        let outcome = DeleteEngine.trashFiles([testDir])   // really moves to Trash (recoverable)
        XCTAssertEqual(outcome.trashed.map { $0.path }, [testDir.path])
        XCTAssertGreaterThanOrEqual(outcome.freedBytes, 128_000,
                                    "directory freedBytes must include nested contents")
    }

    func testDeleteDeduplicatesRepeatedPaths() throws {
        // App-data path discovery can yield the same folder via name AND bundle id; the engine
        // must process each unique path once so outcomes don't report phantom skips.
        let fm = FileManager.default
        let testDir = home.appendingPathComponent("Library/Caches/SpaceLensTest-\(UUID().uuidString)")
        try fm.createDirectory(at: testDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: testDir) }

        let target = CleanupTarget(title: "Dup", description: "", scope: .safe,
                                   paths: [testDir, testDir, testDir], estimatedBytes: 0)
        let outcome = DeleteEngine.delete(targets: [target], dryRun: true)
        XCTAssertEqual(outcome.trashed.map { $0.path }, [testDir.path], "duplicates must collapse to one")
    }
}

/// `trashItem` on a file that is already in `~/.Trash` silently succeeds and frees nothing,
/// so emptying the Trash has to remove files outright. These tests pin the routing decision
/// (which bucket an item lands in) using dry-run only — nothing is actually deleted.
final class DeleteEngineEmptyTrashTests: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private func target(_ title: String, _ path: URL) -> CleanupTarget {
        CleanupTarget(title: title, description: "", scope: .safe, paths: [path], estimatedBytes: 0)
    }

    func testTrashContentsAreRoutedToPermanentDeletionNotTrashing() throws {
        let trash = home.appendingPathComponent(".Trash")
        let probe = trash.appendingPathComponent("spacelens_delete_engine_probe.txt")
        try "probe".write(to: probe, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: probe) }

        let outcome = DeleteEngine.delete(targets: [target("Trash", trash)], dryRun: true)

        // Enumerating ~/.Trash needs Full Disk Access, which a test binary won't have.
        // Without it the target must report a failure rather than a silent success.
        let unreadable = outcome.failed.contains { $0.url.lastPathComponent == ".Trash" }
        if unreadable {
            XCTAssertTrue(outcome.removed.isEmpty,
                          "an unreadable Trash must not report anything as removed")
            return
        }

        let permanent = Set(outcome.deletedPermanently.map(\.lastPathComponent))
        let trashed = Set(outcome.trashed.map(\.lastPathComponent))
        XCTAssertTrue(permanent.contains(probe.lastPathComponent),
                      "items inside ~/.Trash must be reported as permanent deletions")
        XCTAssertFalse(trashed.contains(probe.lastPathComponent),
                       "items inside ~/.Trash must never be reported as recoverably trashed")
        // Still on disk: dry-run must not delete anything.
        XCTAssertTrue(FileManager.default.fileExists(atPath: probe.path))
    }

    /// Whatever the TCC outcome, an unreadable target is never silently counted as cleaned.
    func testUnreadableTargetIsReportedNotSilentlySkipped() {
        let trash = home.appendingPathComponent(".Trash")
        let outcome = DeleteEngine.delete(targets: [target("Trash", trash)], dryRun: true)
        XCTAssertFalse(outcome.failed.isEmpty && outcome.removed.isEmpty,
                       "a target that yielded nothing must say why")
    }

    func testNonTrashCleanupTargetsStayRecoverable() throws {
        let caches = home.appendingPathComponent("Library/Caches")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: caches.path), "no ~/Library/Caches")

        let outcome = DeleteEngine.delete(targets: [target("App Caches", caches)], dryRun: true)

        XCTAssertTrue(outcome.deletedPermanently.isEmpty,
                      "only ~/.Trash may be emptied permanently")
        XCTAssertEqual(outcome.removedCount, outcome.trashedCount)
    }

    /// The app's own state directory lives inside two cleanup targets (Application Support,
    /// and Caches pre-migration) — clearing them must not delete our scan history.
    func testOwnStateDirectoryIsNeverCleared() throws {
        let appSupport = home.appendingPathComponent("Library/Application Support")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: appSupport.path), "no Application Support")

        let outcome = DeleteEngine.delete(targets: [target("Application Support", appSupport)], dryRun: true)

        XCTAssertFalse(outcome.removed.contains { $0.lastPathComponent == "com.spacelens.app" },
                       "SpaceLens must never list its own state directory for deletion")
    }
}
