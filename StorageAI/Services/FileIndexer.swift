import Foundation

enum FileIndexerError: Error {
    case accessDenied(String)
    case cancelled
}

// Result that includes running totals for real-time updates
struct ScanUpdate {
    var scannedFiles: Int
    var scannedBytes: Int64
    var currentPath: String
    var phase: ScanPhase
    var buckets: [StorageCategory: Int64]
    var fileCounts: [StorageCategory: Int]  // File counts per category
}

/// Cancellation token for cooperative cancellation
final class CancellationToken: @unchecked Sendable {
    private var _isCancelled = false
    private let lock = NSLock()
    
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }
    
    func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }
}

enum FileIndexer {
    static func scan(
        roots: [URL],
        includeHidden: Bool,
        excludedPaths: [String],
        cancellationToken: CancellationToken,
        progress: @escaping (ScanUpdate) -> Void,
        initialBuckets: [StorageCategory: Int64]? = nil,
        initialFiles: [StorageCategory: [FileEntry]]? = nil,
        initialScannedFiles: Int = 0,
        initialScannedBytes: Int64 = 0
    ) throws -> ScanResult {
        // Start with initial values if resuming, otherwise start fresh
        var buckets = initialBuckets ?? StorageCategory.allCases.reduce(into: [StorageCategory: Int64]()) { $0[$1] = 0 }
        var filesByCategory = initialFiles ?? StorageCategory.allCases.reduce(into: [StorageCategory: [FileEntry]]()) { $0[$1] = [] }
        // Track file counts per category
        var categoryFileCounts: [StorageCategory: Int] = initialFiles?.mapValues { $0.count } ?? StorageCategory.allCases.reduce(into: [StorageCategory: Int]()) { $0[$1] = 0 }
        var scannedFiles = initialScannedFiles
        var scannedBytes: Int64 = initialScannedBytes
        var lastProgressUpdate = Date()

        let excluded = Set(excludedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path.lowercased() })

        // Send initial progress
        progress(ScanUpdate(
            scannedFiles: 0,
            scannedBytes: 0,
            currentPath: "Starting scan...",
            phase: .preparing,
            buckets: buckets,
            fileCounts: categoryFileCounts
        ))

        for root in roots {
            // Check cancellation at each root
            if cancellationToken.isCancelled {
                throw FileIndexerError.cancelled
            }
            
            // Determine scan phase based on root
            let phase = determinePhase(for: root)
            progress(ScanUpdate(
                scannedFiles: scannedFiles,
                scannedBytes: scannedBytes,
                currentPath: "Scanning: \(root.lastPathComponent)",
                phase: phase,
                buckets: buckets,
                fileCounts: categoryFileCounts
            ))
            
            // For Library folder, always include hidden files
            let shouldIncludeHidden = includeHidden || root.path.contains("/Library")
            
            // Use different options based on what we're scanning
            var enumOptions: FileManager.DirectoryEnumerationOptions = []
            if !shouldIncludeHidden {
                enumOptions.insert(.skipsHiddenFiles)
            }
            
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .fileSizeKey,
                    .totalFileAllocatedSizeKey,
                    .isHiddenKey,
                    .contentModificationDateKey
                ],
                options: enumOptions
            )

            guard let fileEnum = enumerator else {
                continue
            }

            for case let url as URL in fileEnum {
                // Check cancellation frequently
                if cancellationToken.isCancelled {
                    throw FileIndexerError.cancelled
                }

                let standardPath = url.standardizedFileURL.path
                let lowercasePath = standardPath.lowercased()
                
                // Skip excluded paths
                if excluded.contains(where: { lowercasePath.hasPrefix($0) }) {
                    fileEnum.skipDescendants()
                    continue
                }
                
                // Skip problematic system paths
                if lowercasePath.contains("/timemachine") ||
                   lowercasePath.contains("/.spotlight-v100") ||
                   lowercasePath.contains("/.fseventsd") ||
                   lowercasePath.contains("/.trash") ||
                   lowercasePath.contains("/volumes/") && !lowercasePath.contains("/volumes/macintosh") {
                    fileEnum.skipDescendants()
                    continue
                }

                do {
                    let values = try url.resourceValues(forKeys: [
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .isHiddenKey,
                        .fileSizeKey,
                        .totalFileAllocatedSizeKey,
                        .contentModificationDateKey
                    ])

                    // Skip directories (we still traverse into them)
                    if values.isDirectory == true {
                        continue
                    }

                    guard values.isRegularFile == true else { continue }

                    let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                    scannedFiles += 1
                    scannedBytes += size

                    let category = StorageClassifier.category(for: url)
                    buckets[category, default: 0] += size
                    categoryFileCounts[category, default: 0] += 1  // Track file count per category

                    // Store files larger than 1MB for display, with max limit per category
                    let maxFilesPerCategory = 1000
                    if size > 1_000_000 {
                        var categoryFiles = filesByCategory[category, default: []]

                        if categoryFiles.count < maxFilesPerCategory {
                            categoryFiles.append(FileEntry(
                                url: url,
                                sizeBytes: size,
                                modifiedAt: values.contentModificationDate
                            ))
                        } else if let minIndex = categoryFiles.indices.min(by: { categoryFiles[$0].sizeBytes < categoryFiles[$1].sizeBytes }),
                                  categoryFiles[minIndex].sizeBytes < size {
                            // Replace smallest file if new file is larger
                            categoryFiles[minIndex] = FileEntry(
                                url: url,
                                sizeBytes: size,
                                modifiedAt: values.contentModificationDate
                            )
                        }

                        filesByCategory[category] = categoryFiles
                    }

                    // Update progress every 5 seconds OR every 500 files, whichever comes first
                    let now = Date()
                    let timeSinceLastUpdate = now.timeIntervalSince(lastProgressUpdate)
                    if timeSinceLastUpdate >= 5.0 || scannedFiles % 500 == 0 {
                        lastProgressUpdate = now
                        progress(ScanUpdate(
                            scannedFiles: scannedFiles,
                            scannedBytes: scannedBytes,
                            currentPath: url.path,
                            phase: phase,
                            buckets: buckets,
                            fileCounts: categoryFileCounts
                        ))
                    }
                } catch {
                    // Skip files we can't read - this is normal for permission-denied
                    continue
                }
            }
        }

        // Final update
        progress(ScanUpdate(
            scannedFiles: scannedFiles,
            scannedBytes: scannedBytes,
            currentPath: "Finishing up...",
            phase: .analyzing,
            buckets: buckets,
            fileCounts: categoryFileCounts
        ))
        
        let bucketList = StorageCategory.allCases.map { StorageBucket(category: $0, bytes: buckets[$0, default: 0]) }
        return ScanResult(buckets: bucketList, filesByCategory: filesByCategory)
    }
    
    private static func determinePhase(for url: URL) -> ScanPhase {
        let path = url.path.lowercased()
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path.lowercased()
        
        if path.hasPrefix("/applications") {
            return .scanningApplications
        } else if path.hasPrefix("/system") {
            return .scanningSystem
        } else if path.hasPrefix("/library") || path.contains("/library") {
            return .scanningLibrary
        } else if path.hasPrefix(homeDir) {
            return .scanningHome
        }
        return .scanningHome
    }

    static func sizeOfPath(_ url: URL, includeHidden: Bool = true) -> Int64 {
        var total: Int64 = 0
        
        var enumOptions: FileManager.DirectoryEnumerationOptions = []
        if !includeHidden {
            enumOptions.insert(.skipsHiddenFiles)
        }
        
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .totalFileAllocatedSizeKey
            ],
            options: enumOptions
        )

        guard let fileEnum = enumerator else { return 0 }
        for case let fileURL as URL in fileEnum {
            let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
                .totalFileAllocatedSizeKey
            ])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}

