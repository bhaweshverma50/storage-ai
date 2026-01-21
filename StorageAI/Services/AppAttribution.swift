import Foundation

enum AppAttribution {
    static func discoverApps() -> [URL] {
        let appDirs = [URL(fileURLWithPath: "/Applications"),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var apps: [URL] = []
        for dir in appDirs {
            let contents = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            apps.append(contentsOf: contents.filter { $0.pathExtension == "app" })
        }
        return apps
    }

    static func analyzeApps() -> [AppEntry] {
        let apps = discoverApps()
        return apps.map { appURL in
            let bundle = Bundle(url: appURL)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? appURL.deletingPathExtension().lastPathComponent
            let bundleId = bundle?.bundleIdentifier

            let supportPaths = relatedSupportPaths(appName: name, bundleId: bundleId)
            let bundleSize = FileIndexer.sizeOfPath(appURL)
            let supportSize = supportPaths.support.reduce(0) { $0 + FileIndexer.sizeOfPath($1) }
            let cacheSize = supportPaths.caches.reduce(0) { $0 + FileIndexer.sizeOfPath($1) }
            let containerSize = supportPaths.containers.reduce(0) { $0 + FileIndexer.sizeOfPath($1) }

            return AppEntry(
                name: name,
                bundleIdentifier: bundleId,
                bundleURL: appURL,
                bundleSizeBytes: bundleSize,
                supportSizeBytes: supportSize,
                cacheSizeBytes: cacheSize,
                containerSizeBytes: containerSize
            )
        }
    }

    private static func relatedSupportPaths(appName: String, bundleId: String?) -> (support: [URL], caches: [URL], containers: [URL]) {
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
        }

        return (support, caches, containers)
    }
}
