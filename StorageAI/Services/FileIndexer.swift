import Foundation

enum FileIndexerError: Error {
    case accessDenied(String)
    case cancelled
}

// Result that includes running totals for real-time updates
struct ScanUpdate {
    var scannedFiles: Int
    var scannedBytes: Int64
    var currentPath: String
    var phase: ScanPhase
    var buckets: [StorageCategory: Int64]
    var fileCounts: [StorageCategory: Int]  // File counts per category
}

/// Cancellation token for cooperative cancellation
final class CancellationToken: @unchecked Sendable {
    private var _isCancelled = false
    private let lock = NSLock()
    
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }
    
    func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }
}

/// A simple Min-Heap Priority Queue for tracking top N largest files
/// We keep the *smallest* of the large files at the root so we can easily replace it
struct FileHeap {
    private var heap: [FileEntry]
    private let maxSize: Int
    
    init(maxSize: Int) {
        self.heap = []
        self.maxSize = maxSize
    }
    
    var files: [FileEntry] {
        return heap
    }
    
    mutating func insert(_ file: FileEntry) {
        if heap.count < maxSize {
            heap.append(file)
            siftUp(heap.count - 1)
        } else if file.sizeBytes > heap[0].sizeBytes {
            heap[0] = file
            siftDown(0)
        }
    }
    
    private mutating func siftUp(_ index: Int) {
        var child = index
        var parent = (child - 1) / 2
        
        while child > 0 && heap[child].sizeBytes < heap[parent].sizeBytes {
            heap.swapAt(child, parent)
            child = parent
            parent = (child - 1) / 2
        }
    }
    
    private mutating func siftDown(_ index: Int) {
        var parent = index
        
        while true {
            let leftChild = 2 * parent + 1
            let rightChild = 2 * parent + 2
            var candidate = parent
            
            if leftChild < heap.count && heap[leftChild].sizeBytes < heap[candidate].sizeBytes {
                candidate = leftChild
            }
            
            if rightChild < heap.count && heap[rightChild].sizeBytes < heap[candidate].sizeBytes {
                candidate = rightChild
            }
            
            if candidate == parent {
                return
            }
            
            heap.swapAt(parent, candidate)
            parent = candidate
        }
    }
}

enum FileIndexer {
    struct BatchResult {
        var scannedFiles: Int
        var scannedBytes: Int64
        var buckets: [StorageCategory: Int64]
        var fileCounts: [StorageCategory: Int]
        var files: [StorageCategory: [FileEntry]]
        // Return latest path for UI updates 
        var lastPath: String?
    }
    