enum StorageClassifier {
    private static let homeDir = FileManager.default.homeDirectoryForCurrentUser.path.lowercased()
    
    static func category(for url: URL) -> StorageCategory {
        let path = url.path.lowercased()
        let pathExtension = url.pathExtension.lowercased()
        
        // 1. Check Applications first (highest priority for .app bundles)
        if path.hasPrefix("/applications") || 
           path.contains("/applications/") ||
           pathExtension == "app" {
            return .applications
        }
        
        // 2. Check for user Documents/Desktop/Downloads (before Library check)
        let userDocuments = homeDir + "/documents/"
        let userDesktop = homeDir + "/desktop/"
        let userDownloads = homeDir + "/downloads/"
        
        if path.hasPrefix(userDocuments) || 
           path.hasPrefix(userDesktop) || 
           path.hasPrefix(userDownloads) ||
           path.contains("/documents/") ||
           path.contains("/desktop/") ||
           path.contains("/downloads/") {
            return .documents
        }
        
        // 3. Check for Media files (by location and extension)
        let userMovies = homeDir + "/movies/"
        let userMusic = homeDir + "/music/"
        let userPictures = homeDir + "/pictures/"
        let mediaExtensions = Set(["mp4", "mov", "avi", "mkv", "mp3", "aac", "flac", "wav", 
                                   "m4a", "m4v", "jpg", "jpeg", "png", "gif", "heic", "raw",
                                   "tiff", "bmp", "webp", "svg", "pdf"])
        
        if path.hasPrefix(userMovies) || 
           path.hasPrefix(userMusic) || 
           path.hasPrefix(userPictures) ||
           mediaExtensions.contains(pathExtension) {
            return .media
        }
        
        // 4. Check for System files
        if path.hasPrefix("/system") || 
           path.hasPrefix("/library") ||
           path.hasPrefix("/usr") ||
           path.hasPrefix("/bin") ||
           path.hasPrefix("/sbin") ||
           path.hasPrefix("/private/var") {
            return .system
        }
        
        // 5. Check for Library/Caches/Containers (App support data)
        let userLibrary = homeDir + "/library/"
        if path.hasPrefix(userLibrary) || 
           path.contains("/library/caches/") ||
           path.contains("/library/application support/") ||
           path.contains("/library/containers/") ||
           path.contains("/library/logs/") ||
           path.contains("/library/preferences/") {
            return .libraries
        }
        
        // 6. Developer-related files
        let devExtensions = Set(["swift", "m", "h", "c", "cpp", "py", "js", "ts", "json", 
                                 "xml", "plist", "xcodeproj", "xcworkspace"])
        if devExtensions.contains(pathExtension) ||
           path.contains("/developer/") ||
           path.contains("/deriveddata/") ||
           path.contains("/.git/") {
            return .libraries
        }
        
        return .other
    }
}
