import SwiftUI

struct CachedAsyncIcon: View {
    let path: String
    let size: CGFloat
    
    @State private var icon: NSImage?
    @Environment(\.displayScale) private var displayScale
    
    var body: some View {
        Group {
            if let icon = icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear // Placeholder while loading
                    .overlay {
                        // Optional: Show generic icon instantly if needed
                        // Image(systemName: "doc") 
                    }
            }
        }
        .frame(width: size, height: size)
        .task(id: path) { // Re-load if path changes
            // Quick check for standard paths to avoid actor overhead for generic stuff if possible
            // But for file icons, actor is best.
            
            // Load from actor off main thread
            let loadedIcon = await IconCacheService.shared.icon(for: path)
            
            // Back on main thread, update UI
            self.icon = loadedIcon
        }
    }
}
