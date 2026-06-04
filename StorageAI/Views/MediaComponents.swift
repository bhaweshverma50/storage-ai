import SwiftUI
import AppKit
import QuickLookThumbnailing

// MARK: - Thumbnail Cache

/// Global thumbnail cache for media items
final class ThumbnailCache: NSObject, NSCacheDelegate {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.storageai.thumbnailcache", qos: .userInitiated, attributes: .concurrent)

    // Real (approximate) live-item count, kept honest via insert/clear/eviction tracking so the
    // dev Resource Monitor reports actual cache occupancy rather than a fabricated constant.
    private let countLock = NSLock()
    private var liveCount = 0

    var approximateCount: Int {
        countLock.lock(); defer { countLock.unlock() }
        return liveCount
    }

    private func incrementCount() {
        countLock.lock(); liveCount += 1; countLock.unlock()
    }

    private override init() {
        super.init()
        cache.countLimit = 500
        cache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
        cache.delegate = self
    }

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        countLock.lock(); liveCount = max(0, liveCount - 1); countLock.unlock()
    }
    
    func thumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let key = "\(url.path)_\(Int(size.width))x\(Int(size.height))" as NSString
        
        // Check cache first
        if let cached = cache.object(forKey: key) {
            return cached
        }
        
        // Generate thumbnail
        let thumbnail = await generateThumbnail(for: url, size: size)
        
        if let thumbnail = thumbnail {
            cache.setObject(thumbnail, forKey: key)
            incrementCount()
        }

        return thumbnail
    }
    
    private func generateThumbnail(for url: URL, size: CGSize) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            // Use QuickLookThumbnailing only - it's memory-safe
            // DO NOT fall back to NSImage(contentsOf:) as it loads full images (50MB+ RAW files)
            // into memory, causing memory explosion with large media libraries
            if let qlThumbnail = await self.quickLookThumbnail(for: url, size: size) {
                return qlThumbnail
            }
            
            // Return nil - the UI will show a placeholder icon
            // This is safe and prevents memory issues
            return nil
        }.value
    }
    
    private func quickLookThumbnail(for url: URL, size: CGSize) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail
        )
        
        do {
            let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return thumbnail.nsImage
        } catch {
            return nil
        }
    }
    
    private func resizedImage(_ image: NSImage, to size: CGSize) -> NSImage {
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        
        newImage.unlockFocus()
        return newImage
    }
    
    func clearCache() {
        cache.removeAllObjects()
        countLock.lock(); liveCount = 0; countLock.unlock()
    }
}

// MARK: - Media Thumbnail Cell

struct MediaThumbnailCell: View {
    let item: MediaItem
    let size: CGFloat
    let isSelected: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    
    @State private var thumbnail: NSImage?
    @State private var isHovered = false
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Thumbnail
            thumbnailView
            
            // Selection indicator
            if isSelected {
                selectionOverlay
            }
            
            // Type badge
            if item.isVideo || item.type == .screenshot || item.type == .raw {
                typeBadge
            }
            
