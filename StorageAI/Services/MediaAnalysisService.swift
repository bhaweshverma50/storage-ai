import Foundation
import AppKit
import AVFoundation
import CoreMedia
import CoreImage

/// Service for analyzing media files, detecting types, extracting metadata, and identifying patterns
actor MediaAnalysisService {
    
    // MARK: - Constants
    
    private let largePhotoThreshold: Int64 = 10_000_000  // 10 MB
    private let largeVideoThreshold: Int64 = 100_000_000 // 100 MB
    private let oldMediaDays: Int = 365 // 1 year
    
    // Screenshot detection patterns
    private let screenshotPatterns = [
        "screenshot",
        "screen shot",
        "screen_shot",
        "capture",
        "snip"
    ]
    
    // Common screenshot resolutions (width x height)
    private let screenshotResolutions: Set<String> = [
        // iPhone resolutions
        "1170x2532", "2532x1170", // iPhone 12/13/14 Pro
        "1179x2556", "2556x1179", // iPhone 14 Pro Max
        "1284x2778", "2778x1284", // iPhone 12/13 Pro Max
        "1125x2436", "2436x1125", // iPhone X/XS/11 Pro
        "1242x2688", "2688x1242", // iPhone XS Max/11 Pro Max
        "750x1334", "1334x750",   // iPhone 6/7/8
        "1080x1920", "1920x1080", // Common
        // iPad resolutions
        "2048x2732", "2732x2048", // iPad Pro 12.9
        "1668x2388", "2388x1668", // iPad Pro 11
        "2048x1536", "1536x2048", // iPad Air
        // Mac resolutions
        "2560x1600", "1600x2560", // MacBook Pro 13
        "2880x1800", "1800x2880", // MacBook Pro 15
        "3024x1964", "1964x3024", // MacBook Pro 14
        "3456x2234", "2234x3456", // MacBook Pro 16
        "5120x2880", "2880x5120", // iMac 27 5K
        "4480x2520", "2520x4480", // iMac 24
    ]
    
    // RAW file extensions
    private let rawExtensions: Set<String> = [
        "raw", "cr2", "cr3", "nef", "arw", "orf", "rw2", "dng", "raf", "pef", "srw"
    ]
    
    // Photo extensions
    private let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp"
    ]
    
    // Video extensions
    private let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm", "3gp"
    ]
    
    // MARK: - Main Analysis Method
    
    /// Batch size for processing - balances memory usage vs overhead
    private let batchSize = 50
    
    /// Maximum concurrent operations within a batch
    private let maxConcurrent = 4
    
    /// Analyze a single file and return a MediaItem (for use in batched processing)
    /// This method is designed to be called within an autoreleasepool
    /// Marked nonisolated because it only uses local state and thread-safe operations
    private nonisolated func analyzeFileSynchronous(_ file: FileEntry) -> MediaItem? {
        // Use the combined analysis method to get type and dimensions in one CGImageSource load
        guard let analysis = analyzeImageFileNonisolated(url: file.url) else { return nil }
        
        // Note: Video duration requires async, handled separately
        // Create media item with pre-loaded dimensions
        var item = MediaItem(
            from: file,
            type: analysis.type,
            dimensions: analysis.dimensions,
            duration: nil  // Will be filled in for videos
        )
        
        // Categorize - use nonisolated version
        item.subcategories = categorizeItemNonisolated(item)
        
        return item
    }
    
    /// Process a batch of files with limited concurrency using TaskGroup
    private func processBatch(_ batch: [FileEntry]) async -> [MediaItem] {
        return await withTaskGroup(of: MediaItem?.self, returning: [MediaItem].self) { group in
            var results: [MediaItem] = []
            results.reserveCapacity(batch.count)
            var iterator = batch.makeIterator()
            
            // Seed initial tasks up to max concurrent
            for _ in 0..<min(maxConcurrent, batch.count) {
                if let file = iterator.next() {
                    group.addTask { [self] in
                        await self.analyzeFileWithDuration(file)
                    }
                }
            }

            // Process results and add new tasks (maintains max concurrency)
            for await result in group {
                if let item = result {
                    results.append(item)
                }
                // Add next task when one completes
                if let file = iterator.next() {
                    group.addTask { [self] in
                        await self.analyzeFileWithDuration(file)
                    }
                }
            }

            return results
        }
    }
    
    /// Analyze a list of file entries and convert them to MediaItems with metadata
    /// Uses batched processing with autoreleasepool to manage memory
    /// For large file counts (>1000), uses streaming to disk to minimize memory
    func analyzeMediaFiles(
        _ files: [FileEntry],
        progress: @escaping (Double, String?) -> Void
    ) async -> [MediaItem] {
        let total = files.count
        let useStreaming = total > 1000  // Stream to disk for large analyses
        
        var allItems: [MediaItem] = []
        if !useStreaming {
            allItems.reserveCapacity(files.count)
        }
        
        // Start memory pressure monitoring, and ALWAYS stop it when this analysis finishes —
        // otherwise the DispatchSource stays resumed for the process lifetime (the singleton's
        // deinit never runs) and keeps clearing the thumbnail cache on every memory event.
        MemoryPressureMonitor.shared.start()
        defer { MemoryPressureMonitor.shared.stop() }

        // Start incremental cache if streaming
        if useStreaming {
            await ScanDataStore.shared.startIncrementalMediaAnalysis()
        }
        
        // Process in batches to control memory usage
        for batchStart in stride(from: 0, to: total, by: batchSize) {
            // Check for cancellation
            if Task.isCancelled { break }
            
            // Check and wait if under memory pressure
            await MemoryPressureMonitor.shared.checkAndWait()
            
            let batchEnd = min(batchStart + batchSize, total)
            let batch = Array(files[batchStart..<batchEnd])
            
            // Report progress at batch level
            let progressValue = Double(batchStart) / Double(max(total, 1))
            let currentFile = batch.first?.fileName
            progress(progressValue, currentFile)
            
            // Process batch with TaskGroup and autoreleasepool
            let batchItems = await processBatch(batch)
            
            if useStreaming {
                // Stream to disk - don't keep in memory
                try? await ScanDataStore.shared.appendMediaItems(batchItems)
            } else {
                allItems.append(contentsOf: batchItems)
            }
            
            // Yield to allow memory to be released between batches
            await Task.yield()
        }
        
        progress(1.0, nil)
        
        // If streaming, load all items from disk at the end
        if useStreaming {
            do {
                allItems = try await ScanDataStore.shared.loadIncrementalMediaItems()
            } catch {
                print("Failed to load incremental media items: \(error)")
            }
        }
        
        return allItems
    }
    
    // MARK: - Type Detection
    
    /// Result of analyzing an image file - contains type and metadata in one load
    struct ImageAnalysisResult {
        let type: MediaType
        let dimensions: CGSize?
        let hasExifCamera: Bool
    }
    
    /// Determine the media type and extract metadata in a single pass
    /// This avoids multiple CGImageSource loads per file
    func analyzeImageFile(url: URL) -> ImageAnalysisResult? {
        return analyzeImageFileNonisolated(url: url)
    }
    
    /// Nonisolated version for use in concurrent contexts
    private nonisolated func analyzeImageFileNonisolated(url: URL) -> ImageAnalysisResult? {
        let ext = url.pathExtension.lowercased()
        let fileName = url.lastPathComponent.lowercased()
        
        // Check for RAW files first
        if rawExtensions.contains(ext) {
            // RAW files - get dimensions but skip EXIF check (we know it's a camera file)
            let dimensions = getImageDimensionsNonisolated(url: url)
            return ImageAnalysisResult(type: .raw, dimensions: dimensions, hasExifCamera: true)
        }
        
        // Check for video files
        if videoExtensions.contains(ext) {
            return ImageAnalysisResult(type: .video, dimensions: nil, hasExifCamera: false)
        }
        
        // Check for photos - load metadata once
        if photoExtensions.contains(ext) {
            // Get dimensions and EXIF data in a single CGImageSource load
            let (dimensions, hasExif) = getImageMetadataNonisolated(url: url)
            
            // Check if it's a screenshot using pre-loaded metadata
            if isScreenshotNonisolated(fileName: fileName, dimensions: dimensions, hasExifCamera: hasExif) {
                return ImageAnalysisResult(type: .screenshot, dimensions: dimensions, hasExifCamera: hasExif)
            }
            
            // Check for Live Photo (has matching .mov file)
            if isLivePhotoNonisolated(url: url) {
                return ImageAnalysisResult(type: .livePhoto, dimensions: dimensions, hasExifCamera: hasExif)
            }
            
            return ImageAnalysisResult(type: .photo, dimensions: dimensions, hasExifCamera: hasExif)
        }
        
        return nil
    }
    
    /// Legacy method for compatibility - wraps analyzeImageFile
    func determineMediaType(for url: URL) -> MediaType? {
        return analyzeImageFile(url: url)?.type
    }
    
    /// Check if a file is likely a screenshot using pre-loaded metadata
    /// This avoids redundant CGImageSource loads
    private func isScreenshot(fileName: String, dimensions: CGSize?, hasExifCamera: Bool) -> Bool {
        return isScreenshotNonisolated(fileName: fileName, dimensions: dimensions, hasExifCamera: hasExifCamera)
    }
    
    /// Nonisolated version for use in concurrent contexts
    private nonisolated func isScreenshotNonisolated(fileName: String, dimensions: CGSize?, hasExifCamera: Bool) -> Bool {
        // Check filename patterns first (no I/O needed)
        for pattern in screenshotPatterns {
            if fileName.contains(pattern) {
                return true
            }
        }
        
        // Check for macOS screenshot naming pattern: "Screenshot YYYY-MM-DD at HH.MM.SS"
        if fileName.hasPrefix("screenshot ") && fileName.contains(" at ") {
            return true
        }
        
        // Check resolution using pre-loaded dimensions
        if let dimensions = dimensions {
            let resolutionKey = "\(Int(dimensions.width))x\(Int(dimensions.height))"
            if screenshotResolutions.contains(resolutionKey) {
                // Screenshots typically have no EXIF camera data
                if !hasExifCamera {
                    return true
                }
            }
        }
        
        return false
    }
    
    /// Check if a photo is a Live Photo
    private func isLivePhoto(url: URL) -> Bool {
        return isLivePhotoNonisolated(url: url)
    }
    
    /// Nonisolated version for use in concurrent contexts
    private nonisolated func isLivePhotoNonisolated(url: URL) -> Bool {
        // Live Photos have a matching .mov file
        let baseName = url.deletingPathExtension().lastPathComponent
        let directory = url.deletingLastPathComponent()
        let movURL = directory.appendingPathComponent(baseName + ".mov")
        return FileManager.default.fileExists(atPath: movURL.path)
    }
    
    // MARK: - Metadata Extraction
    
    /// Options to prevent CGImageSource from caching full image data in memory
    private nonisolated var imageSourceOptions: CFDictionary {
        [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: true
        ] as CFDictionary
    }
    
    /// Get image dimensions and EXIF camera data in a single CGImageSource load
    /// This is the primary method to avoid multiple loads per file
    func getImageMetadata(url: URL) -> (dimensions: CGSize?, hasExifCamera: Bool) {
        return getImageMetadataNonisolated(url: url)
    }
    
    /// Nonisolated version for use in concurrent contexts
    private nonisolated func getImageMetadataNonisolated(url: URL) -> (dimensions: CGSize?, hasExifCamera: Bool) {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            return (nil, false)
        }
        
        // Extract dimensions
        var dimensions: CGSize?
        if let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            dimensions = CGSize(width: width, height: height)
        }
        
        // Check for EXIF camera data
        var hasExifCamera = false
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            hasExifCamera = exif[kCGImagePropertyExifLensMake] != nil ||
                           exif[kCGImagePropertyExifLensModel] != nil ||
                           exif[kCGImagePropertyExifFocalLength] != nil
        }
        
        return (dimensions, hasExifCamera)
    }
    
    /// Get image dimensions without caching the full image data
    /// Use getImageMetadata() when you also need EXIF data to avoid double loading
    func getImageDimensions(url: URL) -> CGSize? {
        return getImageDimensionsNonisolated(url: url)
    }
    
    /// Nonisolated version for use in concurrent contexts
    private nonisolated func getImageDimensionsNonisolated(url: URL) -> CGSize? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            return nil
        }
        
        if let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            return CGSize(width: width, height: height)
        }
        
        return nil
    }
    
    /// Check if image has EXIF camera data without caching the full image
    /// Use getImageMetadata() when you also need dimensions to avoid double loading
    private func hasExifCameraData(url: URL) -> Bool {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, imageSourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] else {
            return false
        }
        
        // Check for camera-related EXIF tags
        return exif[kCGImagePropertyExifLensMake] != nil ||
               exif[kCGImagePropertyExifLensModel] != nil ||
               exif[kCGImagePropertyExifFocalLength] != nil
    }
    
    /// Analyze a single file, awaiting video duration via the modern async AVAsset API
    /// (the synchronous `tracks`/`duration` accessors are deprecated and block the pool thread).
    private func analyzeFileWithDuration(_ file: FileEntry) async -> MediaItem? {
        guard var item = autoreleasepool(invoking: { analyzeFileSynchronous(file) }) else { return nil }
        if item.type == .video, let seconds = await getVideoDuration(url: file.url), seconds > 0 {
            item = MediaItem(
                id: item.id,
                url: item.url,
                type: item.type,
                sizeBytes: item.sizeBytes,
                dimensions: item.dimensions,
                duration: seconds,
                createdAt: item.createdAt,
                modifiedAt: item.modifiedAt,
                subcategories: item.subcategories
            )
        }
        return item
    }

    /// Get video duration
    func getVideoDuration(url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            return duration.seconds.isNaN ? nil : duration.seconds
        } catch {
            return nil
        }
    }
    
    // MARK: - Categorization
    
    /// Assign subcategories to a media item based on its properties
    func categorizeItem(_ item: MediaItem) -> Set<MediaSubcategory> {
        return categorizeItemNonisolated(item)
    }
    
    /// Nonisolated version for use in concurrent contexts
    private nonisolated func categorizeItemNonisolated(_ item: MediaItem) -> Set<MediaSubcategory> {
        var categories: Set<MediaSubcategory> = []
        
        // Screenshots
        if item.type == .screenshot {
            categories.insert(.screenshots)
        }
        
        // Large files
        let threshold = item.isVideo ? largeVideoThreshold : largePhotoThreshold
        if item.sizeBytes > threshold {
            categories.insert(.largeFiles)
        }
        
        // Old media (not modified in over a year)
        if let modifiedAt = item.modifiedAt {
            let daysSinceModified = Calendar.current.dateComponents([.day], from: modifiedAt, to: Date()).day ?? 0
            if daysSinceModified > oldMediaDays {
                categories.insert(.oldMedia)
            } else if daysSinceModified < 30 {
                categories.insert(.recentMedia)
            }
        }
        
        return categories
    }
    
    // MARK: - Duplicate Detection
    
    /// Find potential duplicate groups based on file size and name similarity
    func detectDuplicates(_ items: [MediaItem]) async -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []

        // Group by exact size first (quick check)
        var sizeGroups: [Int64: [MediaItem]] = [:]
        for item in items {
            sizeGroups[item.sizeBytes, default: []].append(item)
        }

        // Within each same-size bucket, partition into one or more duplicate groups. The
        // previous logic only ever produced ONE group per bucket and silently dropped a second
        // distinct duplicate set; this forms every group.
        for (_, sameSize) in sizeGroups where sameSize.count > 1 {
            var candidateGroups: [[MediaItem]] = []
            for item in sameSize {
                if let idx = candidateGroups.firstIndex(where: { areLikelyDuplicates(item, $0[0]) }) {
                    candidateGroups[idx].append(item)
                } else {
                    candidateGroups.append([item])
                }
            }
            for group in candidateGroups where group.count > 1 {
                groups.append(DuplicateGroup(items: group))
            }
        }

        return groups
    }
    
    /// Check if two items are likely duplicates
    private func areLikelyDuplicates(_ a: MediaItem, _ b: MediaItem) -> Bool {
        // Same size is required
        guard a.sizeBytes == b.sizeBytes else { return false }
        
        // Same type
        guard a.type == b.type else { return false }
        
        // Check dimensions if available
        if let dimA = a.dimensions, let dimB = b.dimensions {
            if dimA != dimB { return false }
        }
        
        // Check for similar names (common duplicate patterns)
        let nameA = a.url.deletingPathExtension().lastPathComponent.lowercased()
        let nameB = b.url.deletingPathExtension().lastPathComponent.lowercased()
        
        // Exact name match
        if nameA == nameB { return true }
        
        // Name with suffix pattern: "photo", "photo (1)", "photo copy"
        return Self.cleanedName(nameA) == Self.cleanedName(nameB)
    }

    /// Precompiled suffix patterns — compiling these per comparison was a hot-path cost.
    private static let suffixRegexes: [NSRegularExpression] = {
        [" (\\d+)$", " copy( \\d+)?$", "-\\d+$", "_\\d+$"].compactMap {
            try? NSRegularExpression(pattern: $0, options: .caseInsensitive)
        }
    }()

    /// Strip common duplicate suffix patterns from a filename using the precompiled regexes.
    private static func cleanedName(_ name: String) -> String {
        var result = name
        for regex in suffixRegexes {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        return result
    }
    
    // MARK: - Statistics
    
    /// Generate statistics from analyzed media items
    func generateStats(from items: [MediaItem]) -> MediaAnalysisResult.MediaStats {
        var photoCount = 0
        var videoCount = 0
        var screenshotCount = 0
        var largeFileCount = 0
        var oldMediaCount = 0
        var totalSize: Int64 = 0
        
        for item in items {
            totalSize += item.sizeBytes
            
            switch item.type {
            case .photo, .livePhoto, .raw:
                photoCount += 1
            case .video:
                videoCount += 1
            case .screenshot:
                screenshotCount += 1
            }
            
            if item.subcategories.contains(.largeFiles) {
                largeFileCount += 1
            }
            if item.subcategories.contains(.oldMedia) {
                oldMediaCount += 1
            }
        }
        
        return MediaAnalysisResult.MediaStats(
            totalCount: items.count,
            totalSize: totalSize,
            photoCount: photoCount,
            videoCount: videoCount,
            screenshotCount: screenshotCount,
            largeFileCount: largeFileCount,
            oldMediaCount: oldMediaCount,
            duplicateCount: 0 // Will be updated separately
        )
    }
    
    // MARK: - Full Analysis
    
    /// Perform complete analysis including duplicate detection
    func performFullAnalysis(
        files: [FileEntry],
        progress: @escaping (Double, String?) -> Void
    ) async -> MediaAnalysisResult {
        // Register task with resource monitor
        await MainActor.run {
            ResourceMonitor.shared.registerTask(name: "MediaAnalysis")
        }
        
        // Ensure we unregister the task when done
        defer {
            Task { @MainActor in
                ResourceMonitor.shared.unregisterTask(name: "MediaAnalysis")
            }
        }
        
        // Phase 1: Analyze files (70% of progress)
        let items = await analyzeMediaFiles(files) { p, file in
            progress(p * 0.7, file)
        }
        
        // Phase 2: Detect duplicates (20% of progress)
        progress(0.7, "Detecting duplicates...")
        let duplicates = await detectDuplicates(items)
        
        // Update items with duplicate subcategory
        var updatedItems = items
        let duplicateIds = Set(duplicates.flatMap { $0.items.map { $0.id } })
        for index in updatedItems.indices {
            if duplicateIds.contains(updatedItems[index].id) {
                updatedItems[index].subcategories.insert(.duplicates)
            }
        }
        
        progress(0.9, "Generating suggestions...")
        
        // Phase 3: Generate stats
        var stats = generateStats(from: updatedItems)
        stats = MediaAnalysisResult.MediaStats(
            totalCount: stats.totalCount,
            totalSize: stats.totalSize,
            photoCount: stats.photoCount,
            videoCount: stats.videoCount,
            screenshotCount: stats.screenshotCount,
            largeFileCount: stats.largeFileCount,
            oldMediaCount: stats.oldMediaCount,
            duplicateCount: duplicates.flatMap { $0.items }.count
        )
        
        // Phase 4: Generate rule-based suggestions
        let suggestions = generateSuggestions(items: updatedItems, duplicates: duplicates, stats: stats)
        
        progress(1.0, nil)
        
        return MediaAnalysisResult(
            items: updatedItems,
            duplicateGroups: duplicates,
            suggestions: suggestions,
            stats: stats
        )
    }
    
    // MARK: - Rule-Based Suggestions
    
    /// Generate cleanup suggestions based on analysis
    func generateSuggestions(
        items: [MediaItem],
        duplicates: [DuplicateGroup],
        stats: MediaAnalysisResult.MediaStats
    ) -> [MediaSuggestion] {
        var suggestions: [MediaSuggestion] = []
        
        // Duplicate suggestion
        if !duplicates.isEmpty {
            let totalDuplicateSavings = duplicates.reduce(0) { $0 + $1.potentialSavings }
            let duplicateItems = duplicates.flatMap { Array($0.items.dropFirst()) }
            suggestions.append(MediaSuggestion(
                title: "Remove Duplicates",
                description: "\(duplicates.count) groups of duplicate files found",
                icon: "doc.on.doc",
                color: .red,
                potentialSavings: totalDuplicateSavings,
                affectedItems: duplicateItems,
                action: .delete
            ))
        }
        
        // Screenshot cleanup
        let screenshots = items.filter { $0.type == .screenshot }
        if screenshots.count > 10 {
            let screenshotSize = screenshots.reduce(0) { $0 + $1.sizeBytes }
            suggestions.append(MediaSuggestion(
                title: "Review Screenshots",
                description: "\(screenshots.count) screenshots taking up space",
                icon: "camera.viewfinder",
                color: .orange,
                potentialSavings: screenshotSize,
                affectedItems: screenshots,
                action: .review
            ))
        }
        
        // Large files
        let largeItems = items.filter { $0.subcategories.contains(.largeFiles) }
        if !largeItems.isEmpty {
            let largeSize = largeItems.reduce(0) { $0 + $1.sizeBytes }
            let potentialSavings = Int64(Double(largeSize) * 0.4) // Estimate 40% compression
            suggestions.append(MediaSuggestion(
                title: "Compress Large Files",
                description: "\(largeItems.count) large files could be optimized",
                icon: "arrow.down.right.and.arrow.up.left",
                color: .purple,
                potentialSavings: potentialSavings,
                affectedItems: largeItems,
                action: .compress
            ))
        }
        
        // Old media
        let oldItems = items.filter { $0.subcategories.contains(.oldMedia) }
        if oldItems.count > 20 {
            let oldSize = oldItems.reduce(0) { $0 + $1.sizeBytes }
            suggestions.append(MediaSuggestion(
                title: "Archive Old Media",
                description: "\(oldItems.count) files not accessed in over a year",
                icon: "clock.arrow.circlepath",
                color: .gray,
                potentialSavings: oldSize,
                affectedItems: oldItems,
                action: .organize
            ))
        }
        
        return suggestions
    }
}
