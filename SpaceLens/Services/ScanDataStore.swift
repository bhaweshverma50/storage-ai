import Foundation

/// Persistent storage for scan data
/// Saves scan results to disk so users don't need to rescan on every app launch
actor ScanDataStore {
    static let shared = ScanDataStore()
    
    private let fileManager = FileManager.default

    // These are pure path computations (no mutable actor state), so they're nonisolated and
    // safe to use from the synchronous init and any context.
    private nonisolated var cacheDirectory: URL {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("com.spacelens.app", isDirectory: true)
    }

    private nonisolated var scanDataURL: URL {
        cacheDirectory.appendingPathComponent("scan_data.json")
    }

    private nonisolated var metadataURL: URL {
        cacheDirectory.appendingPathComponent("metadata.json")
    }

    private nonisolated var appsDataURL: URL {
        cacheDirectory.appendingPathComponent("apps_data.json")
    }

    private nonisolated var performanceHistoryURL: URL {
        cacheDirectory.appendingPathComponent("performance_history.json")
    }

    private nonisolated var mediaAnalysisURL: URL {
        cacheDirectory.appendingPathComponent("media_analysis.json")
    }

    private init() {
        // Ensure cache directory exists
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - Persistence Models
    
    struct PersistedScanData: Codable {
        let buckets: [PersistedBucket]
        let totalBytes: Int64
        let fileCount: Int
        let scanDate: Date
        let topFiles: [PersistedFileEntry]  // Only store top files to save memory
        
        struct PersistedBucket: Codable {
            let category: String
            let bytes: Int64
            let fileCount: Int
        }
        
        struct PersistedFileEntry: Codable {
            let path: String
            let sizeBytes: Int64
            let modifiedAt: Date?
            let category: String
        }
    }
    
    struct ScanMetadata: Codable {
        let lastScanDate: Date
        let scanDurationSeconds: Double
        let totalFilesScanned: Int
        let totalBytesScanned: Int64
        let version: String
        let scanState: ScanState
        
        // Backward compatibility for old cache files
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            lastScanDate = try container.decode(Date.self, forKey: .lastScanDate)
            scanDurationSeconds = try container.decode(Double.self, forKey: .scanDurationSeconds)
            totalFilesScanned = try container.decode(Int.self, forKey: .totalFilesScanned)
            totalBytesScanned = try container.decode(Int64.self, forKey: .totalBytesScanned)
            version = try container.decode(String.self, forKey: .version)
            scanState = try container.decodeIfPresent(ScanState.self, forKey: .scanState) ?? .complete
        }
        
        init(lastScanDate: Date, scanDurationSeconds: Double, totalFilesScanned: Int, totalBytesScanned: Int64, version: String, scanState: ScanState) {
            self.lastScanDate = lastScanDate
            self.scanDurationSeconds = scanDurationSeconds
            self.totalFilesScanned = totalFilesScanned
            self.totalBytesScanned = totalBytesScanned
            self.version = version
            self.scanState = scanState
        }
    }
    
    // MARK: - Save
    
    func save(
        summary: StorageSummary,
        filesByCategory: [StorageCategory: [FileEntry]],
        fileCounts: [StorageCategory: Int] = [:],
        progress: ScanProgress,
        scanDuration: TimeInterval,
        scanState: ScanState = .complete
    ) async throws {
        // Persist the REAL per-category file count (tracked live during the scan), not just the
        // top-N file list's count — the list is empty until a scan completes, so deriving the
        // count from it made interrupted scans persist 0 files per category.
        let buckets = summary.buckets.map { bucket in
            PersistedScanData.PersistedBucket(
                category: bucket.category.rawValue,
                bytes: bucket.bytes,
                fileCount: fileCounts[bucket.category] ?? filesByCategory[bucket.category]?.count ?? 0
            )
        }
        
        // Only store top 100 files per category to save memory
        var topFiles: [PersistedScanData.PersistedFileEntry] = []
        for (category, files) in filesByCategory {
            let topForCategory = files
                .sorted { $0.sizeBytes > $1.sizeBytes }
                .prefix(100)
                .map { entry in
                    PersistedScanData.PersistedFileEntry(
                        path: entry.url.path,
                        sizeBytes: entry.sizeBytes,
                        modifiedAt: entry.modifiedAt,
                        category: category.rawValue
                    )
                }
            topFiles.append(contentsOf: topForCategory)
        }
        
        let scanData = PersistedScanData(
            buckets: buckets,
            totalBytes: summary.totalBytes,
            fileCount: progress.scannedFiles,
            scanDate: Date(),
            topFiles: topFiles
        )
        
        let metadata = ScanMetadata(
            lastScanDate: Date(),
            scanDurationSeconds: scanDuration,
            totalFilesScanned: progress.scannedFiles,
            totalBytesScanned: progress.scannedBytes,
            version: "1.0",
            scanState: scanState
        )
        
        // Write to disk. This is a machine-only cache, so skip pretty-printing (smaller/faster)
        // and write atomically so a crash mid-write can't leave a torn, undecodable file.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let scanDataJSON = try encoder.encode(scanData)
        try scanDataJSON.write(to: scanDataURL, options: .atomic)

        let metadataJSON = try encoder.encode(metadata)
        try metadataJSON.write(to: metadataURL, options: .atomic)
    }
    
    // MARK: - Load
    
    func load() async throws -> (summary: StorageSummary, filesByCategory: [StorageCategory: [FileEntry]], metadata: ScanMetadata, fileCounts: [StorageCategory: Int])? {
        guard fileManager.fileExists(atPath: scanDataURL.path),
              fileManager.fileExists(atPath: metadataURL.path) else {
            return nil
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let scanData: PersistedScanData
        let metadata: ScanMetadata
        do {
            scanData = try decoder.decode(PersistedScanData.self, from: Data(contentsOf: scanDataURL))
            metadata = try decoder.decode(ScanMetadata.self, from: Data(contentsOf: metadataURL))
        } catch {
            // Cache is corrupt or from an incompatible schema (e.g. after an app update). Clear it
            // and fall back to a fresh scan instead of repeatedly failing to load.
            try? fileManager.removeItem(at: scanDataURL)
            try? fileManager.removeItem(at: metadataURL)
            return nil
        }
        
        // Convert back to app models and extract file counts
        var fileCounts: [StorageCategory: Int] = [:]
        let buckets = scanData.buckets.compactMap { persisted -> StorageBucket? in
            guard let category = StorageCategory(rawValue: persisted.category) else { return nil }
            fileCounts[category] = persisted.fileCount
            return StorageBucket(category: category, bytes: persisted.bytes)
        }
        
        // Ensure all categories are present
        var allBuckets = StorageCategory.allCases.map { StorageBucket(category: $0, bytes: 0) }
        for bucket in buckets {
            if let index = allBuckets.firstIndex(where: { $0.category == bucket.category }) {
                allBuckets[index] = bucket
            }
        }
        
        let summary = StorageSummary(buckets: allBuckets)
        
        // Reconstruct files by category
        var filesByCategory: [StorageCategory: [FileEntry]] = [:]
        for persisted in scanData.topFiles {
            guard let category = StorageCategory(rawValue: persisted.category) else { continue }
            let entry = FileEntry(
                url: URL(fileURLWithPath: persisted.path),
                sizeBytes: persisted.sizeBytes,
                modifiedAt: persisted.modifiedAt
            )
            filesByCategory[category, default: []].append(entry)
        }
        
        return (summary, filesByCategory, metadata, fileCounts)
    }
    
    // MARK: - Metadata
    
    func getMetadata() async -> ScanMetadata? {
        guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
        
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: metadataURL)
            return try decoder.decode(ScanMetadata.self, from: data)
        } catch {
            return nil
        }
    }
    
    // MARK: - Clear
    
    func clear() async {
        try? fileManager.removeItem(at: scanDataURL)
        try? fileManager.removeItem(at: metadataURL)
    }
    
    // MARK: - Age Check
    
    func isDataStale(maxAgeHours: Int = 24) async -> Bool {
        guard let metadata = await getMetadata() else { return true }
        let age = Date().timeIntervalSince(metadata.lastScanDate)
        return age > TimeInterval(maxAgeHours * 3600)
    }
    
    // MARK: - Apps Data
    
    struct PersistedAppEntry: Codable {
        let name: String
        let bundleIdentifier: String?
        let bundlePath: String
        let bundleSizeBytes: Int64
        let supportSizeBytes: Int64
        let cacheSizeBytes: Int64
        let containerSizeBytes: Int64
    }
    
    func saveApps(_ apps: [AppEntry]) async throws {
        let persistedApps = apps.map { app in
            PersistedAppEntry(
                name: app.name,
                bundleIdentifier: app.bundleIdentifier,
                bundlePath: app.bundleURL.path,
                bundleSizeBytes: app.bundleSizeBytes,
                supportSizeBytes: app.supportSizeBytes,
                cacheSizeBytes: app.cacheSizeBytes,
                containerSizeBytes: app.containerSizeBytes
            )
        }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(persistedApps)
        try data.write(to: appsDataURL)
    }
    
    func loadApps() async throws -> [AppEntry]? {
        guard fileManager.fileExists(atPath: appsDataURL.path) else {
            return nil
        }
        
        let data = try Data(contentsOf: appsDataURL)
        let decoder = JSONDecoder()
        let persistedApps = try decoder.decode([PersistedAppEntry].self, from: data)
        
        return persistedApps.map { persisted in
            AppEntry(
                name: persisted.name,
                bundleIdentifier: persisted.bundleIdentifier,
                bundleURL: URL(fileURLWithPath: persisted.bundlePath),
                bundleSizeBytes: persisted.bundleSizeBytes,
                supportSizeBytes: persisted.supportSizeBytes,
                cacheSizeBytes: persisted.cacheSizeBytes,
                containerSizeBytes: persisted.containerSizeBytes
            )
        }
    }
    
    func clearApps() async {
        try? fileManager.removeItem(at: appsDataURL)
    }
    
    // MARK: - Performance History (for time estimation)
    
    struct ScanPerformanceHistory: Codable {
        var completedScans: Int
        var totalBytesScanned: Int64
        var totalTimeSeconds: Double
        var lastUpdated: Date
        
        /// Average scan speed in bytes per second
        var averageBytesPerSecond: Double {
            guard totalTimeSeconds > 0 else { return 50_000_000 } // Default: 50 MB/s
            return Double(totalBytesScanned) / totalTimeSeconds
        }
        
        init(completedScans: Int = 0, totalBytesScanned: Int64 = 0, totalTimeSeconds: Double = 0, lastUpdated: Date = Date()) {
            self.completedScans = completedScans
            self.totalBytesScanned = totalBytesScanned
            self.totalTimeSeconds = totalTimeSeconds
            self.lastUpdated = lastUpdated
        }
        
        /// Update history with a new completed scan
        mutating func recordScan(bytesScanned: Int64, durationSeconds: Double) {
            completedScans += 1
            totalBytesScanned += bytesScanned
            totalTimeSeconds += durationSeconds
            lastUpdated = Date()
        }
    }
    
    func savePerformanceHistory(_ history: ScanPerformanceHistory) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(history)
        try data.write(to: performanceHistoryURL)
    }
    
    func loadPerformanceHistory() async -> ScanPerformanceHistory {
        guard fileManager.fileExists(atPath: performanceHistoryURL.path) else {
            return ScanPerformanceHistory()
        }
        
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: performanceHistoryURL)
            return try decoder.decode(ScanPerformanceHistory.self, from: data)
        } catch {
            return ScanPerformanceHistory()
        }
    }
    
    func clearPerformanceHistory() async {
        try? fileManager.removeItem(at: performanceHistoryURL)
    }
    
    // MARK: - Media Analysis Data
    
    struct PersistedMediaItem: Codable {
        let id: String
        let path: String
        let type: String
        let sizeBytes: Int64
        let width: Double?
        let height: Double?
        let duration: Double?
        let createdAt: Date?
        let modifiedAt: Date?
        let subcategories: [String]
    }
    
    struct PersistedMediaAnalysis: Codable {
        let items: [PersistedMediaItem]
        let stats: PersistedMediaStats
        let analysisDate: Date
        let version: String
        
        struct PersistedMediaStats: Codable {
            let totalCount: Int
            let totalSize: Int64
            let photoCount: Int
            let videoCount: Int
            let screenshotCount: Int
            let largeFileCount: Int
            let oldMediaCount: Int
            let duplicateCount: Int
        }
    }
    
    func saveMediaAnalysis(_ result: MediaAnalysisResult) async throws {
        let persistedItems = result.items.map { item in
            PersistedMediaItem(
                id: item.id.uuidString,
                path: item.url.path,
                type: item.type.rawValue,
                sizeBytes: item.sizeBytes,
                width: item.dimensions.map { Double($0.width) },
                height: item.dimensions.map { Double($0.height) },
                duration: item.duration,
                createdAt: item.createdAt,
                modifiedAt: item.modifiedAt,
                subcategories: item.subcategories.map { $0.rawValue }
            )
        }
        
        let persistedStats = PersistedMediaAnalysis.PersistedMediaStats(
            totalCount: result.stats.totalCount,
            totalSize: result.stats.totalSize,
            photoCount: result.stats.photoCount,
            videoCount: result.stats.videoCount,
            screenshotCount: result.stats.screenshotCount,
            largeFileCount: result.stats.largeFileCount,
            oldMediaCount: result.stats.oldMediaCount,
            duplicateCount: result.stats.duplicateCount
        )
        
        let analysis = PersistedMediaAnalysis(
            items: persistedItems,
            stats: persistedStats,
            analysisDate: Date(),
            version: "1.0"
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(analysis)
        try data.write(to: mediaAnalysisURL)
    }
    
    func loadMediaAnalysis() async throws -> (items: [MediaItem], stats: MediaAnalysisResult.MediaStats, analysisDate: Date)? {
        guard fileManager.fileExists(atPath: mediaAnalysisURL.path) else {
            return nil
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: mediaAnalysisURL)
        let analysis = try decoder.decode(PersistedMediaAnalysis.self, from: data)
        
        // Convert back to app models
        let items = analysis.items.compactMap { persisted -> MediaItem? in
            guard let type = MediaType(rawValue: persisted.type),
                  let id = UUID(uuidString: persisted.id) else {
                return nil
            }
            
            let dimensions: CGSize?
            if let width = persisted.width, let height = persisted.height {
                dimensions = CGSize(width: width, height: height)
            } else {
                dimensions = nil
            }
            
            let subcategories = Set(persisted.subcategories.compactMap { MediaSubcategory(rawValue: $0) })
            
            return MediaItem(
                id: id,
                url: URL(fileURLWithPath: persisted.path),
                type: type,
                sizeBytes: persisted.sizeBytes,
                dimensions: dimensions,
                duration: persisted.duration,
                createdAt: persisted.createdAt,
                modifiedAt: persisted.modifiedAt,
                subcategories: subcategories
            )
        }
        
        let stats = MediaAnalysisResult.MediaStats(
            totalCount: analysis.stats.totalCount,
            totalSize: analysis.stats.totalSize,
            photoCount: analysis.stats.photoCount,
            videoCount: analysis.stats.videoCount,
            screenshotCount: analysis.stats.screenshotCount,
            largeFileCount: analysis.stats.largeFileCount,
            oldMediaCount: analysis.stats.oldMediaCount,
            duplicateCount: analysis.stats.duplicateCount
        )
        
        return (items, stats, analysis.analysisDate)
    }
    
    func clearMediaAnalysis() async {
        try? fileManager.removeItem(at: mediaAnalysisURL)
        // Also clear incremental file
        try? fileManager.removeItem(at: mediaItemsIncrementalURL)
    }
    
    func isMediaAnalysisStale(maxAgeHours: Int = 24) async -> Bool {
        do {
            guard let result = try await loadMediaAnalysis() else { return true }
            let age = Date().timeIntervalSince(result.analysisDate)
            return age > TimeInterval(maxAgeHours * 3600)
        } catch {
            return true
        }
    }
    
    // MARK: - Incremental Media Streaming
    
    /// URL for streaming media items during analysis
    private var mediaItemsIncrementalURL: URL {
        cacheDirectory.appendingPathComponent("media_items_incremental.jsonl")
    }
    
    /// Start a new incremental media analysis session
    /// Clears any previous incremental data
    func startIncrementalMediaAnalysis() async {
        try? fileManager.removeItem(at: mediaItemsIncrementalURL)
        // Create empty file
        fileManager.createFile(atPath: mediaItemsIncrementalURL.path, contents: nil)
    }
    
    /// Append a batch of media items to the incremental cache
    /// Uses JSON Lines format for efficient append-only writes
    func appendMediaItems(_ items: [MediaItem]) async throws {
        guard !items.isEmpty else { return }
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        // Convert items to JSON Lines (one JSON object per line)
        var lines = ""
        for item in items {
            let persisted = PersistedMediaItem(
                id: item.id.uuidString,
                path: item.url.path,
                type: item.type.rawValue,
                sizeBytes: item.sizeBytes,
                width: item.dimensions.map { Double($0.width) },
                height: item.dimensions.map { Double($0.height) },
                duration: item.duration,
                createdAt: item.createdAt,
                modifiedAt: item.modifiedAt,
                subcategories: item.subcategories.map { $0.rawValue }
            )
            
            let data = try encoder.encode(persisted)
            if let jsonString = String(data: data, encoding: .utf8) {
                lines += jsonString + "\n"
            }
        }
        
        // Append to file
        if let data = lines.data(using: .utf8) {
            if let fileHandle = try? FileHandle(forWritingTo: mediaItemsIncrementalURL) {
                defer { try? fileHandle.close() }
                try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: data)
            } else {
                // File doesn't exist, create it
                try data.write(to: mediaItemsIncrementalURL)
            }
        }
    }
    
    /// Load all incrementally saved media items
    func loadIncrementalMediaItems() async throws -> [MediaItem] {
        guard fileManager.fileExists(atPath: mediaItemsIncrementalURL.path) else {
            return []
        }
        
        let content = try String(contentsOf: mediaItemsIncrementalURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        var items: [MediaItem] = []
        items.reserveCapacity(lines.count)
        
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let persisted = try? decoder.decode(PersistedMediaItem.self, from: data),
                  let type = MediaType(rawValue: persisted.type),
                  let id = UUID(uuidString: persisted.id) else {
                continue
            }
            
            let dimensions: CGSize?
            if let width = persisted.width, let height = persisted.height {
                dimensions = CGSize(width: width, height: height)
            } else {
                dimensions = nil
            }
            
            let subcategories = Set(persisted.subcategories.compactMap { MediaSubcategory(rawValue: $0) })
            
            let item = MediaItem(
                id: id,
                url: URL(fileURLWithPath: persisted.path),
                type: type,
                sizeBytes: persisted.sizeBytes,
                dimensions: dimensions,
                duration: persisted.duration,
                createdAt: persisted.createdAt,
                modifiedAt: persisted.modifiedAt,
                subcategories: subcategories
            )
            items.append(item)
        }
        
        return items
    }
    
    /// Finalize incremental analysis by saving full analysis result
    /// and cleaning up incremental file
    func finalizeIncrementalAnalysis(stats: MediaAnalysisResult.MediaStats) async throws {
        let items = try await loadIncrementalMediaItems()
        
        let persistedItems = items.map { item in
            PersistedMediaItem(
                id: item.id.uuidString,
                path: item.url.path,
                type: item.type.rawValue,
                sizeBytes: item.sizeBytes,
                width: item.dimensions.map { Double($0.width) },
                height: item.dimensions.map { Double($0.height) },
                duration: item.duration,
                createdAt: item.createdAt,
                modifiedAt: item.modifiedAt,
                subcategories: item.subcategories.map { $0.rawValue }
            )
        }
        
        let persistedStats = PersistedMediaAnalysis.PersistedMediaStats(
            totalCount: stats.totalCount,
            totalSize: stats.totalSize,
            photoCount: stats.photoCount,
            videoCount: stats.videoCount,
            screenshotCount: stats.screenshotCount,
            largeFileCount: stats.largeFileCount,
            oldMediaCount: stats.oldMediaCount,
            duplicateCount: stats.duplicateCount
        )
        
        let analysis = PersistedMediaAnalysis(
            items: persistedItems,
            stats: persistedStats,
            analysisDate: Date(),
            version: "1.0"
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(analysis)
        try data.write(to: mediaAnalysisURL)
        
        // Clean up incremental file
        try? fileManager.removeItem(at: mediaItemsIncrementalURL)
    }
}
