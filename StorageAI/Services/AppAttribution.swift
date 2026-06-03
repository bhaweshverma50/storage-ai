import Foundation

enum AppAttribution {
    static func discoverApps() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        
        // Standard app directories
        var appDirs = [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications")
        ]
        
        // Homebrew Cask locations (apps are symlinked from here)
        let brewCaskDirs = [
            "/opt/homebrew/Caskroom",    // Apple Silicon
            "/usr/local/Caskroom"        // Intel
        ]
        
        for caskDir in brewCaskDirs {
            let url = URL(fileURLWithPath: caskDir)
            if FileManager.default.fileExists(atPath: url.path) {
                // Each cask has subdirectories with version numbers containing .app bundles
                if let casks = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    for cask in casks {
                        if let versions = try? FileManager.default.contentsOfDirectory(at: cask, includingPropertiesForKeys: nil) {
                            for version in versions {
                                appDirs.append(version)
                            }
                        }
                    }
                }
            }
        }
        
        var apps: [URL] = []
        var seenBundles: Set<String> = []  // Track bundle IDs to avoid duplicates
        
        for dir in appDirs {
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for item in contents {
                if item.pathExtension == "app" {
                    // Check for duplicates by bundle ID
                    if let bundle = Bundle(url: item), let bundleId = bundle.bundleIdentifier {
                        if seenBundles.contains(bundleId) { continue }
                        seenBundles.insert(bundleId)
                    }
                    apps.append(item)
                }
            }
        }
        
        return apps
    }
    
    /// Discover apps that have data in Library folders but might not have a .app bundle
    /// (e.g., CLI tools, removed apps with leftover data, Homebrew-installed apps)
    static func discoverOrphanedAppData() -> [AppEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var orphanedApps: [AppEntry] = []
        var seenIdentifiers: Set<String> = []
        
        // Scan Application Support for directories
        let appSupportDir = home.appendingPathComponent("Library/Application Support")
        if let contents = try? FileManager.default.contentsOfDirectory(at: appSupportDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for item in contents {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                
                let name = item.lastPathComponent
                // Skip common system/Apple directories
                if name.hasPrefix(".") || name == "Apple" || name == "com.apple" || name.hasPrefix("com.apple.") { continue }
                
                // Check if this has significant data (> 10MB)
                let size = FileIndexer.sizeOfPath(item)
                if size > 10_000_000 && !seenIdentifiers.contains(name.lowercased()) {
                    seenIdentifiers.insert(name.lowercased())
                    
                    // Check for related cache/container data
                    let cacheSize = FileIndexer.sizeOfPath(home.appendingPathComponent("Library/Caches/\(name)"))
                    let containerSize = FileIndexer.sizeOfPath(home.appendingPathComponent("Library/Containers/\(name)"))
                    
                    orphanedApps.append(AppEntry(
                        name: name,
                        bundleIdentifier: name,  // Use folder name as identifier
                        bundleURL: item,  // Point to Application Support folder
                        bundleSizeBytes: 0,  // No actual app bundle
                        supportSizeBytes: size,
                        cacheSizeBytes: cacheSize,
                        containerSizeBytes: containerSize
                    ))
                }
            }
        }
        
        // Scan Containers for sandboxed app data
        let containersDir = home.appendingPathComponent("Library/Containers")
        if let contents = try? FileManager.default.contentsOfDirectory(at: containersDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for item in contents {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                
                let bundleId = item.lastPathComponent
                if bundleId.hasPrefix("com.apple.") || seenIdentifiers.contains(bundleId.lowercased()) { continue }
                
                let size = FileIndexer.sizeOfPath(item)
                if size > 10_000_000 {
                    seenIdentifiers.insert(bundleId.lowercased())
                    
                    // Try to find a friendly name
                    let name = bundleId.components(separatedBy: ".").last ?? bundleId
                    let supportSize = FileIndexer.sizeOfPath(home.appendingPathComponent("Library/Application Support/\(bundleId)"))
                    let cacheSize = FileIndexer.sizeOfPath(home.appendingPathComponent("Library/Caches/\(bundleId)"))
                    
                    orphanedApps.append(AppEntry(
                        name: name.capitalized,
                        bundleIdentifier: bundleId,
                        bundleURL: item,
                        bundleSizeBytes: 0,
                        supportSizeBytes: supportSize,
                        cacheSizeBytes: cacheSize,
                        containerSizeBytes: size
                    ))
                }
            }
        }
        
        // Scan Group Containers as well
        let groupContainersDir = home.appendingPathComponent("Library/Group Containers")
        if let contents = try? FileManager.default.contentsOfDirectory(at: groupContainersDir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for item in contents {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else { continue }
                
                let groupId = item.lastPathComponent
                if seenIdentifiers.contains(groupId.lowercased()) { continue }
                
                let size = FileIndexer.sizeOfPath(item)
                if size > 50_000_000 {  // Higher threshold for group containers
                    seenIdentifiers.insert(groupId.lowercased())
                    
                    let name = groupId.components(separatedBy: ".").dropFirst().joined(separator: " ").capitalized
                    
                    orphanedApps.append(AppEntry(
                        name: name.isEmpty ? groupId : name,
                        bundleIdentifier: groupId,
                        bundleURL: item,
                        bundleSizeBytes: 0,
                        supportSizeBytes: 0,
                        cacheSizeBytes: 0,
                        containerSizeBytes: size
                    ))
                }
            }
        }
        
        return orphanedApps
    }

    static func analyzeApps() -> [AppEntry] {
        var allApps: [AppEntry] = []
        var seenIdentifiers: Set<String> = []
        
        // First, analyze discovered .app bundles
        let apps = discoverApps()
        for appURL in apps {
            let bundle = Bundle(url: appURL)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? appURL.deletingPathExtension().lastPathComponent
            let bundleId = bundle?.bundleIdentifier
            
            if let id = bundleId {
                seenIdentifiers.insert(id.lowercased())
            }
            seenIdentifiers.insert(name.lowercased())

            let supportPaths = relatedSupportPaths(appName: name, bundleId: bundleId)
            let bundleSize = FileIndexer.sizeOfPath(appURL)
            let supportSize = supportPaths.support.reduce(0) { $0 + FileIndexer.sizeOfPath($1) }
            let cacheSize = supportPaths.caches.reduce(0) { $0 + FileIndexer.sizeOfPath($1) }
            let containerSize = supportPaths.containers.reduce(0) { $0 + FileIndexer.sizeOfPath($1) }

            allApps.append(AppEntry(
                name: name,
                bundleIdentifier: bundleId,
                bundleURL: appURL,
                bundleSizeBytes: bundleSize,
                supportSizeBytes: supportSize,
                cacheSizeBytes: cacheSize,
                containerSizeBytes: containerSize
            ))
        }
        
        // Then, add orphaned app data that doesn't have a corresponding .app bundle
        let orphanedApps = discoverOrphanedAppData()
        for app in orphanedApps {
            if let bundleId = app.bundleIdentifier?.lowercased(),
               !seenIdentifiers.contains(bundleId) && !seenIdentifiers.contains(app.name.lowercased()) {
                allApps.append(app)
            }
        }
        
        return allApps
    }

    static func relatedSupportPaths(appName: String, bundleId: String?) -> (support: [URL], caches: [URL], containers: [URL]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var support: [URL] = []
        var caches: [URL] = []
        var containers: [URL] = []

        support.append(home.appendingPathComponent("Library/Application Support/\(appName)"))
        caches.append(home.appendingPathComponent("Library/Caches/\(appName)"))

        if let bundleId {
            containers.append(home.appendingPathComponent("Library/Containers/\(bundleId)"))
            containers.append(home.appendingPathComponent("Library/Group Containers/\(bundleId)"))
            support.append(home.appendingPathComponent("Library/Application Support/\(bundleId)"))
            caches.append(home.appendingPathComponent("Library/Caches/\(bundleId)"))
            
            // Check for group containers that share the same team/group identifier
            // Group containers typically have format: <TEAM_ID>.<identifier> or <TEAM_ID>.group.<identifier>
            // We match by checking if the container starts with a known team ID from the bundle ID
            // or if the bundle ID is a suffix of the container name
            let groupContainersDir = home.appendingPathComponent("Library/Group Containers")
            if let contents = try? FileManager.default.contentsOfDirectory(at: groupContainersDir, includingPropertiesForKeys: nil) {
                // Extract team ID from bundle ID (typically first component like "UBF8T346G9" in "UBF8T346G9.Office")
                let bundleComponents = bundleId.components(separatedBy: ".")
                let teamId = bundleComponents.first ?? ""
                
                for item in contents {
                    let containerName = item.lastPathComponent
                    // Skip if already added
                    if containerName == bundleId { continue }
                    
                    // Only match if:
                    // 1. Container starts with the same team ID and contains part of the app identifier
                    // 2. Or container ends with the app's main identifier (e.g., ".Office" for Microsoft Office)
                    let containerComponents = containerName.components(separatedBy: ".")
                    let containerTeamId = containerComponents.first ?? ""
                    
                    // Match by team ID if both have one (team IDs are typically 10 alphanumeric chars)
                    let hasMatchingTeamId = teamId.count >= 8 && containerTeamId == teamId
                    
                    // Match by full bundle ID suffix (e.g., "UBF8T346G9.com.microsoft.Word" matches bundle "com.microsoft.Word")
                    // This prevents false matches where a short identifier like "Mail" would match "com.apple.mail"
                    let hasMatchingSuffix = containerName.lowercased().hasSuffix(".\(bundleId.lowercased())")
                    
                    if hasMatchingTeamId || hasMatchingSuffix {
                        containers.append(item)
                    }
                }
            }
        }

        return (support, caches, containers)
    }
}
