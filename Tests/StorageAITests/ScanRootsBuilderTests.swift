import XCTest
@testable import StorageAI

final class ScanRootsBuilderTests: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    func testAlwaysIncludesHomeAndOnlyExistingPaths() {
        var settings = AppSettings()
        settings.includeSystem = false
        let roots = ScanRootsBuilder.roots(settings: settings)
        XCTAssertTrue(roots.contains(home), "home directory should always be a scan root")
        for url in roots {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(url.path) should exist")
        }
    }

    func testExcludesSystemRootsWhenNotRequested() {
        var settings = AppSettings()
        settings.includeSystem = false
        let roots = ScanRootsBuilder.roots(settings: settings).map { $0.path }
        XCTAssertFalse(roots.contains("/System"))
    }

    func testIncludesSystemRootsWhenRequested() {
        var settings = AppSettings()
        settings.includeSystem = true
        let roots = ScanRootsBuilder.roots(settings: settings).map { $0.path }
        // /System always exists on macOS
        XCTAssertTrue(roots.contains("/System"))
    }
}
