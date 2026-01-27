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
    ) throws -> ScanResult {
        // Start with initial values if resuming, otherwise start fresh
        var buckets = initialBuckets ?? StorageCategory.allCases.reduce(into: [StorageCategory: Int64]()) { $0[$1] = 0 }
        
        // Use Heaps for tracking top files per category (O(log N) insertion)
        var fileHeaps: [StorageCategory: FileHeap] = [:]
        for category in StorageCategory.allCases {
            fileHeaps[category] = FileHeap(maxSize: 1000)
        }
        
        // If resuming, re-populate heaps (this is O(N log N) but N is small (1000))
        if let initialFiles = initialFiles {
            for (category, files) in initialFiles {
                for file in files {
                    fileHeaps[category]?.insert(file)
                }
            }
        }

        var categoryFileCounts: [StorageCategory: Int] = initialFiles?.mapValues { $0.count } ?? StorageCategory.allCases.reduce(into: [StorageCategory: Int]()) { $0[$1] = 0 }
        var scannedFiles = initialScannedFiles
        var scannedBytes: Int64 = initialScannedBytes
        var lastProgressUpdate = Date()

        let excluded = Set(excludedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path.lowercased() })
        
        // Get common system paths for faster classification
        let classifier = StorageClassifier()

        // Send initial progress
        progress(ScanUpdate(
            scannedFiles: 0,
            scannedBytes: 0,
            currentPath: "Starting scan...",
            phase: .preparing,
            buckets: buckets,
            fileCounts: categoryFileCounts
        ))

        for root in roots {
            // Check cancellation at each root
            if cancellationToken.isCancelled {
                throw FileIndexerError.cancelled
            }
            
            // Determine scan phase based on root
            let phase = determinePhase(for: root)
            progress(ScanUpdate(
                scannedFiles: scannedFiles,
                scannedBytes: scannedBytes,
                currentPath: "Scanning: \(root.lastPathComponent)",
                phase: phase,
                buckets: buckets,
                fileCounts: categoryFileCounts
            ))
            
            // For Library folder, always include hidden files
            let shouldIncludeHidden = includeHidden || root.path.contains("/Library")
            
            // Use different options based on what we're scanning
            var enumOptions: FileManager.DirectoryEnumerationOptions = []
            if !shouldIncludeHidden {
                enumOptions.insert(.skipsHiddenFiles)
            }
            
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .fileSizeKey,
                    .totalFileAllocatedSizeKey,
                    .isHiddenKey,
                    .contentModificationDateKey
                ],
                options: enumOptions
            )

            guard let fileEnum = enumerator else {
                continue
            }

            var batchCount = 0
            let batchSize = 100  // Process in batches to release memory
            
            for case let url as URL in fileEnum {
                // Check cancellation frequently
                if cancellationToken.isCancelled {
                    throw FileIndexerError.cancelled
                }
                
                // Use autoreleasepool every batch to release Objective-C objects
                let shouldDrainPool = batchCount >= batchSize
                if shouldDrainPool {
                    batchCount = 0
                }
                
                autoreleasepool {
                    let standardPath = url.standardizedFileURL.path
                    let lowercasePath = standardPath.lowercased()
                    
                    // Skip excluded paths
                    if excluded.contains(where: { lowercasePath.hasPrefix($0) }) {
                        fileEnum.skipDescendants()
                        return
                    }
                    
                    // Skip problematic system paths
                    if lowercasePath.contains("/timemachine") ||
                       lowercasePath.contains("/.spotlight-v100") ||
                       lowercasePath.contains("/.fseventsd") ||
                       lowercasePath.contains("/.trash") ||
                       lowercasePath.contains("/volumes/") && !lowercasePath.contains("/volumes/macintosh") {
                        fileEnum.skipDescendants()
                        return
                    }

                    do {
                        let values = try url.resourceValues(forKeys: [
                            .isDirectoryKey,
                            .isRegularFileKey,
                            .isHiddenKey,
                            .fileSizeKey,
                            .totalFileAllocatedSizeKey,
                            .contentModificationDateKey
                        ])

                        // Skip directories (we still traverse into them)
                        if values.isDirectory == true {
                            return
                        }

                        guard values.isRegularFile == true else { return }

                        let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                        scannedFiles += 1
                        scannedBytes += size

                        let category = classifier.classify(url: url)
                        buckets[category, default: 0] += size
                        categoryFileCounts[category, default: 0] += 1

                        // Store files larger than 1MB for display
                        // Using Heap insert is O(log N) instead of Array O(N) sort/insert
                        if size > 1_000_000 {
                            fileHeaps[category]?.insert(FileEntry(
                                url: url,
                                sizeBytes: size,
                                modifiedAt: values.contentModificationDate
                            ))
                        }

                        // Update progress every 5 seconds OR every 2000 files
                        let now = Date()
                        let timeSinceLastUpdate = now.timeIntervalSince(lastProgressUpdate)
                        if timeSinceLastUpdate >= 5.0 || scannedFiles % 2000 == 0 {
                            lastProgressUpdate = now
                            progress(ScanUpdate(
                                scannedFiles: scannedFiles,
                                scannedBytes: scannedBytes,
                                currentPath: url.path,
                                phase: phase,
                                buckets: buckets,
                                fileCounts: categoryFileCounts
                            ))
                        }
                    } catch {
                        // Skip files we can't read
                        return
                    }
                }
                
                batchCount += 1
            }
        }

        // Final update
        progress(ScanUpdate(
            scannedFiles: scannedFiles,
            scannedBytes: scannedBytes,
            currentPath: "Finishing up...",
            phase: .analyzing,
            buckets: buckets,
            fileCounts: categoryFileCounts
        ))
        
        // Convert heaps back to sorted arrays for final result
        var finalFiles: [StorageCategory: [FileEntry]] = [:]
        for (category, heap) in fileHeaps {
            finalFiles[category] = heap.files.sorted { $0.sizeBytes > $1.sizeBytes }
        }
        
        let bucketList = StorageCategory.allCases.map { StorageBucket(category: $0, bytes: buckets[$0, default: 0]) }
        return ScanResult(buckets: bucketList, filesByCategory: finalFiles)
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

class StorageClassifier {
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
        let path = url.path.lowercased()
        let pathExtension = url.pathExtension.lowercased()
        
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
