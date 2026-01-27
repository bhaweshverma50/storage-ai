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
    
    /// Get icon for a file path, checking cache first
    func icon(for path: String) -> NSImage {
        let key = path as NSString
        
        // Return cached if available
        if let cached = cache.object(forKey: key) {
            return cached
        }
        
        // Generate new icon (this happens on the actor's thread, background)
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: key)
        return icon
    }
    
    /// Pre-warm cache for a list of paths
    func prewarm(paths: [String]) {
        for path in paths {
            let _ = icon(for: path)
        }
    }
}
