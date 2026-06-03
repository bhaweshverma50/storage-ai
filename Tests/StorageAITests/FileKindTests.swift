import XCTest
import SwiftUI
@testable import StorageAI

final class FileKindTests: XCTestCase {
    func testCommonExtensionsMapToExpectedKinds() {
        XCTAssertEqual(FileKind.forExtension("jpg"), .image)
        XCTAssertEqual(FileKind.forExtension("PNG"), .image)      // case-insensitive
        XCTAssertEqual(FileKind.forExtension("mp4"), .video)
        XCTAssertEqual(FileKind.forExtension("mp3"), .audio)
        XCTAssertEqual(FileKind.forExtension("swift"), .code)
        XCTAssertEqual(FileKind.forExtension("zip"), .archive)
        XCTAssertEqual(FileKind.forExtension("pdf"), .document)
        XCTAssertEqual(FileKind.forExtension("app"), .application)
        XCTAssertEqual(FileKind.forExtension("xyzunknown"), .other)
        XCTAssertEqual(FileKind.forExtension(""), .other)
    }

    func testEveryKindHasADistinctColorAndLabel() {
        let kinds = FileKind.allCases
        XCTAssertEqual(Set(kinds.map(\.label)).count, kinds.count)
    }
}
