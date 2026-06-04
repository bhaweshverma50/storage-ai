import XCTest
@testable import SpaceLens

final class OllamaModelMatchTests: XCTestCase {
    func testExactMatch() {
        XCTAssertTrue(OllamaClient.modelNameMatches(requested: "llama3.2", installed: "llama3.2"))
    }

    func testLatestTagMatches() {
        XCTAssertTrue(OllamaClient.modelNameMatches(requested: "llama3.2", installed: "llama3.2:latest"))
        XCTAssertTrue(OllamaClient.modelNameMatches(requested: "llama3.2:latest", installed: "llama3.2"))
    }

    func testSameBaseWithDifferentTagMatches() {
        XCTAssertTrue(OllamaClient.modelNameMatches(requested: "llama3", installed: "llama3:8b"))
    }

    func testDifferentVersionsDoNotMatch() {
        // The old loose prefix logic falsely matched these — guard against regression.
        XCTAssertFalse(OllamaClient.modelNameMatches(requested: "llama3.2", installed: "llama3"))
        XCTAssertFalse(OllamaClient.modelNameMatches(requested: "llama3.1", installed: "llama3.2"))
        XCTAssertFalse(OllamaClient.modelNameMatches(requested: "qwen2.5", installed: "llama3.2"))
    }

    func testEmptyInstalledNameNeverMatches() {
        XCTAssertFalse(OllamaClient.modelNameMatches(requested: "llama3.2", installed: ""))
    }
}
