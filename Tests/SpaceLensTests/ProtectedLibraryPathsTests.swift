import XCTest
@testable import SpaceLens

/// Touching Photos/Music-library content (even AVAsset metadata loads) raises blocking macOS
/// TCC prompts. These tests pin the shared guard that scanners and analyzers use to avoid that.
final class ProtectedLibraryPathsTests: XCTestCase {

    func testProtectedBundleDetection() {
        XCTAssertTrue(ProtectedLibraryPaths.isProtectedBundle(
            URL(fileURLWithPath: "/Users/me/Pictures/Photos Library.photoslibrary")))
        XCTAssertTrue(ProtectedLibraryPaths.isProtectedBundle(
            URL(fileURLWithPath: "/Users/me/Music/Music/Music Library.musiclibrary")))
        XCTAssertFalse(ProtectedLibraryPaths.isProtectedBundle(
            URL(fileURLWithPath: "/Users/me/Documents")))
        XCTAssertFalse(ProtectedLibraryPaths.isProtectedBundle(
            URL(fileURLWithPath: "/Users/me/Movies/holiday.mov")))
    }

    func testFilesInsideProtectedBundlesAreDetected() {
        XCTAssertTrue(ProtectedLibraryPaths.isInsideProtectedLibrary(
            URL(fileURLWithPath: "/Users/me/Pictures/Photos Library.photoslibrary/originals/1/IMG_0001.HEIC")))
    }

    func testFilesInManagedMusicFoldersAreDetected() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(ProtectedLibraryPaths.isInsideProtectedLibrary(
            URL(fileURLWithPath: "\(home)/Music/Music/Media.localized/Artist/song.m4a")))
        XCTAssertTrue(ProtectedLibraryPaths.isInsideProtectedLibrary(
            URL(fileURLWithPath: "\(home)/Music/iTunes/iTunes Media/Movies/film.m4v")))
    }

    func testOrdinaryMediaFilesAreNotFlagged() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertFalse(ProtectedLibraryPaths.isInsideProtectedLibrary(
            URL(fileURLWithPath: "\(home)/Movies/screencast.mp4")))
        XCTAssertFalse(ProtectedLibraryPaths.isInsideProtectedLibrary(
            URL(fileURLWithPath: "\(home)/Downloads/track.mp3")))
        // Loose files directly under ~/Music but OUTSIDE the app-managed folders are fine.
        XCTAssertFalse(ProtectedLibraryPaths.isInsideProtectedLibrary(
            URL(fileURLWithPath: "\(home)/Music/GarageBand/demo.band")))
    }
}
