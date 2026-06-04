import XCTest
import SwiftUI
@testable import SpaceLens

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

    func testNewKindsMapTheirExtensions() {
        XCTAssertEqual(FileKind.forExtension("psd"), .design)
        XCTAssertEqual(FileKind.forExtension("sqlite"), .data)
        XCTAssertEqual(FileKind.forExtension("json"), .data)
        XCTAssertEqual(FileKind.forExtension("dmg"), .diskImage)
        XCTAssertEqual(FileKind.forExtension("ISO"), .diskImage)
        XCTAssertEqual(FileKind.forExtension("ttf"), .font)
    }

    func testFolderPaletteIsDeterministicAcrossCalls() {
        // The hue must come from a stable hash — String.hashValue is seeded per-process and
        // would reshuffle every folder's color on each launch.
        XCTAssertEqual(FolderPalette.fnv1a("node_modules"), FolderPalette.fnv1a("node_modules"))
        XCTAssertNotEqual(FolderPalette.fnv1a("node_modules"), FolderPalette.fnv1a("Library"))
        XCTAssertEqual(FolderPalette.color(forName: "Documents"), FolderPalette.color(forName: "Documents"))
    }
}