    actor ScanAggregator {
        var buckets: [StorageCategory: Int64]
        var fileHeaps: [StorageCategory: FileHeap]
        var categoryFileCounts: [StorageCategory: Int]
        var scannedFiles: Int
        var scannedBytes: Int64
        var lastProgressUpdate: Date
        
        let progressCallback: (ScanUpdate) -> Void
        
        init(
            initialBuckets: [StorageCategory: Int64],
            initialFiles: [StorageCategory: [FileEntry]]?,
            initialScannedFiles: Int,
            initialScannedBytes: Int64,
            progress: @escaping (ScanUpdate) -> Void
        ) {
            self.buckets = initialBuckets
            self.scannedFiles = initialScannedFiles
            self.scannedBytes = initialScannedBytes
            self.progressCallback = progress
            self.lastProgressUpdate = Date()
            
            // Initialize heaps
            var heaps: [StorageCategory: FileHeap] = [:]
            for category in StorageCategory.allCases {
                heaps[category] = FileHeap(maxSize: 1000)
            }
            if let initialFiles = initialFiles {
                for (category, files) in initialFiles {
                    for file in files {
                        heaps[category]?.insert(file)
                    }
                }
            }
            self.fileHeaps = heaps
            
            self.categoryFileCounts = initialFiles?.mapValues { $0.count } ?? StorageCategory.allCases.reduce(into: [StorageCategory: Int]()) { $0[$1] = 0 }
        }
        
        func add(result: BatchResult, phase: ScanPhase) {
            scannedFiles += result.scannedFiles
            scannedBytes += result.scannedBytes
            
            for (category, bytes) in result.buckets {
                buckets[category, default: 0] += bytes
            }
            
            for (category, count) in result.fileCounts {
                categoryFileCounts[category, default: 0] += count
            }
            
            for (category, files) in result.files {
                for file in files {
                    fileHeaps[category]?.insert(file)
                }
            }
            
            // Check throttle (optimization: move date check outside actor if possible, but safe here)
            let now = Date()
            if now.timeIntervalSince(lastProgressUpdate) >= 1.0 { // Throttled update inside aggregator
                lastProgressUpdate = now
                emitProgress(currentPath: result.lastPath ?? "", phase: phase)
            }
        }
        
        func emitProgress(currentPath: String, phase: ScanPhase) {
            progressCallback(ScanUpdate(
                scannedFiles: scannedFiles,
                scannedBytes: scannedBytes,
                currentPath: currentPath,
                phase: phase,
                buckets: buckets,
                fileCounts: categoryFileCounts
            ))
        }
        
        func getFinalResult() -> ScanResult {
            // Convert heaps back to sorted arrays
            var finalFiles: [StorageCategory: [FileEntry]] = [:]
            for (category, heap) in fileHeaps {
                finalFiles[category] = heap.files.sorted { $0.sizeBytes > $1.sizeBytes }
            }
            
            let bucketList = StorageCategory.allCases.map { StorageBucket(category: $0, bytes: buckets[$0, default: 0]) }
            return ScanResult(buckets: bucketList, filesByCategory: finalFiles, fileCounts: categoryFileCounts)
        }
    }

    static func scan(
        roots: [URL],
        includeHidden: Bool,
        excludedPaths: [String],
        cancellationToken: CancellationToken,
        progress: @escaping (ScanUpdate) -> Void,
        initialBuckets: [StorageCategory: Int64]? = nil,
        initialFiles: [StorageCategory: [FileEntry]]? = nil,
        initialScannedFiles: Int = 0,
        initialScannedBytes: Int64 = 0
    ) async throws -> ScanResult {
        // Start with initial values
        let baseBuckets = initialBuckets ?? StorageCategory.allCases.reduce(into: [StorageCategory: Int64]()) { $0[$1] = 0 }
        
        let aggregator = ScanAggregator(
            initialBuckets: baseBuckets,
            initialFiles: initialFiles,
            initialScannedFiles: initialScannedFiles,
            initialScannedBytes: initialScannedBytes,
            progress: progress
        )
        
        // Initial progress
        await aggregator.emitProgress(currentPath: "Starting scan...", phase: .preparing)
        
        let excluded = Set(excludedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path.lowercased() })
        let classifier = StorageClassifier() // Struct is lightweight
        
