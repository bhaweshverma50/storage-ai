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
    /// Non-fatal advisory shown when a scan likely under-reported due to missing Full Disk Access.
    @Published private(set) var accessWarning: String?
    /// Non-fatal advisory shown when scan progress stops advancing (e.g. blocked on a
    /// permission prompt or an unusually slow subtree) instead of silently looking frozen.
    @Published private(set) var stallWarning: String?
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var hasLoadedCache = false
    @Published private(set) var isLoadingCache = true
    @Published private(set) var scanState: ScanState = .neverScanned

    private var scanTask: Task<Void, Never>?
    private var periodicSaveTask: Task<Void, Never>?
    private var cacheLoadTask: Task<Void, Never>?
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

        // Load cache and performance history immediately on init. Kept as a task others can
        // await (see awaitCacheLoad) instead of being polled.
        cacheLoadTask = Task { @MainActor in
            await self.loadCachedData()
            await self.loadPerformanceHistory()
        }
    }

    /// Await the initial cache load that kicks off in init (used instead of polling isLoadingCache).
    func awaitCacheLoad() async {
        await cacheLoadTask?.value
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
            Log.cache.error("Failed to load cached scan data: \(error.localizedDescription, privacy: .public)")
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
        
        // Check if this is a resume BEFORE any state changes.
        // NOTE: "resume" re-enumerates every root from scratch (FileIndexer has no frontier
        // bookmark), so previous totals must NOT be seeded into the aggregator — that added
        // the whole tree on top of the partial counts, roughly doubling usage after every
        // resume (and compounding further on each repeat). Nothing carries over — bytes,
        // files and elapsed time are all recounted from zero. `isResume` now only picks the
        // status label.
        let isResume = scanState == .partial && summary.totalBytes > 0

        // Set scanning state IMMEDIATELY
        isScanning = true
        lastError = nil
        accessWarning = nil
        stallWarning = nil
        scanStartTime = Date()
        
        // Reset pause tracking
        pausedDuration = 0
        lastPauseTime = nil
        
        // Calculate total expected bytes (disk used space as estimate)
        totalExpectedBytes = summary.diskInfo.usedSpace
        
        // A resume re-enumerates everything (see note above), so the previous partial's
        // elapsed time must NOT carry over either. Pairing recounted-from-zero bytes with
        // stale elapsed understates throughput, and that figure is written into the
        // persisted performance history — inflating the ETA of every future scan.
        resumeElapsedTime = 0

        // Get initial time estimate
        let initialEstimate = getInitialTimeEstimate()

        // Counters restart in both cases; only the status label differs.
        progress = ScanProgress(
            currentPath: isResume ? "Restarting scan..." : "",
            phase: .preparing,
            estimatedSecondsRemaining: initialEstimate,
            elapsedSeconds: 0
        )
        let initialBuckets = StorageCategory.allCases.map { StorageBucket(category: $0, bytes: 0) }
        summary = StorageSummary(buckets: initialBuckets)
        filesByCategory = [:]
        fileCounts = [:]
        
        // Create cancellation token
        let token = CancellationToken()
        self.cancellationToken = token
        
        // Capture settings for background task
        let includeHidden = settings.includeHidden
        let excludedPaths = settings.excludedPaths
        
        // Periodic save (every 60s) + stall watchdog. The watchdog surfaces an advisory when
        // file counts stop advancing for ~2 minutes — usually a pending TCC permission prompt
        // or an unusually slow subtree — instead of leaving the UI silently frozen.
        periodicSaveTask = Task { [weak self] in
            var lastSeenFiles = -1
            var stalledChecks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
                guard let self = self, !Task.isCancelled, self.isScanning else { break }
                await MainActor.run {
                    if self.summary.totalBytes > 0 {
                        self.saveCurrentProgress()
                    }
                }

                // Stall detection
                let currentFiles = await MainActor.run { self.progress.scannedFiles }
                if !Task.isCancelled, currentFiles == lastSeenFiles {
                    stalledChecks += 1
                    if stalledChecks == 2 {
                        let path = await MainActor.run { self.progress.currentPath }
                        await MainActor.run {
                            self.stallWarning = "Scan hasn't made progress for a few minutes\(path.isEmpty ? "" : " (near \(path))"). A folder-permission prompt may be waiting, or this location is very slow."
                        }
                    }
                } else {
                    stalledChecks = 0
                    await MainActor.run {
                        if self.stallWarning != nil { self.stallWarning = nil }
                    }
                }
                lastSeenFiles = currentFiles
            }
        }
        
        // Start background scan
        scanTask = Task { [weak self] in
            guard let self = self else { return }
            
            // Track last UI update to throttle updates and reduce memory pressure
            // Use actor-isolated state to avoid creating Tasks for each update
            let progressActor = ProgressThrottler(minInterval: 1.0)
            // Orders progress ticks so out-of-order main-actor hops can't regress the UI.
            let tickSequencer = ProgressTickSequencer()
            
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

                            // Hop to the main actor without bypassing isolation: mutating
                            // @Published state from a non-isolated closure via
                            // DispatchQueue.main.async breaks under strict concurrency.
                            // Independent Tasks don't guarantee FIFO like DispatchQueue did,
                            // so each tick carries a sequence number and stale (older) ticks
                            // are dropped at apply time — otherwise progress can jump
                            // backward or appear frozen on an old value.
                            guard let service = self else { return }
                            let seq = tickSequencer.next()
                            Task { @MainActor in
                                guard !token.isCancelled,
                                      service.cancellationToken === token,
                                      service.isScanning else { return }
                                guard tickSequencer.accept(seq) else { return }

                                // Calculate elapsed time and estimate
                                let elapsed = service.getEffectiveElapsedTime()
                                let estimate = service.calculateEstimatedTimeRemaining(
                                    scannedBytes: update.scannedBytes,
                                    elapsedSeconds: elapsed
                                )

                                service.progress = ScanProgress(
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
                                service.summary = StorageSummary(buckets: bucketList)

                                // Update file counts in real-time
                                service.fileCounts = update.fileCounts

                                // Stream the live top-files snapshot so category drill-down works
                                // DURING the scan and survives cancellation/interruption (partial
                                // saves persist it). Guarded so a sparse early snapshot never
                                // wipes richer data already on screen (e.g. right after resume).
                                if !update.topFiles.isEmpty {
                                    service.filesByCategory = update.topFiles
                                }
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
                    self.stallWarning = nil
                    ResourceMonitor.shared.unregisterTask(name: "Scan")
                }
                return
            }
            
            // Cancel periodic save task
            self.periodicSaveTask?.cancel()
            self.periodicSaveTask = nil
            
            // Final update on main actor
            await MainActor.run {
                self.stallWarning = nil
                switch result {
                case .success(let scanResult):
                    self.summary = StorageSummary(buckets: scanResult.buckets)
                    self.filesByCategory = scanResult.filesByCategory
                    // Update file counts from actual scan results
                    self.fileCounts = scanResult.fileCounts
                    self.lastScanDate = Date()
                    self.scanState = .complete  // Mark as complete scan

                    // Without Full Disk Access the enumerator silently yields nothing for
                    // protected areas, so surface an actionable advisory instead of just
                    // showing an inexplicably small total.
                    if !PermissionsChecker.hasFullDiskAccess() {
                        self.accessWarning = "Full Disk Access isn't granted, so some files may be missing from this scan. Grant it in System Settings ▸ Privacy & Security ▸ Full Disk Access for complete results."
                    }

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
        stallWarning = nil
        
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
    
    /// - Parameter isScanActivity: `true` for saves that belong to an actual scan (start,
    ///   periodic, finish, cancel) — these stamp "now" as the scan date and record the live
    ///   scan duration. `false` when merely re-persisting an existing snapshot after a
    ///   deletion: that must not claim a scan just ran, or the UI reports "scanned just now"
    ///   and the next launch restores a duration that includes every idle hour since
    ///   `scanStartTime`.
    func saveCurrentProgress(isScanActivity: Bool = true) {
        let summaryToSave = self.summary
        let filesToSave = self.filesByCategory
        let countsToSave = self.fileCounts
        let progressToSave = self.progress
        let currentScanState = self.scanState

        let scanDate: Date
        let scanDuration: TimeInterval
        if isScanActivity {
            scanDate = Date()
            scanDuration = self.scanStartTime.map { Date().timeIntervalSince($0) } ?? 0
            self.lastScanDate = scanDate
        } else {
            scanDate = self.lastScanDate ?? Date()
            scanDuration = self.progress.elapsedSeconds
        }

        Task.detached(priority: .background) {
            do {
                try await ScanDataStore.shared.save(
                    summary: summaryToSave,
                    filesByCategory: filesToSave,
                    fileCounts: countsToSave,
                    progress: progressToSave,
                    scanDuration: scanDuration,
                    scanState: currentScanState,
                    scanDate: scanDate
                )
            } catch {
                Log.cache.error("Failed to save current progress: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func removeEntries(category: StorageCategory, ids: Set<UUID>) {
        guard var entries = filesByCategory[category] else { return }
        let removed = entries.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        filesByCategory[category] = entries

        let removedBytes = removed.reduce(0) { $0 + $1.sizeBytes }
        summary = StorageSummary(
            buckets: summary.buckets.map { bucket in
                guard bucket.category == category else { return bucket }
                return StorageBucket(category: bucket.category, bytes: max(0, bucket.bytes - removedBytes))
            },
            diskInfo: .current
        )

        // Keep per-category counts honest too — the Categories cards read from fileCounts,
        // so leaving it stale made deleted files keep being counted after removal.
        fileCounts[category] = max(0, (fileCounts[category] ?? 0) - removed.count)

        progress = ScanProgress(
            scannedFiles: max(0, progress.scannedFiles - removed.count),
            scannedBytes: max(0, progress.scannedBytes - removedBytes),
            currentPath: progress.currentPath,
            phase: progress.phase,
            estimatedSecondsRemaining: progress.estimatedSecondsRemaining,
            elapsedSeconds: progress.elapsedSeconds
        )

        persistSnapshotIfNeeded()
    }

    /// Reflect items moved to Trash by any delete surface (Cleanup tab, category sheet, app
    /// cleanup, media viewer) in the scanned totals, top-file lists, counts, and the persisted
    /// cache. Without this the Overview chart, category cards, and next-launch numbers kept
    /// reporting pre-cleanup sizes.
    func applyCleanup(trashed: [URL], freedBytes: Int64) {
        guard !trashed.isEmpty else { return }

        let removedPaths = Set(trashed.map { $0.standardizedFileURL.path })

        // Paths that already have tracked FileEntries — anything else was never itemized.
        let trackedPaths = Set(filesByCategory.values.flatMap { entries in
            entries.map { $0.url.standardizedFileURL.path }
        })

        // 1) Exact removals from the tracked top-files lists.
        var removedBytesByCategory: [StorageCategory: Int64] = [:]
        var removedCountByCategory: [StorageCategory: Int] = [:]
        var newFilesByCategory = filesByCategory
        for (category, entries) in filesByCategory {
            let removed = entries.filter { removedPaths.contains($0.url.standardizedFileURL.path) }
            guard !removed.isEmpty else { continue }
            removedBytesByCategory[category, default: 0] += removed.reduce(0) { $0 + $1.sizeBytes }
            removedCountByCategory[category, default: 0] += removed.count
            newFilesByCategory[category] = entries.filter { !removedPaths.contains($0.url.standardizedFileURL.path) }
        }
        filesByCategory = newFilesByCategory

        // 2) Whole-folder targets (Caches, Logs, Trash…) aren't itemized in the top-files
        //    lists. Attribute their freed bytes to the categories the trashed paths belong
        //    to so buckets still move instead of staying frozen at pre-cleanup figures.
        let knownBytes = removedBytesByCategory.values.reduce(0, +)
        let unaccountedBytes = max(0, freedBytes - knownBytes)
        let untrackedURLs = trashed.filter { !trackedPaths.contains($0.standardizedFileURL.path) }
        if unaccountedBytes > 0, !untrackedURLs.isEmpty {
            // One classifier for the whole loop: its init builds two Sets and eight string
            // concats, and a Caches clear can hand us thousands of URLs.
            let classifier = StorageClassifier()
            let share = unaccountedBytes / Int64(untrackedURLs.count)
            // Hand the integer-division remainder to the last URL so the distributed total
            // is exactly `unaccountedBytes` and buckets stay consistent with `scannedBytes`.
            let remainder = unaccountedBytes - share * Int64(untrackedURLs.count)
            for (index, url) in untrackedURLs.enumerated() {
                let category = classifier.classify(url: url)
                let bytes = share + (index == untrackedURLs.count - 1 ? remainder : 0)
                removedBytesByCategory[category, default: 0] += bytes
                // Count each untracked entry as one removal so the file count moves with the
                // byte total instead of the two drifting apart.
                // ponytail: a folder-clear reports only its top-level children, so this is a
                // floor, not the true recursive count — the files are already in the Trash by
                // now, so there's nothing left to walk. The next scan makes it exact.
                removedCountByCategory[category, default: 0] += 1
            }
        }

        summary = StorageSummary(
            buckets: summary.buckets.map { bucket in
                let delta = removedBytesByCategory[bucket.category] ?? 0
                guard delta > 0 else { return bucket }
                return StorageBucket(category: bucket.category, bytes: max(0, bucket.bytes - delta))
            },
            diskInfo: .current
        )

        let removedFileCount = removedCountByCategory.values.reduce(0, +)
        if removedFileCount > 0 {
            fileCounts = Dictionary(uniqueKeysWithValues: fileCounts.map { category, count in
                (category, max(0, count - (removedCountByCategory[category] ?? 0)))
            })
        }

        progress = ScanProgress(
            scannedFiles: max(0, progress.scannedFiles - removedFileCount),
            scannedBytes: max(0, progress.scannedBytes - freedBytes),
            currentPath: progress.currentPath,
            phase: progress.phase,
            estimatedSecondsRemaining: progress.estimatedSecondsRemaining,
            elapsedSeconds: progress.elapsedSeconds
        )

        persistSnapshotIfNeeded()
    }

    /// Persist current state so deletions survive relaunch. Skipped mid-scan — a background
    /// save here would race with the live scan's own periodic saves.
    private func persistSnapshotIfNeeded() {
        guard !isScanning else { return }
        saveCurrentProgress(isScanActivity: false)
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
        self.lastUpdate = .distantPast
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

/// Hands out monotonically increasing sequence numbers and accepts them for application
/// exactly in issue order. `Task { @MainActor }` hops don't run FIFO (unlike
/// DispatchQueue.main.async), so without this an older tick scheduled later could overwrite
/// a newer one and make progress jump backward or stick.
final class ProgressTickSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var issued = 0
    private var applied = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        issued += 1
        return issued
    }

    /// Returns false for ticks older than the most recently applied one.
    func accept(_ sequence: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sequence > applied else { return false }
        applied = sequence
        return true
    }
}
