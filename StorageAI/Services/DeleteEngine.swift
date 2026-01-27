import Foundation

enum DeleteEngine {
    /// Well-known system directories that should have their contents deleted, not the directory itself
    private static let protectedDirectories: Set<String> = [
        "Library/Caches",
        "Library/Logs",
        "Library/Containers",
        "Library/Application Support",
        ".Trash"
    ]
    
    /// Check if a path is a protected system directory that shouldn't be deleted itself
    private static func isProtectedDirectory(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for protected in protectedDirectories {
            if url.path == home.appendingPathComponent(protected).path {
                return true
            }
        }
        return false
    }
    
    /// Delete contents of a directory without deleting the directory itself
    private static func deleteContents(of directory: URL, dryRun: Bool) throws -> (deleted: [URL], errors: [String]) {
        var deleted: [URL] = []
        var errors: [String] = []
        let fm = FileManager.default
        
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return (deleted, errors)
        }
        
        for item in contents {
            if dryRun {
                deleted.append(item)
                continue
            }
            
            do {
                try fm.trashItem(at: item, resultingItemURL: nil)
                deleted.append(item)
            } catch {
                // If trash fails, fallback to permanent delete (rare, but possible for some sys files)
                // or just log error. For safety, we will just log error here.
                do {
                     try fm.removeItem(at: item)
                     deleted.append(item)
                } catch {
                     errors.append("\(item.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        
        return (deleted, errors)
    }
    
    static func delete(targets: [CleanupTarget], dryRun: Bool) throws -> [URL] {
        var deleted: [URL] = []
        var allErrors: [String] = []
        let fm = FileManager.default
        
        for target in targets {
            for path in target.paths {
                guard fm.fileExists(atPath: path.path) else { continue }
                
                // For protected directories, delete contents instead of the directory itself
                if isProtectedDirectory(path) {
                    let result = try deleteContents(of: path, dryRun: dryRun)
                    deleted.append(contentsOf: result.deleted)
                    allErrors.append(contentsOf: result.errors)
                } else {
                    if dryRun {
                        deleted.append(path)
                        continue
                    }
                    
                    do {
                        try fm.trashItem(at: path, resultingItemURL: nil)
                        deleted.append(path)
                    } catch {
                        // Trash failed, try direct delete
                        do {
                            try fm.removeItem(at: path)
                            deleted.append(path)
                        } catch {
                             allErrors.append("\(path.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
        
        // If we deleted nothing and have errors, throw an error
        if deleted.isEmpty && !allErrors.isEmpty {
            throw DeleteError.partialFailure(errors: allErrors)
        }
        
        return deleted
    }
}

enum DeleteError: LocalizedError {
    case partialFailure(errors: [String])
    
    var errorDescription: String? {
        switch self {
        case .partialFailure(let errors):
            return "Some items couldn't be deleted:\n" + errors.prefix(5).joined(separator: "\n")
        }
    }
}
