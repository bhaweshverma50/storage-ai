import XCTest
@testable import SpaceLens

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

    func testIndexSizesAggregatesFolderTotals() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = await FileTreeBuilder.indexSizes(roots: [root], token: CancellationToken(), progress: { _ in })
        XCTAssertNotNil(index)
        // totalFileAllocatedSize rounds up to APFS block size, so widen tolerance.
        XCTAssertEqual(Double(index!.size(of: root)), 800_020, accuracy: 20_000)   // 500000+300000+20
        XCTAssertEqual(Double(index!.size(of: root.appendingPathComponent("sub"))), 300_000, accuracy: 8_000)
    }

    func testLevelChildrenTailCollapsesAndSizesSubfoldersFromIndex() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = await FileTreeBuilder.indexSizes(roots: [root], token: CancellationToken(), progress: { _ in })!
        let level = FileTreeBuilder.levelChildren(of: root, index: index)
        let names = Set(level.map(\.name))
        XCTAssertTrue(names.contains("big.bin"))                                  // significant file kept
        XCTAssertFalse(names.contains("tiny1.txt"))                              // tail folded
        XCTAssertTrue(level.contains { $0.name.contains("small item") })         // aggregate present
        // subfolder node is sized from the index, not re-walked
        let sub = level.first { $0.name == "sub" }
        XCTAssertNotNil(sub)
        XCTAssertEqual(sub!.sizeBytes, index.size(of: root.appendingPathComponent("sub")))
        // returned largest-first
        XCTAssertEqual(level.map(\.sizeBytes), level.map(\.sizeBytes).sorted(by: >))
    }

    func testCancellationReturnsNilIndex() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = CancellationToken(); token.cancel()
        let index = await FileTreeBuilder.indexSizes(roots: [root], token: token, progress: { _ in })
        XCTAssertNil(index)
    }

    func testSymlinksAreNotCounted() async throws {
        let fm = FileManager.default
        let root = try makeTempTree()
        defer { try? fm.removeItem(at: root) }
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.bin"),
                                  withDestinationURL: root.appendingPathComponent("big.bin"))
        let index = await FileTreeBuilder.indexSizes(roots: [root], token: CancellationToken(), progress: { _ in })!
        // big.bin counted once; symlink not added on top.
        XCTAssertEqual(Double(index.size(of: root)), 800_020, accuracy: 20_000)
        let names = Set(FileTreeBuilder.levelChildren(of: root, index: index).map(\.name))
        XCTAssertFalse(names.contains("link.bin"))
    }

    func testMultipleRootsIndexedIndependently() async throws {
        let r1 = try makeTempTree()
        let r2 = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: r1); try? FileManager.default.removeItem(at: r2) }
        let index = await FileTreeBuilder.indexSizes(roots: [r1, r2], token: CancellationToken(), progress: { _ in })!
        XCTAssertEqual(Double(index.size(of: r1)), 800_020, accuracy: 20_000)
        XCTAssertEqual(Double(index.size(of: r2)), 800_020, accuracy: 20_000)
    }
}
