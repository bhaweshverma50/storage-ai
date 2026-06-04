import XCTest
@testable import StorageAI

/// The drill-down views read `filesByCategory`, which is fed from scan progress updates.
/// These tests pin the contract that updates carry the LIVE top-files snapshot — without it,
/// cancelled/interrupted scans (and the partial cache they persist) have no files to show.
final class ScanAggregatorTests: XCTestCase {

    private final class UpdateBox: @unchecked Sendable {
        var updates: [ScanUpdate] = []
    }

    func testProgressUpdateCarriesTopFilesSortedLargestFirst() async {
        let box = UpdateBox()
        let aggregator = FileIndexer.ScanAggregator(
            initialBuckets: [:],
            initialFiles: nil,
            initialScannedFiles: 0,
            initialScannedBytes: 0,
            progress: { box.updates.append($0) }
        )

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

    func testInitialFilesSeedTheTopFilesSnapshot() async {
        // Resuming a partial scan re-seeds the heaps; the very first update must already
        // include those files so the UI never regresses to an empty drill-down.
        let box = UpdateBox()
        let seeded = FileEntry(url: URL(fileURLWithPath: "/tmp/seeded.dat"), sizeBytes: 500, modifiedAt: nil)
        let aggregator = FileIndexer.ScanAggregator(
            initialBuckets: [:],
            initialFiles: [.media: [seeded]],
            initialScannedFiles: 1,
            initialScannedBytes: 500,
            progress: { box.updates.append($0) }
        )

        await aggregator.emitProgress(currentPath: "", phase: .preparing)

        XCTAssertEqual(box.updates.last?.topFiles[.media]?.map(\.sizeBytes), [500])
    }
}