        try await withThrowingTaskGroup(of: Void.self) { group in
            for root in roots {
                if cancellationToken.isCancelled { throw FileIndexerError.cancelled }
                
                let phase = determinePhase(for: root)
                await aggregator.emitProgress(currentPath: "Scanning: \(root.lastPathComponent)", phase: phase)
                
                let shouldIncludeHidden = includeHidden || root.path.contains("/Library")
                var enumOptions: FileManager.DirectoryEnumerationOptions = []
                if !shouldIncludeHidden { enumOptions.insert(.skipsHiddenFiles) }
                
                // Prefetch exactly the keys processBatch consumes so the enumerator caches them
                // during the directory read — avoids a second per-file stat for every file.
                let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [
                        .isRegularFileKey, .isDirectoryKey,
                        .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey
                    ],
                    options: enumOptions
                )

                guard let fileEnum = enumerator else { continue }

                var batch: [URL] = []
                batch.reserveCapacity(2000)

                // Bound in-flight batches so a huge filesystem can't enqueue millions of pending
                // tasks (each holding a 2000-URL array) before the pool drains them.
                var inFlight = 0
                let maxInFlight = max(2, ProcessInfo.processInfo.activeProcessorCount)

                // Use nextObject() rather than for-in so we don't hold a non-Sendable enumerator
                // iterator across the `await group.next()` suspension point below.
                while let nextObject = fileEnum.nextObject() {
                    guard let url = nextObject as? URL else { continue }
                    if cancellationToken.isCancelled { throw FileIndexerError.cancelled }

                    // Simple path checks (fast)
                    let path = url.path.lowercased()
                    // Skip exact excluded paths or prefixes efficiently
                    if excluded.contains(where: { path.hasPrefix($0) }) {
                        fileEnum.skipDescendants()
                        continue
                    }

                    if path.contains("/timemachine") || path.contains("/.spotlight-v100") || path.contains("/.trash") {
                        fileEnum.skipDescendants()
                        continue
                    }

                    batch.append(url)

                    if batch.count >= 2000 {
                        let batchToProcess = batch
                        batch = []
                        batch.reserveCapacity(2000)

                        // Apply backpressure before enqueuing the next batch.
                        if inFlight >= maxInFlight {
                            _ = try await group.next()
                            inFlight -= 1
                        }
                        group.addTask {
                            if cancellationToken.isCancelled { return }
                            let result = processBatch(batchToProcess, classifier: classifier)
                            if !cancellationToken.isCancelled {
                                await aggregator.add(result: result, phase: phase)
                            }
                        }
                        inFlight += 1
                    }
                }

                // Process remaining
                if !batch.isEmpty {
                    let batchToProcess = batch
                    group.addTask {
                        let result = processBatch(batchToProcess, classifier: classifier)
                        await aggregator.add(result: result, phase: phase)
                    }
                }
            }
            
            // Wait for all tasks to complete
            try await group.waitForAll()
        }
        
        await aggregator.emitProgress(currentPath: "Finishing up...", phase: .analyzing)
        return await aggregator.getFinalResult()
    }
    
    private static func processBatch(_ urls: [URL], classifier: StorageClassifier) -> BatchResult {
        var scannedFiles = 0
        var scannedBytes: Int64 = 0
        var buckets: [StorageCategory: Int64] = [:]
        var fileCounts: [StorageCategory: Int] = [:]
        var files: [StorageCategory: [FileEntry]] = [:]
        var lastPath: String?
        
        for url in urls {
            // Re-check detailed resource values here (thread-safe on URL)
            do {
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .totalFileAllocatedSizeKey,
                    .contentModificationDateKey,
                    .isDirectoryKey
                ])
                
                if values.isDirectory == true { continue }
                guard values.isRegularFile == true else { continue }
                
                let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                scannedFiles += 1
                scannedBytes += size
                lastPath = url.path
                
                // Optimize: Use precomputed standard path if possible, but URL resource values don't give "standardized path string" easily
                // We'll trust the URL from enumerator is good enough.
                let category = classifier.classify(url: url)
                
                buckets[category, default: 0] += size
                fileCounts[category, default: 0] += 1
                
                if size > 1_000_000 {
                    let entry = FileEntry(
                        url: url,
                        sizeBytes: size,
                        modifiedAt: values.contentModificationDate
                    )
                    files[category, default: []].append(entry)
                }
            } catch {
                continue
            }
        }
        
        return BatchResult(
            scannedFiles: scannedFiles,
            scannedBytes: scannedBytes,
            buckets: buckets,
            fileCounts: fileCounts,
            files: files,
            lastPath: lastPath
        )
    }
    
    private static func determinePhase(for url: URL) -> ScanPhase {
        let path = url.path.lowercased()
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path.lowercased()
        
        // Use standard directory checks instead of hardcoded strings where possible
        if path.hasPrefix("/applications") {
            return .scanningApplications
        } else if path.hasPrefix("/system") {
            return .scanningSystem
        } else if path.hasPrefix("/library") || path.contains("/library") {
            return .scanningLibrary
        } else if path.hasPrefix(homeDir) {
            return .scanningHome
        }
        return .scanningHome
    }

    static func sizeOfPath(_ url: URL, includeHidden: Bool = true) -> Int64 {
        var total: Int64 = 0
        
        var enumOptions: FileManager.DirectoryEnumerationOptions = []
        if !includeHidden {
            enumOptions.insert(.skipsHiddenFiles)
        }
        
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .totalFileAllocatedSizeKey
            ],
            options: enumOptions
        )

        guard let fileEnum = enumerator else { return 0 }
        for case let fileURL as URL in fileEnum {
            let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .totalFileAllocatedSizeKey
            ])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}

