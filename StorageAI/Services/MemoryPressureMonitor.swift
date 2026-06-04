import Foundation

/// Monitors system memory pressure and provides utilities to pause processing when memory is low.
/// This helps prevent memory-related crashes during intensive operations like media analysis.
final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()
    
    // MARK: - Properties
    
    private var source: DispatchSourceMemoryPressure?
    private let lock = NSLock()
    
    /// Whether the system is currently under memory pressure
    private(set) var isUnderPressure = false
    
    /// The current memory pressure level
    private(set) var pressureLevel: PressureLevel = .normal
    
    /// Callback when memory pressure changes
    var onPressureChange: ((PressureLevel) -> Void)?
    
    // MARK: - Types
    
    enum PressureLevel: Int, Comparable {
        case normal = 0
        case warning = 1
        case critical = 2
        
        static func < (lhs: PressureLevel, rhs: PressureLevel) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
        
        var description: String {
            switch self {
            case .normal: return "Normal"
            case .warning: return "Warning"
            case .critical: return "Critical"
            }
        }
    }
    
    // MARK: - Initialization
    
    private init() {}
    
    deinit {
        stop()
    }
    
    // MARK: - Monitoring Control
    
    /// Start monitoring memory pressure
    func start() {
        lock.lock()
        defer { lock.unlock() }
        
        guard source == nil else { return }
        
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal],
            queue: .global(qos: .utility)
        )
        
        source?.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            let event = self.source?.data ?? []
            
            self.lock.lock()
            
            if event.contains(.critical) {
                self.pressureLevel = .critical
                self.isUnderPressure = true
            } else if event.contains(.warning) {
                self.pressureLevel = .warning
                self.isUnderPressure = true
            } else {
                self.pressureLevel = .normal
                self.isUnderPressure = false
            }
            
            let level = self.pressureLevel
            self.lock.unlock()
            
            // Clear caches on memory pressure
            if level >= .warning {
                ThumbnailCache.shared.clearCache()
            }
            
            // Notify observers
            self.onPressureChange?(level)
        }
        
        source?.resume()
    }
    
    /// Stop monitoring memory pressure
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        
        source?.cancel()
        source = nil
    }
    
    // MARK: - Pressure Checking
    
    /// Thread-safe read of the pressure flag (the flag is mutated under `lock` in the
    /// dispatch-source handler, so all reads must take the lock too).
    private var underPressure: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isUnderPressure
    }

    /// Reset the pressure flag if the level has returned to normal (sync; takes the lock).
    private func resetPressureIfNormal() {
        lock.lock()
        defer { lock.unlock() }
        if pressureLevel == .normal {
            isUnderPressure = false
        }
    }

    /// Check and wait if under memory pressure
    /// Use this in processing loops to pause when memory is low
    func checkAndWait() async {
        while underPressure {
            // Wait 500ms before checking again
            try? await Task.sleep(nanoseconds: 500_000_000)

            // Reset pressure flag - will be set again by the dispatch source if still under pressure
            resetPressureIfNormal()
        }
    }

    /// Check if we should pause processing (non-blocking)
    func shouldPause() -> Bool {
        return underPressure
    }
    
    // MARK: - Memory Info
    
    /// Get current memory usage information
    func getCurrentMemoryUsage() -> MemoryInfo {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS else {
            return MemoryInfo(resident: 0, virtual: 0)
        }
        
        return MemoryInfo(
            resident: Int64(info.resident_size),
            virtual: Int64(info.virtual_size)
        )
    }
    
    struct MemoryInfo {
        let resident: Int64  // Physical memory used
        let virtual: Int64   // Virtual memory used
        
        var residentMB: Double {
            Double(resident) / 1_000_000
        }
        
        var formattedResident: String {
            Formatters.bytes(resident)
        }
    }
}