            // Hover overlay with size
            if isHovered && !isSelected {
                hoverOverlay
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
        }
        .onTapGesture(count: 2) {
            onDoubleTap()
        }
        .onTapGesture {
            onTap()
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .task {
            await loadThumbnail()
        }
    }
    
    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail = thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.1))
                .overlay {
                    Image(systemName: item.isVideo ? "video" : "photo")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                }
        }
    }
    
    private var selectionOverlay: some View {
        ZStack(alignment: .topTrailing) {
            Color.accentColor.opacity(0.2)
            
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.white, Color.accentColor)
                .padding(6)
        }
    }
    
    private var typeBadge: some View {
        HStack(spacing: 4) {
            if item.isVideo, let duration = item.formattedDuration {
                HStack(spacing: 2) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                    Text(duration)
                        .font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
            } else if item.type == .screenshot {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 10))
                    .padding(5)
                    .background(.ultraThinMaterial, in: Circle())
            } else if item.type == .raw {
                Text("RAW")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .shadow(radius: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(6)
    }
    
    private var hoverOverlay: some View {
        VStack {
            Spacer()
            Text(Formatters.bytes(item.sizeBytes))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(4)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    
    private func loadThumbnail() async {
        let thumbSize = CGSize(width: size * 2, height: size * 2)
        thumbnail = await ThumbnailCache.shared.thumbnail(for: item.url, size: thumbSize)
    }
}

// MARK: - Media List Row

struct MediaListRow: View {
    let item: MediaItem
    let isSelected: Bool
    let onTap: () -> Void
    
    @State private var thumbnail: NSImage?
    
    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            Group {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                        .overlay {
                            Image(systemName: item.isVideo ? "video" : "photo")
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName)
                    .font(.subheadline)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    // Type badge
                    HStack(spacing: 4) {
                        Image(systemName: item.type.icon)
                        Text(item.type.displayName)
                    }
                    .font(.caption2)
                    .foregroundStyle(item.type.color)
                    
                    // Dimensions or duration
                    if let dimensions = item.formattedDimensions {
                        Text(dimensions)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    
                    if let duration = item.formattedDuration {
                        Text(duration)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // Date
            if let date = item.modifiedAt {
                Text(Formatters.relativeDate(date))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            
            // Size
            Text(Formatters.bytes(item.sizeBytes))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            
            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .task {
            await loadThumbnail()
        }
    }
    
    private func loadThumbnail() async {
        let thumbSize = CGSize(width: 100, height: 100)
        thumbnail = await ThumbnailCache.shared.thumbnail(for: item.url, size: thumbSize)
    }
}

// MARK: - Media Filter Bar

struct MediaFilterBar: View {
    @Binding var selectedFilter: MediaFilter
    let stats: MediaAnalysisResult.MediaStats?
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MediaFilter.allCases) { filter in
                    FilterChipButton(
                        filter: filter,
                        count: countForFilter(filter),
                        isSelected: selectedFilter == filter
                    ) {
                        selectedFilter = filter
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }
    
    private func countForFilter(_ filter: MediaFilter) -> Int? {
        guard let stats = stats else { return nil }
        
        switch filter {
        case .all: return stats.totalCount
        case .photos: return stats.photoCount
        case .videos: return stats.videoCount
        case .screenshots: return stats.screenshotCount
        case .large: return stats.largeFileCount
        case .old: return stats.oldMediaCount
        }
    }
}

struct FilterChipButton: View {
    let filter: MediaFilter
    let count: Int?
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: filter.icon)
                    .font(.caption)
                
                Text(filter.displayName)
                    .font(.caption.weight(.medium))
                
                if let count = count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.1), in: Capsule())
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Media Toolbar

struct MediaToolbar: View {
    @Binding var viewMode: MediaViewMode
    @Binding var gridSize: MediaGridSize
    @Binding var sortOrder: MediaSortOrder
    let selectionCount: Int
    let totalCount: Int
    let selectedSize: Int64
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // Selection info
            if selectionCount > 0 {
                HStack(spacing: 8) {
                    Text("\(selectionCount) selected")
                        .font(.subheadline.weight(.medium))
                    
                    Text("(\(Formatters.bytes(selectedSize)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Button("Deselect") {
                        onDeselectAll()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            } else {
                Button("Select All") {
                    onSelectAll()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            
            Spacer()
            
            // Sort picker
            Picker("Sort", selection: $sortOrder) {
                ForEach(MediaSortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            
            // Grid size (only in grid mode)
            if viewMode == .grid {
                Picker(selection: $gridSize, label: EmptyView()) {
                    ForEach(MediaGridSize.allCases) { size in
                        Image(systemName: gridIconForSize(size))
                            .tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 100)
            }
            
            // View mode toggle
            Picker(selection: $viewMode, label: EmptyView()) {
                ForEach(MediaViewMode.allCases) { mode in
                    Image(systemName: mode.icon)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 70)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
    
    private func gridIconForSize(_ size: MediaGridSize) -> String {
        switch size {
        case .small: return "square.grid.4x3.fill"
        case .medium: return "square.grid.3x3.fill"
        case .large: return "square.grid.2x2.fill"
        }
    }
}

// MARK: - Media Action Bar

struct MediaActionBar: View {
    let selectionCount: Int
    let selectedSize: Int64
    let compressionEstimate: CompressionEstimate?
    let onCompress: () -> Void
    let onOrganize: () -> Void
    let onDelete: () -> Void
    let onReveal: () -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        HStack(spacing: 12) {
            // Compression estimate
            if let estimate = compressionEstimate, estimate.savingsBytes > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .foregroundStyle(.green)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Potential savings")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(estimate.formattedSavings)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            
            Spacer()
            
            // Actions
            Button {
                onReveal()
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .disabled(selectionCount != 1)
            
            Button {
                onOrganize()
            } label: {
                Label("Organize", systemImage: "folder.badge.gearshape")
            }
            .buttonStyle(.bordered)
            .disabled(selectionCount == 0)
            
            Button {
                onCompress()
            } label: {
                Label("Compress", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(selectionCount == 0)
            
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selectionCount == 0)
        }
        .padding(16)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Divider()
                }
        }
    }
}

// MARK: - Media Progress View

struct MediaProgressView: View {
    let state: MediaOperationState
    let onCancel: () -> Void
    
    var body: some View {
        if state.isActive {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.statusText)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        
                        ProgressView(value: state.progress)
                            .progressViewStyle(.linear)
                    }
                    
                    Button("Cancel") {
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Media Suggestion Card

struct MediaSuggestionCard: View {
    let suggestion: MediaSuggestion
    let onAction: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: suggestion.icon)
                .font(.title2)
                .foregroundStyle(suggestion.color)
                .frame(width: 40)
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.title)
                    .font(.subheadline.weight(.medium))
                
                Text(suggestion.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Potential savings
            if let savings = suggestion.formattedSavings {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(savings)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(suggestion.color)
                    Text("potential")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            // Action button
            Button {
                onAction()
            } label: {
                Text(actionText)
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(suggestion.color)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
    
    private var actionText: String {
        switch suggestion.action {
        case .delete: return "Review"
        case .compress: return "Compress"
        case .organize: return "Organize"
        case .review: return "Review"
        }
    }
}

// MARK: - Media Empty State

struct MediaEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var action: (() -> Void)?
    var actionTitle: String = "Scan Now"
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            
            if let action = action {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Media Stats Card

struct MediaStatsCard: View {
    let stats: MediaAnalysisResult.MediaStats
    
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 20) {
                StatItem(
                    title: "Total",
                    value: stats.formattedTotalSize,
                    subtitle: "\(stats.totalCount) files",
                    color: .blue
                )
                
                Divider()
                    .frame(height: 40)
                
                StatItem(
                    title: "Photos",
                    value: "\(stats.photoCount)",
                    subtitle: nil,
                    color: .green
                )
                
                StatItem(
                    title: "Videos",
                    value: "\(stats.videoCount)",
                    subtitle: nil,
                    color: .purple
                )
                
                StatItem(
                    title: "Screenshots",
                    value: "\(stats.screenshotCount)",
                    subtitle: nil,
                    color: .orange
                )
                
                if stats.duplicateCount > 0 {
                    Divider()
                        .frame(height: 40)
                    
                    StatItem(
                        title: "Duplicates",
                        value: "\(stats.duplicateCount)",
                        subtitle: "found",
                        color: .red
                    )
                }
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            
            Spacer()
        }
    }
}

struct StatItem: View {
    let title: String
    let value: String
    let subtitle: String?
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
            
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// Note: StatBentoCard is defined in CleanupView.swift
