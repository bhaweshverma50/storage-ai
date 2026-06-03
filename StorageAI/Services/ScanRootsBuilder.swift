import Foundation

/// Single source of truth for the set of filesystem roots a scan should cover.
/// Used by every scan entry point (window, menu bar, dashboard) so they can't diverge.
enum ScanRootsBuilder {
    static func roots(settings: AppSettings, fileManager: FileManager = .default) -> [URL] {
        var roots = [
            fileManager.homeDirectoryForCurrentUser,   // captures hidden folders, dev tools, etc.
            URL(fileURLWithPath: "/Applications")
        ]

        // Developer / package-manager trees often live outside home.
        for path in ["/opt/homebrew", "/usr/local", "/opt/local"] {
            roots.append(URL(fileURLWithPath: path))
        }

        if settings.includeSystem {
            for path in ["/System", "/Library", "/private/var"] {
                roots.append(URL(fileURLWithPath: path))
            }
        }

        return roots.filter { fileManager.fileExists(atPath: $0.path) }
    }
}
