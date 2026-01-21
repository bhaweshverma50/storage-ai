import Foundation
import Combine

@MainActor
final class ScanService: ObservableObject {
    @Published private(set) var summary: StorageSummary
    @Published private(set) var filesByCategory: [StorageCategory: [FileEntry]] = [:]
    @Published private(set) var progress = ScanProgress()
    @Published private(set) var isScanning = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var hasLoadedCache = false

    private var scanTask: Task<Void, Never>?
    private var cancellationToken: CancellationToken?
    private var scanStartTime: Date?

    init() {
        let initialBuckets = StorageCategory.allCases.map { StorageBucket(category: $0, bytes: 0) }
        self.summary = StorageSummary(buckets: initialBuckets)
    }
    
    // MARK: - Load Cached Data
    
    func loadCachedData() async {
        guard !hasLoadedCache else { return }
        hasLoadedCache = true
        
        do {
            if let cached = try await ScanDataStore.shared.load() {
                await MainActor.run {
                    self.summary = cached.summary
                    self.filesByCategory = cached.filesByCategory
                    self.lastScanDate = cached.metadata.lastScanDate
                    self.progress = ScanProgress(
                        scannedFiles: cached.metadata.totalFilesScanned,
                        scannedBytes: cached.metadata.totalBytesScanned,
                        currentPath: "",
                        phase: .complete
                    )
                }
            }
        } catch {
            print("Failed to load cached scan data: \(error)")
        }
    }
    
    // MARK: - Check if Rescan Needed
    
    func shouldRescan(maxAgeHours: Int = 24) async -> Bool {
        return await ScanDataStore.shared.isDataStale(maxAgeHours: maxAgeHours)
    }

    // MARK: - Start Scan
    
    func startScan(settings: AppSettings, roots: [URL]) {
        guard !isScanning else { return }
        
        // Set scanning state IMMEDIATELY
        isScanning = true
        lastError = nil
        scanStartTime = Date()
        progress = ScanProgress(phase: .preparing)
        
        // Create cancellation token
        let token = CancellationToken()
        self.cancellationToken = token
        
        // Reset data
        let initialBuckets = StorageCategory.allCases.map { StorageBucket(category: $0, bytes: 0) }
        summary = StorageSummary(buckets: initialBuckets)
        filesByCategory = [:]
        
        // Capture settings for background task
        let includeHidden = settings.includeHidden
        let excludedPaths = settings.excludedPaths
        
        // Start background scan
        scanTask = Task { [weak self] in
            guard let self = self else { return }
            
            // Run the scan on a background thread with lower priority for efficiency
            let result: Result<ScanResult, Error> = await Task.detached(priority: .utility) {
                do {
                    let scanResult = try FileIndexer.scan(
                        roots: roots,
                        includeHidden: includeHidden,
                        excludedPaths: excludedPaths,
                        cancellationToken: token,
                        progress: { update in
                            // Update progress AND summary on main actor
                            Task { @MainActor in
                                guard !token.isCancelled else { return }
                                self.progress = ScanProgress(
                                    scannedFiles: update.scannedFiles,
                                    scannedBytes: update.scannedBytes,
                                    currentPath: update.currentPath,
                                    phase: update.phase
                                )
                                
                                // Update summary buckets in real-time
                                let bucketList = StorageCategory.allCases.map { 
                                    StorageBucket(category: $0, bytes: update.buckets[$0, default: 0]) 
                                }
                                self.summary = StorageSummary(buckets: bucketList)
                            }
                        }
                    )
                    return .success(scanResult)
                } catch {
                    return .failure(error)
                }
            }.value
            
            // Check if cancelled before final update
            guard !token.isCancelled else {
                await MainActor.run {
                    self.isScanning = false
                }
                return
            }
            
            // Calculate scan duration
            let scanDuration = self.scanStartTime.map { Date().timeIntervalSince($0) } ?? 0
            
            // Final update on main actor
            await MainActor.run {
                switch result {
                case .success(let scanResult):
                    self.summary = StorageSummary(buckets: scanResult.buckets)
                    self.filesByCategory = scanResult.filesByCategory
                    self.lastScanDate = Date()
                    self.progress = ScanProgress(
                        scannedFiles: self.progress.scannedFiles,
                        scannedBytes: self.progress.scannedBytes,
                        currentPath: "",
                        phase: .complete
                    )
                    
                    // Save to cache in background
                    Task.detached(priority: .background) {
                        try? await ScanDataStore.shared.save(
                            summary: self.summary,
                            filesByCategory: self.filesByCategory,
                            progress: self.progress,
                            scanDuration: scanDuration
                        )
                    }
                    
                case .failure(let error):
                    if case FileIndexerError.cancelled = error {
                        // Don't set error for cancellation
                    } else {
                        self.lastError = error.localizedDescription
                    }
                }
                
                self.isScanning = false
            }
        }
    }

    func cancelScan() {
        // Cancel the token first - this stops the file enumeration
        cancellationToken?.cancel()
        cancellationToken = nil
        
        // Cancel the task
        scanTask?.cancel()
        scanTask = nil
        
        // Update state
        isScanning = false
        progress = ScanProgress(
            scannedFiles: progress.scannedFiles,
            scannedBytes: progress.scannedBytes,
            currentPath: "",
            phase: .complete
        )
    }

    func removeEntries(category: StorageCategory, ids: Set<UUID>) {
        guard var entries = filesByCategory[category] else { return }
        let removed = entries.filter { ids.contains($0.id) }
        entries.removeAll { ids.contains($0.id) }
        filesByCategory[category] = entries

        let removedBytes = removed.reduce(0) { $0 + $1.sizeBytes }
        summary = StorageSummary(
            buckets: summary.buckets.map { bucket in
                guard bucket.category == category else { return bucket }
                return StorageBucket(category: bucket.category, bytes: max(0, bucket.bytes - removedBytes))
            }
        )
        
        progress = ScanProgress(
            scannedFiles: max(0, progress.scannedFiles - removed.count),
            scannedBytes: max(0, progress.scannedBytes - removedBytes),
            currentPath: progress.currentPath,
            phase: progress.phase
        )
    }
    
    func refreshDiskInfo() {
        summary = StorageSummary(buckets: summary.buckets, diskInfo: .current)
    }
    
    func clearCache() async {
        await ScanDataStore.shared.clear()
    }
}
