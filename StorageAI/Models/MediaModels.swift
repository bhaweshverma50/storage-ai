import Foundation
import SwiftUI

// MARK: - Media Type

enum MediaType: String, CaseIterable, Identifiable, Codable {
    case photo
    case video
    case screenshot
    case livePhoto
    case raw
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .photo: return "Photo"
        case .video: return "Video"
        case .screenshot: return "Screenshot"
        case .livePhoto: return "Live Photo"
        case .raw: return "RAW"
        }
    }
    
    var icon: String {
        switch self {
        case .photo: return "photo"
        case .video: return "video"
        case .screenshot: return "camera.viewfinder"
        case .livePhoto: return "livephoto"
        case .raw: return "camera.aperture"
        }
    }
    
    var color: Color {
        switch self {
        case .photo: return .blue
        case .video: return .purple
        case .screenshot: return .orange
        case .livePhoto: return .pink
        case .raw: return .green
        }
    }
}

// MARK: - Media Subcategory

enum MediaSubcategory: String, CaseIterable, Identifiable, Codable {
    case screenshots
    case duplicates
    case blurry
    case largeFiles
    case oldMedia
    case recentMedia
    case similarPhotos
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .screenshots: return "Screenshots"
        case .duplicates: return "Duplicates"
        case .blurry: return "Potentially Blurry"
        case .largeFiles: return "Large Files"
        case .oldMedia: return "Old Media"
        case .recentMedia: return "Recent"
        case .similarPhotos: return "Similar Photos"
        }
    }
    
    var icon: String {
        switch self {
        case .screenshots: return "camera.viewfinder"
        case .duplicates: return "doc.on.doc"
        case .blurry: return "aqi.medium"
        case .largeFiles: return "externaldrive"
        case .oldMedia: return "clock.arrow.circlepath"
        case .recentMedia: return "clock"
        case .similarPhotos: return "square.stack.3d.up"
        }
    }
    
    var color: Color {
        switch self {
        case .screenshots: return .orange
        case .duplicates: return .red
        case .blurry: return .yellow
        case .largeFiles: return .purple
        case .oldMedia: return .gray
        case .recentMedia: return .green
        case .similarPhotos: return .cyan
        }
    }
}

// MARK: - Media Filter

enum MediaFilter: String, CaseIterable, Identifiable {
    case all
    case photos
    case videos
    case screenshots
    case large
    case old
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .all: return "All"
        case .photos: return "Photos"
        case .videos: return "Videos"
        case .screenshots: return "Screenshots"
        case .large: return "Large"
        case .old: return "Old"
        }
    }
    
    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .photos: return "photo"
        case .videos: return "video"
        case .screenshots: return "camera.viewfinder"
        case .large: return "externaldrive"
        case .old: return "clock.arrow.circlepath"
        }
    }
}

// MARK: - View Mode

enum MediaViewMode: String, CaseIterable, Identifiable {
    case grid
    case list
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

// MARK: - Grid Size

enum MediaGridSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
    
    var cellSize: CGFloat {
        switch self {
        case .small: return 80
        case .medium: return 120
        case .large: return 180
        }
    }
    
    var columns: Int {
        switch self {
        case .small: return 8
        case .medium: return 5
        case .large: return 3
        }
    }
}

// MARK: - Compression Quality

enum CompressionQuality: String, CaseIterable, Identifiable, Codable {
    case high
    case medium
    case low
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .high: return "High Quality"
        case .medium: return "Balanced"
        case .low: return "Maximum Savings"
        }
    }
    
    var description: String {
        switch self {
        case .high: return "Best quality, less compression"
        case .medium: return "Good quality, moderate compression"
        case .low: return "Lower quality, maximum space savings"
        }
    }
    
    /// Target compression ratio (1.0 = no compression)
    var targetRatio: Double {
        switch self {
        case .high: return 0.7
        case .medium: return 0.5
        case .low: return 0.3
        }
    }
    
    /// JPEG quality for photos (0-1)
    var jpegQuality: CGFloat {
        switch self {
        case .high: return 0.85
        case .medium: return 0.65
        case .low: return 0.45
        }
    }
    
    /// Video bitrate multiplier
    var videoBitrateMultiplier: Double {
        switch self {
        case .high: return 0.75
        case .medium: return 0.5
        case .low: return 0.3
        }
    }
    
    var color: Color {
        switch self {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }
}

// MARK: - Media Item

