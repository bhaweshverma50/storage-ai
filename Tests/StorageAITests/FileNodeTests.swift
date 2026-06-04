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
