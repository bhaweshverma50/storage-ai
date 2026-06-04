import XCTest
import CoreGraphics
@testable import SpaceLens

final class TreemapLayoutTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 600, height: 400)

    func testTilesCoverRectAreaWithoutOverlap() {
        let items = [("a", 6.0), ("b", 6.0), ("c", 4.0), ("d", 3.0), ("e", 2.0), ("f", 1.0)]
        let tiles = TreemapLayout.squarify(items.map { (id: $0.0, weight: $0.1) }, in: rect)
        XCTAssertEqual(tiles.count, items.count)
        let area = tiles.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        XCTAssertEqual(area, Double(rect.width * rect.height), accuracy: 1.0)
        for t in tiles {
            XCTAssertTrue(rect.insetBy(dx: -0.5, dy: -0.5).contains(t.rect))
        }
    }

    func testAreaIsProportionalToWeight() {
        let tiles = TreemapLayout.squarify([(id: "big", weight: 3.0), (id: "small", weight: 1.0)], in: rect)
        let big = tiles.first { $0.id == "big" }!.rect
        let small = tiles.first { $0.id == "small" }!.rect
        let ratio = Double(big.width * big.height) / Double(small.width * small.height)
        XCTAssertEqual(ratio, 3.0, accuracy: 0.05)
    }

    func testIgnoresZeroAndNegativeWeights() {
        let tiles = TreemapLayout.squarify([(id: "a", weight: 1.0), (id: "z", weight: 0.0)], in: rect)
        XCTAssertEqual(tiles.map(\.id), ["a"])
    }

    func testEmptyOrZeroRectReturnsNoTiles() {
        XCTAssertTrue(TreemapLayout.squarify([(id: "a", weight: 1.0)], in: .zero).isEmpty)
        XCTAssertTrue(TreemapLayout.squarify([(id: "a", weight: 1.0)].filter { _ in false }, in: rect).isEmpty)
    }
}