struct StorageClassifier {
    // Cache standard paths to avoid repeated lookups
    private let homeDir: String
    private let userDocuments: String
    private let userDesktop: String
    private let userDownloads: String
    private let userMovies: String
    private let userMusic: String
    private let userPictures: String
    private let userLibrary: String
    
    // Extensions sets
    private let mediaExtensions: Set<String>
    private let devExtensions: Set<String>
    
    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path.lowercased()
        self.homeDir = home
        self.userDocuments = home + "/documents/"
        self.userDesktop = home + "/desktop/"
        self.userDownloads = home + "/downloads/"
        self.userMovies = home + "/movies/"
        self.userMusic = home + "/music/"
        self.userPictures = home + "/pictures/"
        self.userLibrary = home + "/library/"
        
        self.mediaExtensions = Set(["mp4", "mov", "avi", "mkv", "mp3", "aac", "flac", "wav", 
                                   "m4a", "m4v", "jpg", "jpeg", "png", "gif", "heic", "raw",
                                   "tiff", "bmp", "webp", "svg", "pdf"])
        
        self.devExtensions = Set(["swift", "m", "h", "c", "cpp", "py", "js", "ts", "json", 
                                 "xml", "plist", "xcodeproj", "xcworkspace"])
    }
    
    func classify(url: URL) -> StorageCategory {
        return classify(path: url.path.lowercased(), pathExtension: url.pathExtension.lowercased())
    }

    func classify(path: String, pathExtension: String) -> StorageCategory {
        // 1. Applications
        if path.hasPrefix("/applications") || 
           path.contains("/applications/") ||
           pathExtension == "app" {
            return .applications
        }
        
        // 2. Documents/Desktop/Downloads
        if path.hasPrefix(userDocuments) || 
           path.hasPrefix(userDesktop) || 
           path.hasPrefix(userDownloads) ||
           path.contains("/documents/") ||
           path.contains("/desktop/") ||
           path.contains("/downloads/") {
            return .documents
        }
        
        // 3. Media
        if path.hasPrefix(userMovies) || 
           path.hasPrefix(userMusic) || 
           path.hasPrefix(userPictures) ||
           mediaExtensions.contains(pathExtension) {
            return .media
        }
        
        // 4. System
        if path.hasPrefix("/system") || 
           path.hasPrefix("/library") ||
           path.hasPrefix("/usr") ||
           path.hasPrefix("/bin") ||
           path.hasPrefix("/sbin") ||
           path.hasPrefix("/private/var") {
            return .system
        }
        
        // 5. Library/Caches (App Data)
        if path.hasPrefix(userLibrary) || 
           path.contains("/library/caches/") ||
           path.contains("/library/application support/") ||
           path.contains("/library/containers/") ||
           path.contains("/library/logs/") ||
           path.contains("/library/preferences/") {
            return .libraries
        }
        
        // 6. Developer
        if devExtensions.contains(pathExtension) ||
           path.contains("/developer/") ||
           path.contains("/deriveddata/") ||
           path.contains("/.git/") {
            return .libraries
        }
        
        return .other
    }
    
    // Static helper for backward compatibility if needed, though instance method is preferred for perf
    static func category(for url: URL) -> StorageCategory {
        return StorageClassifier().classify(url: url)
    }
}
