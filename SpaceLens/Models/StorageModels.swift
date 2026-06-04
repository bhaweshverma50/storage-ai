import Foundation
import SwiftUI

enum StorageCategory: String, CaseIterable, Identifiable {
    case applications
    case documents
    case media
    case system
    case libraries
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .applications: return "Applications"
        case .documents: return "Documents"
        case .media: return "Media"
        case .system: return "System"
        case .libraries: return "App Data"
        case .other: return "Other"
        }
    }
    
    var icon: String {
        switch self {
        case .applications: return "square.grid.2x2"
        case .documents: return "doc.text"
        case .media: return "photo.on.rectangle"
        case .system: return "gearshape"
        case .libraries: return "archivebox"
        case .other: return "ellipsis.circle"
        }
    }
    
    var color: Color {
        switch self {
        case .applications: return .blue
        case .documents: return .orange
        case .media: return .purple
        case .system: return .gray
        case .libraries: return .cyan
        case .other: return .secondary
        }
    }
    
    var gradient: LinearGradient {
        switch self {
        case .applications: 
            return LinearGradient(colors: [.blue, .blue.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .documents: 
            return LinearGradient(colors: [.orange, .orange.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .media: 
            return LinearGradient(colors: [.purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .system: 
            return LinearGradient(colors: [.gray, .gray.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .libraries: 
            return LinearGradient(colors: [.cyan, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .other: 
            return LinearGradient(colors: [.secondary, .secondary.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

struct StorageBucket: Identifiable {
    // Identity derives from the category (the natural stable key) so SwiftUI diffs the same
    // six rows across scan-progress ticks instead of tearing them down and rebuilding
    // (which dropped animations and reset scroll/hover state every update).
    var id: StorageCategory { category }
    let category: StorageCategory
    var bytes: Int64
    
    var percentage: Double {
        0 // Will be calculated in summary
    }
}

struct DiskInfo {
    let totalSpace: Int64
    let freeSpace: Int64
    let usedSpace: Int64
    
    var usedPercentage: Double {
        guard totalSpace > 0 else { return 0 }
        return Double(usedSpace) / Double(totalSpace) * 100
    }
    
    var freePercentage: Double {
        guard totalSpace > 0 else { return 0 }
        return Double(freeSpace) / Double(totalSpace) * 100
    }
    
    static var current: DiskInfo {
        let fileManager = FileManager.default
        let homeURL = fileManager.homeDirectoryForCurrentUser
        
        do {
            let values = try homeURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            return DiskInfo(totalSpace: total, freeSpace: free, usedSpace: total - free)
        } catch {
            return DiskInfo(totalSpace: 0, freeSpace: 0, usedSpace: 0)
        }
    }
}

struct StorageSummary {
    var buckets: [StorageBucket]
    var diskInfo: DiskInfo
    
    var totalBytes: Int64 {
        buckets.reduce(0) { $0 + $1.bytes }
    }
    
    func percentage(for category: StorageCategory) -> Double {
        guard totalBytes > 0 else { return 0 }
        let bucket = buckets.first { $0.category == category }
        return Double(bucket?.bytes ?? 0) / Double(totalBytes) * 100
    }
    
    init(buckets: [StorageBucket], diskInfo: DiskInfo = .current) {
        self.buckets = buckets
        self.diskInfo = diskInfo
    }
}

struct ScanResult {
    var buckets: [StorageBucket]
    var filesByCategory: [StorageCategory: [FileEntry]]
    var fileCounts: [StorageCategory: Int]
}

struct FileEntry: Identifiable {
    let id = UUID()
    let url: URL
    let sizeBytes: Int64
    let modifiedAt: Date?
    
    var fileName: String {
        url.lastPathComponent
    }
    
    var fileExtension: String {
        url.pathExtension.lowercased()
    }
    
    var isOld: Bool {
        guard let modifiedAt else { return false }
        return Date().timeIntervalSince(modifiedAt) > 365 * 24 * 60 * 60 // 1 year
    }
}

struct AppEntry: Identifiable {
    let id = UUID()
    let name: String
    let bundleIdentifier: String?
    let bundleURL: URL
    var bundleSizeBytes: Int64
    var supportSizeBytes: Int64
    var cacheSizeBytes: Int64
    var containerSizeBytes: Int64

    var totalBytes: Int64 {
        bundleSizeBytes + supportSizeBytes + cacheSizeBytes + containerSizeBytes
    }
    
    var cleanableBytes: Int64 {
        cacheSizeBytes + containerSizeBytes
    }
    
    var iconImage: NSImage? {
        NSWorkspace.shared.icon(forFile: bundleURL.path)
    }
}

enum CleanupScope: String, CaseIterable, Identifiable {
    case safe
    case aggressive

    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .safe: return "Safe"
        case .aggressive: return "Deep Clean"
        }
    }
    
    var color: Color {
        switch self {
        case .safe: return .green
        case .aggressive: return .orange
        }
    }
    
    var icon: String {
        switch self {
        case .safe: return "checkmark.shield"
        case .aggressive: return "bolt.shield"
        }
    }
}

struct CleanupTarget: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let scope: CleanupScope
    let paths: [URL]
    var estimatedBytes: Int64
    var icon: String = "folder"
}

struct ScanProgress {
    var scannedFiles: Int
    var scannedBytes: Int64
    var currentPath: String
    var phase: ScanPhase
    var estimatedSecondsRemaining: TimeInterval?
    var elapsedSeconds: TimeInterval
    
    init(
        scannedFiles: Int = 0,
        scannedBytes: Int64 = 0,
        currentPath: String = "",
        phase: ScanPhase = .preparing,
        estimatedSecondsRemaining: TimeInterval? = nil,
        elapsedSeconds: TimeInterval = 0
    ) {
        self.scannedFiles = scannedFiles
        self.scannedBytes = scannedBytes
        self.currentPath = currentPath
        self.phase = phase
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
        self.elapsedSeconds = elapsedSeconds
    }
    
    /// Format the estimated time remaining for display
    var formattedTimeRemaining: String {
        guard let remaining = estimatedSecondsRemaining, remaining > 0 else {
            return "Calculating..."
        }
        
        if remaining < 60 {
            return "~\(Int(remaining)) sec"
        } else if remaining < 3600 {
            let minutes = Int(remaining / 60)
            return "~\(minutes) min"
        } else {
            let hours = Int(remaining / 3600)
            let minutes = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
            if minutes > 0 {
                return "~\(hours) hr \(minutes) min"
            } else {
                return "~\(hours) hr"
            }
        }
    }
}

enum ScanPhase: String {
    case preparing = "Preparing..."
    case scanningHome = "Scanning Home"
    case scanningApplications = "Scanning Applications"
    case scanningLibrary = "Scanning Library"
    case scanningSystem = "Scanning System"
    case analyzing = "Analyzing..."
    case complete = "Complete"
}
