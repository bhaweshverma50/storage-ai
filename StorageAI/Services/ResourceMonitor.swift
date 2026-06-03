import Foundation
import Combine
import AppKit

// MARK: - Resource Monitor

/// Monitors app resource usage for developer debugging
@MainActor
final class ResourceMonitor: ObservableObject {
    static let shared = ResourceMonitor()
    
    // MARK: - Published Properties
    
    @Published private(set) var memoryUsage: MemoryUsage = .zero
    @Published private(set) var cpuUsage: Double = 0
    @Published private(set) var activeTasks: Int = 0
    @Published private(set) var cacheStats: CacheStats = .zero
    @Published private(set) var isMonitoring = false
    
    // MARK: - Private Properties
    
    private var timer: Timer?
    private var taskCounter = 0
    private var peakMemory: Int64 = 0
    private var previousCPUInfo: host_cpu_load_info?
    
    // MARK: - Types
    
    struct MemoryUsage: Equatable {
        let resident: Int64       // Physical memory (RSS)
        let virtual: Int64        // Virtual memory
        let peak: Int64           // Peak memory since monitoring started
        let compressed: Int64     // Compressed memory
        
        static let zero = MemoryUsage(resident: 0, virtual: 0, peak: 0, compressed: 0)
        
        var formattedResident: String {
            Formatters.bytes(resident)
        }
        
        var formattedVirtual: String {
            Formatters.bytes(virtual)
        }
        
        var formattedPeak: String {
            Formatters.bytes(peak)
        }
        
        var statusColor: StatusColor {
            if resident > 2_000_000_000 { return .critical }  // > 2 GB
            if resident > 500_000_000 { return .warning }     // > 500 MB
            return .normal
        }
    }
    
    struct CacheStats: Equatable {
        let thumbnailCount: Int
        let thumbnailEstimatedBytes: Int64
        let scanCacheBytes: Int64
        let mediaCacheBytes: Int64
        
        static let zero = CacheStats(thumbnailCount: 0, thumbnailEstimatedBytes: 0, scanCacheBytes: 0, mediaCacheBytes: 0)
        
        var totalBytes: Int64 {
            thumbnailEstimatedBytes + scanCacheBytes + mediaCacheBytes
        }
        
        var formattedTotal: String {
            Formatters.bytes(totalBytes)
        }
    }
    
    enum StatusColor {
        case normal
        case warning
        case critical
        
        var color: String {
            switch self {
            case .normal: return "green"
            case .warning: return "yellow"
            case .critical: return "red"
            }
        }
    }
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Monitoring Control
    
    private var monitoringTask: Task<Void, Never>?
    
