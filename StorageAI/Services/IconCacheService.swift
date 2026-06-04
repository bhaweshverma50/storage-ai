import SwiftUI
import AppKit

/// A thread-safe actor to manage icon caching and retrieval
actor IconCacheService {
    static let shared = IconCacheService()
    
    private var cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 500 // Limit to 500 icons
        return cache
    }()
    
    /// Get icon for a file path, checking cache first.
    /// The (potentially slow, disk-touching) NSWorkspace lookup runs on a detached task so
    /// concurrent requests don't serialize behind one another on the actor's single executor;
    /// the actor only guards the cache map.
    func icon(for path: String) async -> NSImage {
        let key = path as NSString

        if let cached = cache.object(forKey: key) {
            return cached
        }

        let icon = await Task.detached(priority: .utility) {
            NSWorkspace.shared.icon(forFile: path)
        }.value
        cache.setObject(icon, forKey: key)
        return icon
    }

    /// Pre-warm cache for a list of paths concurrently (bounded by the cooperative pool).
    func prewarm(paths: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for path in paths {
                group.addTask { _ = await self.icon(for: path) }
            }
        }
    }
}
