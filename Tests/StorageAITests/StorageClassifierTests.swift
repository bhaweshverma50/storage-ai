import XCTest
@testable import StorageAI

final class StorageClassifierTests: XCTestCase {
    private let classifier = StorageClassifier()
    private let home = FileManager.default.homeDirectoryForCurrentUser.path.lowercased()

    func testSystemPathWithMediaExtensionIsSystemNotMedia() {
        // A .png/.pdf under a system tree must classify as system, not media.
        XCTAssertEqual(classifier.classify(path: "/system/library/x.png", pathExtension: "png"), .system)
        XCTAssertEqual(classifier.classify(path: "/usr/share/doc/x.pdf", pathExtension: "pdf"), .system)
        XCTAssertEqual(classifier.classify(path: "/library/audio/x.mp3", pathExtension: "mp3"), .system)
    }

    func testUserMediaStillClassifiesAsMedia() {
        XCTAssertEqual(classifier.classify(path: home + "/pictures/photo.png", pathExtension: "png"), .media)
        XCTAssertEqual(classifier.classify(path: home + "/movies/clip.mp4", pathExtension: "mp4"), .media)
        XCTAssertEqual(classifier.classify(path: home + "/downloads/song.mp3", pathExtension: "mp3"), .documents) // Downloads wins (checked first)
    }

    func testApplicationsAndSystemBasics() {
        XCTAssertEqual(classifier.classify(path: "/applications/safari.app", pathExtension: "app"), .applications)
        XCTAssertEqual(classifier.classify(path: "/usr/bin/swift", pathExtension: ""), .system)
    }
}