    func startMonitoring(interval: TimeInterval = 2.0) {
        guard !isMonitoring else { return }
        
        isMonitoring = true
        peakMemory = 0
        
        // Initial update
        updateMetricsSync()
        
        // Start async monitoring loop instead of Timer + Task spam
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self = self else { break }
                await self.updateMetricsAsync()
            }
        }
    }
    
    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        timer?.invalidate()
        timer = nil
        isMonitoring = false
    }
    
    // MARK: - Task Tracking
    
    func registerTask(name: String = "") {
        taskCounter += 1
        activeTasks = taskCounter
    }
    
    func unregisterTask(name: String = "") {
        taskCounter = max(0, taskCounter - 1)
        activeTasks = taskCounter
    }
    
    // MARK: - Manual Refresh
    
    func refresh() {
        updateMetricsSync()
    }
    
    // MARK: - Metrics Collection
    
    /// Synchronous update - only updates memory and CPU (no Task spawning)
    private func updateMetricsSync() {
        memoryUsage = collectMemoryUsage()
        cpuUsage = collectCPUUsage()
    }
    
    /// Async update - updates all metrics including cache stats
    private func updateMetricsAsync() async {
        memoryUsage = collectMemoryUsage()
        cpuUsage = collectCPUUsage()
        cacheStats = await collectCacheStats()
    }
    
    private func collectMemoryUsage() -> MemoryUsage {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS else {
            return MemoryUsage(resident: 0, virtual: 0, peak: peakMemory, compressed: 0)
        }
        
        let resident = Int64(info.resident_size)
        let virtual = Int64(info.virtual_size)
        
        // Update peak memory
        if resident > peakMemory {
            peakMemory = resident
        }
        
        return MemoryUsage(
            resident: resident,
            virtual: virtual,
            peak: peakMemory,
            compressed: 0  // Compressed memory requires additional API calls
        )
    }
    
    private func collectCPUUsage() -> Double {
        var cpuInfo: host_cpu_load_info?
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        
        var hostInfo = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &hostInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS else {
            return 0
        }
        
        cpuInfo = hostInfo
        
        guard let current = cpuInfo, let previous = previousCPUInfo else {
            previousCPUInfo = cpuInfo
            return 0
        }
        
        // Calculate CPU usage from ticks difference
        let userDiff = Double(current.cpu_ticks.0 - previous.cpu_ticks.0)
        let systemDiff = Double(current.cpu_ticks.1 - previous.cpu_ticks.1)
        let idleDiff = Double(current.cpu_ticks.2 - previous.cpu_ticks.2)
        let niceDiff = Double(current.cpu_ticks.3 - previous.cpu_ticks.3)
        
        let totalTicks = userDiff + systemDiff + idleDiff + niceDiff
        
        previousCPUInfo = cpuInfo
        
        guard totalTicks > 0 else { return 0 }
        
        let usage = ((userDiff + systemDiff + niceDiff) / totalTicks) * 100
        return min(100, max(0, usage))
    }
    
    private func collectCacheStats() async -> CacheStats {
        // Get thumbnail cache stats
        let thumbnailCount = ThumbnailCache.shared.cacheCount
        let thumbnailBytes = ThumbnailCache.shared.estimatedCacheBytes
        
        // Get scan data cache size
        let scanCacheBytes = await getCacheFileSize(name: "scan_data.json")
        let mediaCacheBytes = await getCacheFileSize(name: "media_analysis.json")
        
        return CacheStats(
            thumbnailCount: thumbnailCount,
            thumbnailEstimatedBytes: thumbnailBytes,
            scanCacheBytes: scanCacheBytes,
            mediaCacheBytes: mediaCacheBytes
        )
    }
    
    private func getCacheFileSize(name: String) async -> Int64 {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.storageai.app")
        
        guard let cacheDir = cacheDir else { return 0 }
        
        let fileURL = cacheDir.appendingPathComponent(name)
        
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            return attrs[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
    
    // MARK: - Utilities
    
    func copyStatsToClipboard() {
        let stats = """
        Storage AI Resource Monitor
        ==========================
        Memory (Resident): \(memoryUsage.formattedResident)
        Memory (Virtual): \(memoryUsage.formattedVirtual)
        Memory (Peak): \(memoryUsage.formattedPeak)
        CPU Usage: \(String(format: "%.1f%%", cpuUsage))
        Active Tasks: \(activeTasks)
        Thumbnail Cache: \(cacheStats.thumbnailCount) items (~\(Formatters.bytes(cacheStats.thumbnailEstimatedBytes)))
        Scan Cache: \(Formatters.bytes(cacheStats.scanCacheBytes))
        Media Cache: \(Formatters.bytes(cacheStats.mediaCacheBytes))
        Total Cache: \(cacheStats.formattedTotal)
        """
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(stats, forType: .string)
    }
    
    func clearAllCaches() async {
        ThumbnailCache.shared.clearCache()
        await ScanDataStore.shared.clear()
        await ScanDataStore.shared.clearMediaAnalysis()
        
        // Refresh stats
        cacheStats = await collectCacheStats()
    }
    
    var cpuStatusColor: StatusColor {
        if cpuUsage > 80 { return .critical }
        if cpuUsage > 50 { return .warning }
        return .normal
    }
    
    var taskStatusColor: StatusColor {
        if activeTasks > 3 { return .critical }
        if activeTasks > 0 { return .warning }
        return .normal
    }
}

// MARK: - ThumbnailCache Extension for Stats

extension ThumbnailCache {
    /// Approximate count of cached items (tracked via insert/clear/eviction, not fabricated).
    var cacheCount: Int {
        approximateCount
    }

    /// Estimated bytes used by the thumbnail cache (~57 KB per 120×120 RGBA thumbnail).
    var estimatedCacheBytes: Int64 {
        Int64(approximateCount) * 57_000
    }
}
