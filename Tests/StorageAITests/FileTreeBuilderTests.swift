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
        // totalFileAllocatedSize rounds each file up to the APFS block size (4 KB),
        // so the aggregate runs higher than the logical byte counts; widen tolerance.
        XCTAssertEqual(Double(node!.sizeBytes), 800_020, accuracy: 20_000)  // 500000+300000+20
        let sub = node!.children?.first { $0.name == "sub" }
        XCTAssertEqual(Double(sub?.sizeBytes ?? 0), 300_000, accuracy: 8_000)
    }

    func testTailCollapsesSmallFilesIntoAggregate() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let node = await FileTreeBuilder.build(root: root, token: CancellationToken(), progress: { _ in })
        let names = Set(node!.children?.map(\.name) ?? [])
        XCTAssertFalse(names.contains("tiny1.txt"))
        XCTAssertTrue(node!.children?.contains { $0.name.contains("small item") } ?? false)
        XCTAssertTrue(names.contains("big.bin"))
    }

    func testCancellationReturnsNil() async throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = CancellationToken(); token.cancel()
        let node = await FileTreeBuilder.build(root: root, token: token, progress: { _ in })
        XCTAssertNil(node)
    }

    func testBuildAllWrapsMultipleRootsAndAggregates() async throws {
        let r1 = try makeTempTree()
        let r2 = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: r1); try? FileManager.default.removeItem(at: r2) }
        let node = await FileTreeBuilder.buildAll(roots: [r1, r2], token: CancellationToken(), progress: { _ in })
        XCTAssertNotNil(node)
        XCTAssertEqual(node?.children?.count, 2)                 // one child per root
        // Synthetic root aggregates both roots (~2 x ~800 KB), allowing for block rounding.
        XCTAssertEqual(Double(node!.sizeBytes), 1_600_040, accuracy: 40_000)
    }

    func testSymlinksAreSkipped() async throws {
        let fm = FileManager.default
        let root = try makeTempTree()
        defer { try? fm.removeItem(at: root) }
        // A symlink pointing back at a sibling must NOT be followed (cycle / double-count guard).
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.bin"),
                                  withDestinationURL: root.appendingPathComponent("big.bin"))
        let node = await FileTreeBuilder.build(root: root, token: CancellationToken(), progress: { _ in })
        let names = node!.children?.map(\.name) ?? []
        XCTAssertFalse(names.contains("link.bin"))               // symlink excluded
    }
}
