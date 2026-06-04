import XCTest
@testable import SpaceLens

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

    func testLegacySettingsWithoutModelFieldDecodeWithDefault() throws {
        // Settings persisted before ollamaModel existed must still decode.
        let legacy = #"{"includeSystem":true,"includeHidden":false,"excludedPaths":["/x"],"ollamaEnabled":false}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertTrue(decoded.includeSystem)
        XCTAssertEqual(decoded.excludedPaths, ["/x"])
        XCTAssertFalse(decoded.ollamaEnabled)
        XCTAssertEqual(decoded.ollamaModel, "llama3.2") // default applied
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
