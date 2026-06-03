import Foundation
import AppKit
import AVFoundation
import CoreImage

/// Service for estimating and performing media compression
actor MediaCompressionService {
    
    // MARK: - Compression Estimation
    
    /// Estimate compression savings for a collection of media items
    func estimateCompression(
        for items: [MediaItem],
        quality: CompressionQuality
    ) -> CompressionEstimate {
        var totalOriginalSize: Int64 = 0
        var totalEstimatedSize: Int64 = 0
        
        for item in items {
            totalOriginalSize += item.sizeBytes
            
            let estimatedSize: Int64
            if item.isVideo {
                estimatedSize = estimateVideoCompression(item: item, quality: quality)
            } else {
                estimatedSize = estimatePhotoCompression(item: item, quality: quality)
            }
            
            totalEstimatedSize += estimatedSize
        }
        
        return CompressionEstimate(
            originalSize: totalOriginalSize,
            estimatedSize: totalEstimatedSize,
            quality: quality,
            itemCount: items.count
        )
    }
    
    /// Estimate compressed size for a photo
    private func estimatePhotoCompression(item: MediaItem, quality: CompressionQuality) -> Int64 {
        let original = item.sizeBytes
        
        // RAW files have high compression potential
        if item.type == .raw {
            // Converting RAW to JPEG typically reduces to 10-20% of original
            return Int64(Double(original) * 0.15 * (1.0 + quality.targetRatio) / 2.0)
        }
        
        // PNG screenshots can be compressed significantly
        if item.type == .screenshot && item.fileExtension == "png" {
            // PNG to JPEG typically 20-40% of original
            return Int64(Double(original) * 0.3 * (1.0 + quality.targetRatio) / 2.0)
        }
        
        // HEIC is already compressed, limited gains
        if item.fileExtension == "heic" || item.fileExtension == "heif" {
            return Int64(Double(original) * (0.85 + quality.targetRatio * 0.1))
        }
        
        // Standard JPEG/other photos
        return Int64(Double(original) * quality.targetRatio)
    }
    
    /// Estimate compressed size for a video
    private func estimateVideoCompression(item: MediaItem, quality: CompressionQuality) -> Int64 {
        let original = item.sizeBytes
        
        // Videos typically compress based on bitrate reduction
        // Factor in video duration if available
        let baseRatio = quality.videoBitrateMultiplier
        
        // Larger videos tend to have more compression potential
        if original > 500_000_000 { // > 500 MB
            return Int64(Double(original) * baseRatio * 0.9)
        } else if original > 100_000_000 { // > 100 MB
            return Int64(Double(original) * baseRatio * 0.95)
        }
        
        return Int64(Double(original) * baseRatio)
    }
    
    // MARK: - Batch Estimation
    
    /// Get estimates for all quality levels
    func estimateAllQualities(for items: [MediaItem]) -> [CompressionQuality: CompressionEstimate] {
        var estimates: [CompressionQuality: CompressionEstimate] = [:]
        
        for quality in CompressionQuality.allCases {
            estimates[quality] = estimateCompression(for: items, quality: quality)
        }
        
        return estimates
    }
    
    // MARK: - Compression Execution
    
    /// Compress a batch of media items
    func compressItems(
        _ items: [MediaItem],
        quality: CompressionQuality,
        keepOriginals: Bool = true,
        progress: @escaping (Double, String?) -> Void
    ) async throws -> CompressionResult {
        // Register task with resource monitor
        await MainActor.run {
            ResourceMonitor.shared.registerTask(name: "Compression")
        }
        
        // Ensure we unregister the task when done
        defer {
            Task { @MainActor in
                ResourceMonitor.shared.unregisterTask(name: "Compression")
            }
        }
        
        var compressedItems: [CompressedItemResult] = []
        var totalOriginalSize: Int64 = 0
        var totalCompressedSize: Int64 = 0
        var errors: [String] = []
        
        let total = items.count
        
        for (index, item) in items.enumerated() {
            // Check for cancellation
            if Task.isCancelled {
                throw CompressionError.cancelled
            }
            
            // Report progress
            let progressValue = Double(index) / Double(max(total, 1))
            progress(progressValue, item.fileName)
            
            do {
                let result: CompressedItemResult
                if item.isVideo {
                    result = try await compressVideo(item: item, quality: quality, keepOriginal: keepOriginals)
                } else {
                    result = try await compressPhoto(item: item, quality: quality, keepOriginal: keepOriginals)
                }
                
                compressedItems.append(result)
                totalOriginalSize += result.originalSize
                totalCompressedSize += result.compressedSize
            } catch {
                errors.append("\(item.fileName): \(error.localizedDescription)")
            }
        }
        
        progress(1.0, nil)
        
        return CompressionResult(
            items: compressedItems,
            totalOriginalSize: totalOriginalSize,
            totalCompressedSize: totalCompressedSize,
            errors: errors
        )
    }
    
    // MARK: - Photo Compression
    
    /// Compress a single photo
    private func compressPhoto(
        item: MediaItem,
        quality: CompressionQuality,
        keepOriginal: Bool
    ) async throws -> CompressedItemResult {
        guard let image = NSImage(contentsOf: item.url) else {
            throw CompressionError.unableToReadFile
        }
        
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CompressionError.invalidImageData
        }
        
        // Create output URL
        let outputURL = createOutputURL(for: item.url, suffix: "_compressed", extension: "jpg")
        
        // Create JPEG representation
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmapRep.representation(
            using: .jpeg,
            properties: [.compressionFactor: quality.jpegQuality]
        ) else {
            throw CompressionError.compressionFailed
        }
        
        // Write to file
        try jpegData.write(to: outputURL)
        
        let compressedSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64 ?? 0
        
        // Handle original file
        var finalURL = outputURL
        if !keepOriginal {
            finalURL = try replaceOriginal(item.url, with: outputURL, compressedExtension: "jpg", compressedSize: compressedSize)
        }

        return CompressedItemResult(
            originalURL: item.url,
            compressedURL: finalURL,
            originalSize: item.sizeBytes,
            compressedSize: compressedSize,
            mediaType: item.type
        )
    }

    /// Safely replace `original` with the freshly written `compressed` output.
    /// We verify the output first, move the original aside (restoring it if the swap fails),
    /// and move the original to the Trash on success rather than permanently deleting it.
    private func replaceOriginal(_ original: URL, with compressed: URL, compressedExtension: String, compressedSize: Int64) throws -> URL {
        // Never destroy the only copy for a zero-byte / failed output.
        guard compressedSize > 0 else { throw CompressionError.compressionFailed }

        let fm = FileManager.default
        let finalDest = original.deletingPathExtension().appendingPathExtension(compressedExtension)
        let backupURL = original.appendingPathExtension("backup")
        // Clear any stale backup from a previous interrupted run.
        try? fm.removeItem(at: backupURL)

        // Move the original aside (recoverable point).
        try fm.moveItem(at: original, to: backupURL)
        do {
            try fm.moveItem(at: compressed, to: finalDest)
        } catch {
            // Swap failed — restore the original so we never strand the user's only copy.
            try? fm.moveItem(at: backupURL, to: original)
            throw error
        }
        // Success: move the original (backup) to the Trash so it stays recoverable.
        if (try? fm.trashItem(at: backupURL, resultingItemURL: nil)) == nil {
            // If trashing fails, leave the .backup in place rather than permanently deleting it.
        }
        return finalDest
    }

    // MARK: - Video Compression
    
    /// Compress a single video
    private func compressVideo(
        item: MediaItem,
        quality: CompressionQuality,
        keepOriginal: Bool
    ) async throws -> CompressedItemResult {
        let asset = AVURLAsset(url: item.url)
        
        // Create output URL
        let outputURL = createOutputURL(for: item.url, suffix: "_compressed", extension: "mp4")
        
        // Configure export session
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetForQuality(quality)) else {
            throw CompressionError.exportSessionCreationFailed
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        
        // Export
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            if let error = exportSession.error {
                throw CompressionError.videoExportFailed(error.localizedDescription)
            }
            throw CompressionError.compressionFailed
        }
        
        let compressedSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64 ?? 0
        
        // Handle original file
        var finalURL = outputURL
        if !keepOriginal {
            finalURL = try replaceOriginal(item.url, with: outputURL, compressedExtension: "mp4", compressedSize: compressedSize)
        }
        
        return CompressedItemResult(
            originalURL: item.url,
            compressedURL: finalURL,
            originalSize: item.sizeBytes,
            compressedSize: compressedSize,
            mediaType: item.type
        )
    }
    
    /// Get AVAssetExportSession preset for quality level
    private func presetForQuality(_ quality: CompressionQuality) -> String {
        switch quality {
        case .high:
            return AVAssetExportPreset1920x1080
        case .medium:
            return AVAssetExportPreset1280x720
        case .low:
            return AVAssetExportPreset960x540
        }
    }
    
    // MARK: - Helpers
    
    /// Create an output URL for compressed file
    private func createOutputURL(for originalURL: URL, suffix: String, extension ext: String) -> URL {
        let directory = originalURL.deletingLastPathComponent()
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        var outputURL = directory.appendingPathComponent("\(baseName)\(suffix).\(ext)")
        
        // Ensure unique filename
        var counter = 1
        while FileManager.default.fileExists(atPath: outputURL.path) {
            outputURL = directory.appendingPathComponent("\(baseName)\(suffix)_\(counter).\(ext)")
            counter += 1
        }
        
        return outputURL
    }
}

