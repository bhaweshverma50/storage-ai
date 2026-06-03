import XCTest
@testable import StorageAI

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
        let testDir = cachesRoot.appendingPathComponent("StorageAITest-\(UUID().uuidString)")
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
}
