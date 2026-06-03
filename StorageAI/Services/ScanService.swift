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
    @Published private(set) var fileCounts: [StorageCategory: Int] = [:]
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
    
    // Time estimation properties
    private var performanceHistory: ScanDataStore.ScanPerformanceHistory?
    private var pausedDuration: TimeInterval = 0
    private var lastPauseTime: Date?
    private var totalExpectedBytes: Int64 = 0
    private var resumeElapsedTime: TimeInterval = 0  // Time elapsed before pause for resume
    
    private let periodicSaveInterval: TimeInterval = 60 // Save every 60 seconds
    private let defaultScanSpeed: Double = 50_000_000  // 50 MB/s default estimate
    
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

        // Load cache and performance history immediately on init
        Task { @MainActor in
            await self.loadCachedData()
            await self.loadPerformanceHistory()
        }
    }
    
    // MARK: - Performance History
    
    private func loadPerformanceHistory() async {
        performanceHistory = await ScanDataStore.shared.loadPerformanceHistory()
    }
    
    private func savePerformanceHistory(totalBytes: Int64, durationSeconds: Double) {
        Task.detached(priority: .background) {
            var history = await ScanDataStore.shared.loadPerformanceHistory()
            history.recordScan(bytesScanned: totalBytes, durationSeconds: durationSeconds)
            try? await ScanDataStore.shared.savePerformanceHistory(history)
        }
    }
    
    // MARK: - Time Estimation
    
    private func calculateEstimatedTimeRemaining(
        scannedBytes: Int64,
        elapsedSeconds: TimeInterval
    ) -> TimeInterval? {
        // Need some data to estimate
        guard scannedBytes > 0, elapsedSeconds > 1 else { return nil }
        
        // Calculate current scan speed
        let currentSpeed = Double(scannedBytes) / elapsedSeconds
        guard currentSpeed > 0 else { return nil }
        
        // Blend with historical data if available
        let effectiveSpeed: Double
        if let history = performanceHistory, history.completedScans > 0 {
            // 70% historical, 30% current - gives stability while adapting
            effectiveSpeed = (history.averageBytesPerSecond * 0.7) + (currentSpeed * 0.3)
        } else {
            // First scan - use current speed with some smoothing toward default
            effectiveSpeed = (defaultScanSpeed * 0.3) + (currentSpeed * 0.7)
        }
        
        // Estimate remaining bytes
        let remainingBytes = max(0, totalExpectedBytes - scannedBytes)
        
        // Calculate time remaining
        let timeRemaining = Double(remainingBytes) / effectiveSpeed
        
        // Sanity check - cap at 24 hours
        return min(timeRemaining, 24 * 3600)
    }
    
    private func getInitialTimeEstimate() -> TimeInterval? {
        guard totalExpectedBytes > 0 else { return nil }
        
        let estimatedSpeed: Double
        if let history = performanceHistory, history.completedScans > 0 {
            estimatedSpeed = history.averageBytesPerSecond
        } else {
            estimatedSpeed = defaultScanSpeed
        }
        
        return Double(totalExpectedBytes) / estimatedSpeed
    }
    
    private func getEffectiveElapsedTime() -> TimeInterval {
        guard let startTime = scanStartTime else { return 0 }
        let totalElapsed = Date().timeIntervalSince(startTime)
        return totalElapsed - pausedDuration + resumeElapsedTime
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
                self.fileCounts = cached.fileCounts
                self.lastScanDate = cached.metadata.lastScanDate
                self.progress = ScanProgress(
                    scannedFiles: cached.metadata.totalFilesScanned,
                    scannedBytes: cached.metadata.totalBytesScanned,
                    currentPath: "",
                    phase: .complete,
                    estimatedSecondsRemaining: nil,
                    elapsedSeconds: cached.metadata.scanDurationSeconds
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
        
        // Register task with resource monitor
        ResourceMonitor.shared.registerTask(name: "Scan")
        
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
        
        // Reset pause tracking
        pausedDuration = 0
        lastPauseTime = nil
        
        // Calculate total expected bytes (disk used space as estimate)
        totalExpectedBytes = summary.diskInfo.usedSpace
        
        // Handle resume elapsed time
        if isResume {
            // Preserve the elapsed time from before pause
            resumeElapsedTime = progress.elapsedSeconds
        } else {
            resumeElapsedTime = 0
        }
        
        // Get initial time estimate
        let initialEstimate = getInitialTimeEstimate()
        
        // Only reset progress for fresh scans
        if !isResume {
            progress = ScanProgress(
                phase: .preparing,
                estimatedSecondsRemaining: initialEstimate,
                elapsedSeconds: 0
            )
            let initialBuckets = StorageCategory.allCases.map { StorageBucket(category: $0, bytes: 0) }
            summary = StorageSummary(buckets: initialBuckets)
            filesByCategory = [:]
        } else {
            // For resume, update phase but keep counts
            progress = ScanProgress(
                scannedFiles: progress.scannedFiles,
                scannedBytes: progress.scannedBytes,
                currentPath: "Resuming scan...",
                phase: .preparing,
                estimatedSecondsRemaining: initialEstimate,
                elapsedSeconds: resumeElapsedTime
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
            
            // Track last UI update to throttle updates and reduce memory pressure
            // Use actor-isolated state to avoid creating Tasks for each update
            let progressActor = ProgressThrottler(minInterval: 1.0)
            
            // Run the scan on a background thread with lower priority for efficiency
            let result: Result<ScanResult, Error> = await Task.detached(priority: .utility) { [weak self] in
                do {
                    let scanResult = try await FileIndexer.scan(
                        roots: roots,
                        includeHidden: includeHidden,
                        excludedPaths: excludedPaths,
                        cancellationToken: token,
                        progress: { update in
                            // Use fire-and-forget dispatch instead of Task to avoid accumulation
                            // Only update if enough time has passed (throttling)
                            guard progressActor.shouldUpdate() else { return }
                            guard !token.isCancelled else { return }
                            
                            // Dispatch to main thread without creating a Task
                            DispatchQueue.main.async { [weak self] in
                                // Ignore stale ticks: only apply if this is still the active scan's
                                // token AND a scan is in progress. Otherwise a tick enqueued just
                                // before completion/cancel could overwrite final results or
                                // resurrect a cancelled scan's partial UI.
                                guard let self = self,
                                      !token.isCancelled,
                                      self.cancellationToken === token,
                                      self.isScanning else { return }

                                // Calculate elapsed time and estimate
                                let elapsed = self.getEffectiveElapsedTime()
                                let estimate = self.calculateEstimatedTimeRemaining(
                                    scannedBytes: update.scannedBytes,
                                    elapsedSeconds: elapsed
                                )
                                
                                self.progress = ScanProgress(
                                    scannedFiles: update.scannedFiles,
                                    scannedBytes: update.scannedBytes,
                                    currentPath: update.currentPath,
                                    phase: update.phase,
                                    estimatedSecondsRemaining: estimate,
                                    elapsedSeconds: elapsed
                                )
                                
                                // Update summary buckets in real-time
                                let bucketList = StorageCategory.allCases.map { 
                                    StorageBucket(category: $0, bytes: update.buckets[$0, default: 0]) 
                                }
                                self.summary = StorageSummary(buckets: bucketList)
                                
                                // Update file counts in real-time
                                self.fileCounts = update.fileCounts
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
                    ResourceMonitor.shared.unregisterTask(name: "Scan")
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
                    // Update file counts from actual scan results
                    self.fileCounts = scanResult.fileCounts
                    self.lastScanDate = Date()
                    self.scanState = .complete  // Mark as complete scan
                    
                    // Calculate final elapsed time
                    let finalElapsed = self.getEffectiveElapsedTime()
                    
                    self.progress = ScanProgress(
                        scannedFiles: self.progress.scannedFiles,
                        scannedBytes: self.progress.scannedBytes,
                        currentPath: "",
                        phase: .complete,
                        estimatedSecondsRemaining: 0,
                        elapsedSeconds: finalElapsed
                    )
                    
                    // Save performance history for future estimates
                    self.savePerformanceHistory(
                        totalBytes: self.progress.scannedBytes,
                        durationSeconds: finalElapsed
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
                ResourceMonitor.shared.unregisterTask(name: "Scan")
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
        
        // Unregister task from resource monitor
        ResourceMonitor.shared.unregisterTask(name: "Scan")
        
        // Mark as partial scan
        scanState = .partial
        
        // Calculate elapsed time to preserve for resume
        let elapsedTime = getEffectiveElapsedTime()
        
        // Save current progress before stopping
        if summary.totalBytes > 0 {
            saveCurrentProgress()
        }
        
        // Update state - preserve elapsed time for resume
        isScanning = false
        progress = ScanProgress(
            scannedFiles: progress.scannedFiles,
            scannedBytes: progress.scannedBytes,
            currentPath: "",
            phase: .complete,
            estimatedSecondsRemaining: nil,
            elapsedSeconds: elapsedTime
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
            phase: progress.phase,
            estimatedSecondsRemaining: progress.estimatedSecondsRemaining,
            elapsedSeconds: progress.elapsedSeconds
        )
    }
    
    func refreshDiskInfo() {
        summary = StorageSummary(buckets: summary.buckets, diskInfo: .current)
    }
    
    func clearCache() async {
        await ScanDataStore.shared.clear()
    }
    
    /// Clears scan results from memory to free up RAM
    /// Call this when navigating away from views that need scan data
    func clearInMemoryResults() {
        filesByCategory = [:]
        fileCounts = [:]
    }
    
    /// Full reset - clears both memory and disk cache
    func fullReset() async {
        clearInMemoryResults()
        let initialBuckets = StorageCategory.allCases.map { StorageBucket(category: $0, bytes: 0) }
        summary = StorageSummary(buckets: initialBuckets)
        progress = ScanProgress()
        lastScanDate = nil
        scanState = .neverScanned
        await ScanDataStore.shared.clear()
    }
}

// MARK: - Progress Throttler

/// Thread-safe throttler to limit progress updates without creating Tasks
final class ProgressThrottler: @unchecked Sendable {
    private var lastUpdate: Date
    private let minInterval: TimeInterval
    private let lock = NSLock()
    
    init(minInterval: TimeInterval) {
        self.minInterval = minInterval
        self.lastUpdate = Date.distantPast
    }
    
    func shouldUpdate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date()
        if now.timeIntervalSince(lastUpdate) >= minInterval {
            lastUpdate = now
            return true
        }
        return false
    }
}
