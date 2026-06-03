import XCTest
@testable import StorageAI

final class SettingsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "SettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testLoadReturnsDefaultsWhenNothingPersisted() {
        let defaults = makeDefaults()
        let loaded = SettingsStore.load(from: defaults)
        XCTAssertEqual(loaded, AppSettings())
    }

    func testSaveThenLoadRoundTripsAllFields() {
        let defaults = makeDefaults()
        var settings = AppSettings()
        settings.includeSystem = true
        settings.includeHidden = true
        settings.excludedPaths = ["/tmp/a", "/tmp/b"]
        settings.ollamaEnabled = false

        SettingsStore.save(settings, to: defaults)
        let loaded = SettingsStore.load(from: defaults)

        XCTAssertEqual(loaded, settings)
        XCTAssertTrue(loaded.includeSystem)
        XCTAssertEqual(loaded.excludedPaths, ["/tmp/a", "/tmp/b"])
        XCTAssertFalse(loaded.ollamaEnabled)
    }
}
