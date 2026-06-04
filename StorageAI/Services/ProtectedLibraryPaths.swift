import Foundation

/// Paths macOS guards behind the Photos / "Media & Apple Music" TCC services. Descending into
/// them — or even loading metadata from their files via AVAsset — raises a blocking system
/// permission prompt, so scanners treat the packages as opaque leaves and analyzers skip
/// their contents entirely.
enum ProtectedLibraryPaths {
    /// Package bundles owned by Photos / Music / TV / iMovie.
    static let bundleExtensions: Set<String> = [
        "photoslibrary", "migratedphotolibrary", "photolibrary", "aplibrary",
        "musiclibrary", "tvlibrary", "imovielibrary", "theater"
    ]

    /// Music.app / iTunes / TV.app managed media folders — loose files, not package bundles,
    /// but still covered by the media-library TCC service.
    private static let managedFolders: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/Music/Music", "\(home)/Music/iTunes", "\(home)/Music/TV"]
    }()

    /// True when `url` IS a protected package (a directory walk must not descend into it).
    static func isProtectedBundle(_ url: URL) -> Bool {
        bundleExtensions.contains(url.pathExtension.lowercased())
    }

    /// True when `url` lives inside a protected package or an app-managed media folder
    /// (the file must not be opened or analyzed).
    static func isInsideProtectedLibrary(_ url: URL) -> Bool {
        let path = url.path
        for folder in managedFolders where path == folder || path.hasPrefix(folder + "/") {
            return true
        }
        // Any ancestor component being a protected package also covers the file.
        for component in url.pathComponents {
            if let dot = component.lastIndex(of: "."),
               bundleExtensions.contains(component[component.index(after: dot)...].lowercased()) {
                return true
            }
        }
        return false
    }
}
