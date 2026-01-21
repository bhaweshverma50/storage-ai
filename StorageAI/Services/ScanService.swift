import Foundation
import Combine

enum ScanState: String, Codable {
    case neverScanned = "never"      // First time - show "Start Scan"
    case partial = "partial"          // Cancelled/interrupted - show "Resume Scan"  
    case complete = "complete"        // Fully completed - show "Scan Again"
}

@MainActor
final class ScanService: ObservableObject {
    @Published private(set) var summary: StorageSummary
    @Published private(set) var filesByCategory: [StorageCategory: [FileEntry]] = [:]
    @Published private(set) var progress = ScanProgress()
    @Published private(set) var isScanning = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var hasLoadedCache = false
    @Published private(set) var isLoadingCache = true
    @Published private(set) var scanState: ScanState = .neverScanned

    private var scanTask: Task<Void, Never>?
    private var periodicSaveTask: Task<Void, Never>?
    private var cancellationToken: CancellationToken?
    private var scanStartTime: Date?
    private var lastPeriodicSaveTime: Date?
    
    private let periodicSaveInterval: TimeInterval = 60 // Save every 60 seconds
    
    var scanButtonTitle: String {
        switch scanState {
        case .neverScanned: return "Start Scan"
        case .partial: return "Resume Scan"
        case .complete: return "Scan Again"
        }
    }

    init() {
        let initialBuckets = StorageCategory.allCases.map { StorageBucket(category: $0, bytes: 0) }
        self.summary = StorageSummary(buckets: initialBuckets)

        // Load cache immediately on init
        Task { @MainActor in
            await self.loadCachedData()
        }
    }
    
    // MARK: - Load Cached Data
    
    func loadCachedData() async {
        guard !hasLoadedCache else {
            isLoadingCache = false
            return
        }
        hasLoadedCache = true

        do {
            if let cached = try await ScanDataStore.shared.load() {
                self.summary = cached.summary
                self.filesByCategory = cached.filesByCategory
                self.lastScanDate = cached.metadata.lastScanDate
                self.progress = ScanProgress(
                    scannedFiles: cached.metadata.totalFilesScanned,
                    scannedBytes: cached.metadata.totalBytesScanned,
                    currentPath: "",
                    phase: .complete
                )
                // Load scan state from cache
                self.scanState = cached.metadata.scanState
            }
        } catch {
            print("Failed to load cached scan data: \(error)")
        }

        isLoadingCache = false
    }
    
    // MARK: - Check if Rescan Needed
    
    func shouldRescan(maxAgeHours: Int = 24) async -> Bool {
        return await ScanDataStore.shared.isDataStale(maxAgeHours: maxAgeHours)
    }

    // MARK: - Start Scan
    
    func startScan(settings: AppSettings, roots: [URL]) {
        guard !isScanning else { return }
        
        // Check if this is a resume BEFORE any state changes
        let isResume = scanState == .partial && summary.totalBytes > 0
        
        // Capture initial values for resume BEFORE any resets
        let resumeInitialBuckets: [StorageCategory: Int64]? = isResume ? Dictionary(uniqueKeysWithValues: summary.buckets.map { ($0.category, $0.bytes) }) : nil
        let resumeInitialFiles: [StorageCategory: [FileEntry]]? = isResume ? filesByCategory : nil
        let resumeScannedFiles = isResume ? progress.scannedFiles : 0
        let resumeScannedBytes = isResume ? progress.scannedBytes : 0
        
        // Set scanning state IMMEDIATELY
        isScanning = true
        lastError = nil
        scanStartTime = Date()
        
        // Only reset progress for fresh scans
        if !isResume {
            progress = ScanProgress(phase: .preparing)
            let initialBuckets = StorageCategory.allCases.map { StorageBucket(category: $0, bytes: 0) }
            summary = StorageSummary(buckets: initialBuckets)
            filesByCategory = [:]
        } else {
            // For resume, update phase but keep counts
            progress = ScanProgress(
                scannedFiles: progress.scannedFiles,
                scannedBytes: progress.scannedBytes,
                currentPath: "Resuming scan...",
                phase: .preparing
            )
        }
        
        // Create cancellation token
        let token = CancellationToken()
        self.cancellationToken = token
        
        // Capture settings for background task
        let includeHidden = settings.includeHidden
        let excludedPaths = settings.excludedPaths
        
        // Start periodic save task (saves every 60 seconds during scan)
        periodicSaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
                guard let self = self, !Task.isCancelled, self.isScanning else { break }
                await MainActor.run {
                    if self.summary.totalBytes > 0 {
                        self.saveCurrentProgress()
                    }
                }
            }
        }
        
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
                        progress: { [weak self] update in
                            // Update progress AND summary on main actor
                            Task { @MainActor in
                                guard let self = self, !token.isCancelled else { return }
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
                        },
                        initialBuckets: resumeInitialBuckets,
                        initialFiles: resumeInitialFiles,
                        initialScannedFiles: resumeScannedFiles,
                        initialScannedBytes: resumeScannedBytes
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
            
            // Cancel periodic save task
            self.periodicSaveTask?.cancel()
            self.periodicSaveTask = nil
            
            // Final update on main actor
            await MainActor.run {
                switch result {
                case .success(let scanResult):
                    self.summary = StorageSummary(buckets: scanResult.buckets)
                    self.filesByCategory = scanResult.filesByCategory
                    self.lastScanDate = Date()
                    self.scanState = .complete  // Mark as complete scan
                    self.progress = ScanProgress(
                        scannedFiles: self.progress.scannedFiles,
                        scannedBytes: self.progress.scannedBytes,
                        currentPath: "",
                        phase: .complete
                    )
                    
                    // Save final result to cache
                    self.saveCurrentProgress()
                    
                case .failure(let error):
                    if case FileIndexerError.cancelled = error {
                        // Don't set error for cancellation - progress already saved in cancelScan()
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
        
        // Cancel the tasks
        scanTask?.cancel()
        scanTask = nil
        periodicSaveTask?.cancel()
        periodicSaveTask = nil
        
        // Mark as partial scan
        scanState = .partial
        
        // Save current progress before stopping
        if summary.totalBytes > 0 {
            saveCurrentProgress()
        }
        
        // Update state
        isScanning = false
        progress = ScanProgress(
            scannedFiles: progress.scannedFiles,
            scannedBytes: progress.scannedBytes,
            currentPath: "",
            phase: .complete
        )
    }
    
    // MARK: - Save Current Progress
    
    func saveCurrentProgress() {
        let summaryToSave = self.summary
        let filesToSave = self.filesByCategory
        let progressToSave = self.progress
        let scanDuration = self.scanStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let currentScanState = self.scanState
        
        // Update last scan date for partial saves too
        self.lastScanDate = Date()
        
        Task.detached(priority: .background) {
            do {
                try await ScanDataStore.shared.save(
                    summary: summaryToSave,
                    filesByCategory: filesToSave,
                    progress: progressToSave,
                    scanDuration: scanDuration,
                    scanState: currentScanState
                )
            } catch {
                print("Failed to save current progress: \(error)")
            }
        }
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