struct MediaItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let type: MediaType
    let sizeBytes: Int64
    let dimensions: CGSize?
    let duration: TimeInterval?
    let createdAt: Date?
    let modifiedAt: Date?
    var subcategories: Set<MediaSubcategory>
    
    // Computed properties
    var fileName: String {
        url.lastPathComponent
    }
    
    var fileExtension: String {
        url.pathExtension.lowercased()
    }
    
    var isVideo: Bool {
        type == .video
    }
    
    var isPhoto: Bool {
        type == .photo || type == .screenshot || type == .livePhoto || type == .raw
    }
    
    var isLarge: Bool {
        subcategories.contains(.largeFiles)
    }
    
    var isOld: Bool {
        subcategories.contains(.oldMedia)
    }
    
    var formattedDuration: String? {
        guard let duration = duration else { return nil }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        }
        return String(format: "0:%02d", seconds)
    }
    
    var formattedDimensions: String? {
        guard let dimensions = dimensions else { return nil }
        return "\(Int(dimensions.width)) × \(Int(dimensions.height))"
    }
    
    // Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.id == rhs.id
    }
    
    // Initialize from FileEntry
    init(from fileEntry: FileEntry, type: MediaType, dimensions: CGSize? = nil, duration: TimeInterval? = nil) {
        self.id = fileEntry.id
        self.url = fileEntry.url
        self.type = type
        self.sizeBytes = fileEntry.sizeBytes
        self.dimensions = dimensions
        self.duration = duration
        self.createdAt = fileEntry.modifiedAt
        self.modifiedAt = fileEntry.modifiedAt
        self.subcategories = []
    }
    
    // Full initializer
    init(
        id: UUID = UUID(),
        url: URL,
        type: MediaType,
        sizeBytes: Int64,
        dimensions: CGSize? = nil,
        duration: TimeInterval? = nil,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        subcategories: Set<MediaSubcategory> = []
    ) {
        self.id = id
        self.url = url
        self.type = type
        self.sizeBytes = sizeBytes
        self.dimensions = dimensions
        self.duration = duration
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.subcategories = subcategories
    }
}

// MARK: - Compression Estimate

struct CompressionEstimate: Equatable {
    let originalSize: Int64
    let estimatedSize: Int64
    let quality: CompressionQuality
    let itemCount: Int
    
    var savingsBytes: Int64 {
        max(0, originalSize - estimatedSize)
    }
    
    var savingsPercent: Double {
        guard originalSize > 0 else { return 0 }
        return Double(savingsBytes) / Double(originalSize) * 100
    }
    
    var formattedOriginalSize: String {
        Formatters.bytes(originalSize)
    }
    
    var formattedEstimatedSize: String {
        Formatters.bytes(estimatedSize)
    }
    
    var formattedSavings: String {
        Formatters.bytes(savingsBytes)
    }
    
    var formattedSavingsPercent: String {
        String(format: "%.1f%%", savingsPercent)
    }
    
    static var empty: CompressionEstimate {
        CompressionEstimate(originalSize: 0, estimatedSize: 0, quality: .medium, itemCount: 0)
    }
}

// MARK: - Media Suggestion

struct MediaSuggestion: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let icon: String
    let color: Color
    let potentialSavings: Int64?
    let affectedItems: [MediaItem]
    let action: SuggestionAction
    
    enum SuggestionAction {
        case delete
        case compress
        case organize
        case review
    }
    
    var formattedSavings: String? {
        guard let savings = potentialSavings else { return nil }
        return Formatters.bytes(savings)
    }
}

// MARK: - Duplicate Group

struct DuplicateGroup: Identifiable {
    let id = UUID()
    let items: [MediaItem]
    
    var totalSize: Int64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }
    
    var potentialSavings: Int64 {
        // Keep one, delete the rest
        guard items.count > 1 else { return 0 }
        return items.dropFirst().reduce(0) { $0 + $1.sizeBytes }
    }
    
    var originalItem: MediaItem? {
        // Return the largest/oldest as the "original"
        items.max { $0.sizeBytes < $1.sizeBytes }
    }
}

// MARK: - Media Analysis Result

struct MediaAnalysisResult {
    let items: [MediaItem]
    let duplicateGroups: [DuplicateGroup]
    let suggestions: [MediaSuggestion]
    let stats: MediaStats
    
    struct MediaStats {
        let totalCount: Int
        let totalSize: Int64
        let photoCount: Int
        let videoCount: Int
        let screenshotCount: Int
        let largeFileCount: Int
        let oldMediaCount: Int
        let duplicateCount: Int
        
        var formattedTotalSize: String {
            Formatters.bytes(totalSize)
        }
    }
}

// MARK: - Media Operation State

enum MediaOperationState: Equatable {
    case idle
    case analyzing(progress: Double, currentFile: String?)
    case compressing(progress: Double, currentFile: String?)
    case deleting(progress: Double)
    case organizing(progress: Double)
    case error(String)
    
    var isActive: Bool {
        switch self {
        case .idle, .error: return false
        default: return true
        }
    }
    
    var progress: Double {
        switch self {
        case .analyzing(let p, _), .compressing(let p, _), .deleting(let p), .organizing(let p):
            return p
        default:
            return 0
        }
    }
    
    var statusText: String {
        switch self {
        case .idle: return ""
        case .analyzing(_, let file): return "Analyzing\(file.map { ": \($0)" } ?? "...")"
        case .compressing(_, let file): return "Compressing\(file.map { ": \($0)" } ?? "...")"
        case .deleting: return "Deleting..."
        case .organizing: return "Organizing..."
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

// MARK: - Sort Order

enum MediaSortOrder: String, CaseIterable, Identifiable {
    case sizeDesc = "Largest First"
    case sizeAsc = "Smallest First"
    case dateDesc = "Newest First"
    case dateAsc = "Oldest First"
    case nameAsc = "Name A-Z"
    case typeAsc = "By Type"
    
    var id: String { rawValue }
}
