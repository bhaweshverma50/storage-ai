import XCTest
@testable import SpaceLens

/// The drill-down views read `filesByCategory`, which is fed from scan progress updates.
/// These tests pin the contract that updates carry the LIVE top-files snapshot — without it,
/// cancelled/interrupted scans (and the partial cache they persist) have no files to show.
final class ScanAggregatorTests: XCTestCase {

    private final class UpdateBox: @unchecked Sendable {
        var updates: [ScanUpdate] = []
    }

    func testProgressUpdateCarriesTopFilesSortedLargestFirst() async {
        let box = UpdateBox()
        let aggregator = FileIndexer.ScanAggregator(progress: { box.updates.append($0) })

        let small = FileEntry(url: URL(fileURLWithPath: "/tmp/small.txt"), sizeBytes: 10, modifiedAt: nil)
        let big = FileEntry(url: URL(fileURLWithPath: "/tmp/big.bin"), sizeBytes: 999, modifiedAt: nil)
        await aggregator.add(result: FileIndexer.BatchResult(
            scannedFiles: 2,
            scannedBytes: 1_009,
            buckets: [.documents: 1_009],
            fileCounts: [.documents: 2],
            files: [.documents: [small, big]],
            lastPath: "/tmp/big.bin"
        ), phase: .scanningHome)
        await aggregator.emitProgress(currentPath: "/tmp", phase: .scanningHome)

        guard let update = box.updates.last else {
            return XCTFail("no progress update emitted")
        }
        XCTAssertEqual(update.topFiles[.documents]?.map(\.sizeBytes), [999, 10],
                       "progress updates must carry the live top-files snapshot, largest first")
        XCTAssertEqual(update.fileCounts[.documents], 2)
    }

}

/// Out-of-order progress ticks must not regress the UI: accept() only passes ticks newer
/// than the last applied one, regardless of arrival order.
final class ProgressTickSequencerTests: XCTestCase {
    func testAcceptsInIssueOrder() {
        let seq = ProgressTickSequencer()
        let a = seq.next()
        let b = seq.next()
        XCTAssertTrue(seq.accept(a))
        XCTAssertTrue(seq.accept(b))
    }

    func testRejectsStaleTicks() {
        let seq = ProgressTickSequencer()
        let a = seq.next()
        let b = seq.next()
        // Newer tick applied first (simulated race), then the older one arrives late.
        XCTAssertTrue(seq.accept(b))
        XCTAssertFalse(seq.accept(a))
    }
}