// MARK: - Compression Results

struct CompressedItemResult: Identifiable {
    let id = UUID()
    let originalURL: URL
    let compressedURL: URL
    let originalSize: Int64
    let compressedSize: Int64
    let mediaType: MediaType
    
    var savingsBytes: Int64 {
        max(0, originalSize - compressedSize)
    }
    
    var savingsPercent: Double {
        guard originalSize > 0 else { return 0 }
        return Double(savingsBytes) / Double(originalSize) * 100
    }
}

struct CompressionResult {
    let items: [CompressedItemResult]
    let totalOriginalSize: Int64
    let totalCompressedSize: Int64
    let errors: [String]
    
    var totalSavings: Int64 {
        max(0, totalOriginalSize - totalCompressedSize)
    }
    
    var savingsPercent: Double {
        guard totalOriginalSize > 0 else { return 0 }
        return Double(totalSavings) / Double(totalOriginalSize) * 100
    }
    
    var successCount: Int {
        items.count
    }
    
    var errorCount: Int {
        errors.count
    }
    
    var formattedSavings: String {
        Formatters.bytes(totalSavings)
    }
}

// MARK: - Compression Errors

enum CompressionError: LocalizedError {
    case unableToReadFile
    case invalidImageData
    case compressionFailed
    case exportSessionCreationFailed
    case videoExportFailed(String)
    case cancelled
    case diskFull
    case permissionDenied
    
    var errorDescription: String? {
        switch self {
        case .unableToReadFile:
            return "Unable to read the file"
        case .invalidImageData:
            return "Invalid image data"
        case .compressionFailed:
            return "Compression failed"
        case .exportSessionCreationFailed:
            return "Could not create video export session"
        case .videoExportFailed(let reason):
            return "Video export failed: \(reason)"
        case .cancelled:
            return "Operation was cancelled"
        case .diskFull:
            return "Not enough disk space"
        case .permissionDenied:
            return "Permission denied"
        }
    }
}
