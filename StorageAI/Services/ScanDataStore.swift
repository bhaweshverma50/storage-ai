import Foundation

/// Persistent storage for scan data
/// Saves scan results to disk so users don't need to rescan on every app launch
actor ScanDataStore {
    static let shared = ScanDataStore()
    
    private let fileManager = FileManager.default
    private var cacheDirectory: URL {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("com.storageai.app", isDirectory: true)
    }
    
    private var scanDataURL: URL {
        cacheDirectory.appendingPathComponent("scan_data.json")
    }
    
    private var metadataURL: URL {
        cacheDirectory.appendingPathComponent("metadata.json")
    }
    
    private var appsDataURL: URL {
        cacheDirectory.appendingPathComponent("apps_data.json")
    }
    
    private var performanceHistoryURL: URL {
        cacheDirectory.appendingPathComponent("performance_history.json")
    }
    
    private init() {
        // Ensure cache directory exists
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
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
        progress: ScanProgress,
        scanDuration: TimeInterval,
        scanState: ScanState = .complete
    ) async throws {
        // Convert to persisted format
        let buckets = summary.buckets.map { bucket in
            PersistedScanData.PersistedBucket(
                category: bucket.category.rawValue,
                bytes: bucket.bytes,
                fileCount: filesByCategory[bucket.category]?.count ?? 0
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
        
        // Write to disk
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        
        let scanDataJSON = try encoder.encode(scanData)
        try scanDataJSON.write(to: scanDataURL)
        
        let metadataJSON = try encoder.encode(metadata)
        try metadataJSON.write(to: metadataURL)
    }
    
    // MARK: - Load
    
    func load() async throws -> (summary: StorageSummary, filesByCategory: [StorageCategory: [FileEntry]], metadata: ScanMetadata, fileCounts: [StorageCategory: Int])? {
        guard fileManager.fileExists(atPath: scanDataURL.path),
              fileManager.fileExists(atPath: metadataURL.path) else {
            return nil
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let scanDataJSON = try Data(contentsOf: scanDataURL)
        let scanData = try decoder.decode(PersistedScanData.self, from: scanDataJSON)
        
        let metadataJSON = try Data(contentsOf: metadataURL)
        let metadata = try decoder.decode(ScanMetadata.self, from: metadataJSON)
        
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
}
