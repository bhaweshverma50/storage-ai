import SwiftUI

struct AppDetailView: View {
    let apps: [AppEntry]
    var isRefreshing: Bool = false
    var onCleanup: ((Int64, [URL]) -> Void)?  // Callback when cleanup happens: bytes freed + trashed URLs
    var onRefresh: (() -> Void)?       // Re-analyze apps on demand (list is cached between scans)
    @State private var searchText = ""
    @State private var selectedApp: AppEntry?
    @State private var sortOrder: SortOrder = .totalDesc
    @Environment(\.accentTheme) private var accentTheme
    
    enum SortOrder: String, CaseIterable {
        case totalDesc = "Total Size"
        case bundleDesc = "Bundle Size"
        case cacheDesc = "Cache Size"
        case nameAsc = "Name A-Z"
    }
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Header with search
                // Padding standardized to 20
                header
                    .padding(20)
                    .background(.ultraThinMaterial)
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Stats row
                        statsRow(width: geometry.size.width - 40) // 20 padding each side
                        
                        // Apps list
                        appsSection
                    }
                    .padding(20)
                }
            }
        }
        .sheet(item: $selectedApp) { app in
            AppDetailSheet(app: app, onCleanup: onCleanup)
        }
    }
    
    // MARK: - Header
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Applications")
                    .font(.title2.weight(.bold)) // Adjusted font for cleaner look
                
                Text("Analyze app storage and clean up cache data")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search apps...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .frame(width: 250)

            // Re-analyze on demand — the list is served from cache between scans, so sizes
            // go stale after deletes that happen outside a cleanup action.
            if let onRefresh {
                Button(action: onRefresh) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing)
                .help("Re-analyze apps and their data sizes")
                .accessibilityLabel("Refresh app list")
            }
        }
    }
    
    // MARK: - Stats Row
    private func statsRow(width: CGFloat) -> some View {
        let spacing: CGFloat = 12
        // Cards flex equally via maxWidth: .infinity, so no per-card width is computed here.
        return HStack(spacing: spacing) {
            StatBentoCard(
                title: "Applications",
                value: "\(filteredApps.count)",
                icon: "square.grid.2x2",
                color: .blue
            )
            
            StatBentoCard(
                title: "Total Size",
                value: Formatters.bytes(totalBundleSize),
                icon: "app.badge",
                color: .purple
            )
            
            StatBentoCard(
                title: "Cache",
                value: Formatters.bytes(totalCleanable),
                icon: "archivebox",
                color: .orange
            )
            
            StatBentoCard(
                title: "Support Data",
                value: Formatters.bytes(totalSupportSize),
                icon: "folder",
                color: .cyan
            )
        }
        .frame(height: 80)
    }
    
    // MARK: - Apps Section
    private var appsSection: some View {
        VStack(spacing: 0) {
            // Section Header
            HStack(spacing: 12) {
                Text("Installed Applications")
                    .font(.headline)
                
                Text("\(filteredApps.count) apps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                
                Spacer()
                
                // Sort Menu
                Menu {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Button {
                            sortOrder = order
                        } label: {
                            if sortOrder == order {
                                Label(order.rawValue, systemImage: "checkmark")
                            } else {
                                Text(order.rawValue)
                            }
                        }
                    }
                } label: {
                    Label(sortOrder.rawValue, systemImage: "arrow.up.arrow.down")
                        .font(.subheadline)
                }
                .menuStyle(.borderedButton)
                .frame(width: 150)
            }
            .padding(.bottom, 12)
            
            // List Content
            if filteredApps.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text(searchText.isEmpty ? "No applications detected" : "No apps match \"\(searchText)\"")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else {
                // Using LazyVStack inside ScrollView is okay for 100-200 apps,
                // BUT List is better for virtualization. However, since the whole page is scrolled (including stats),
                // we stick to LazyVStack but optimize the Row.
                // Standardizing container.
                
                LazyVStack(spacing: 1) { // 1px spacing for separator look
                    ForEach(sortedApps) { app in
                        AppListRow(app: app) {
                            selectedApp = app
                        }
                    }
                }
                .background(Color.secondary.opacity(0.1)) // Separator color
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.secondary.opacity(0.1), lineWidth: 1)
                )
            }
        }
    }
    
    // MARK: - Computed Properties
    private var filteredApps: [AppEntry] {
        if searchText.isEmpty { return apps }
        return apps.filter { app in
            app.name.localizedCaseInsensitiveContains(searchText) ||
            (app.bundleIdentifier?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
    
    private var sortedApps: [AppEntry] {
        switch sortOrder {
        case .totalDesc: return filteredApps.sorted { $0.totalBytes > $1.totalBytes }
        case .bundleDesc: return filteredApps.sorted { $0.bundleSizeBytes > $1.bundleSizeBytes }
        case .cacheDesc: return filteredApps.sorted { $0.cacheSizeBytes > $1.cacheSizeBytes }
        case .nameAsc: return filteredApps.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }
    
    private var totalBundleSize: Int64 { filteredApps.reduce(0) { $0 + $1.bundleSizeBytes } }
    private var totalCleanable: Int64 { filteredApps.reduce(0) { $0 + $1.cleanableBytes } }
    private var totalSupportSize: Int64 { filteredApps.reduce(0) { $0 + $1.supportSizeBytes } }
}

// MARK: - Stat Bento Card (Refined)
struct StatBentoCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.1))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(color)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2) // Subtle shadow
    }
}

// MARK: - App List Row (Optimized)
struct AppListRow: View {
    let app: AppEntry
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 16) {
            // Optimized Icon Loading
            CachedAsyncIcon(path: app.bundleURL.path, size: 40)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
            
            // App Info
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                
                HStack(spacing: 6) {
                    if let bundleId = app.bundleIdentifier {
                        Text(bundleId)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            
            Spacer()
            
            // Stats Grid - Fixed width columns for alignment
            HStack(spacing: 0) {
                // Bundle
                sizeColumn(title: "Bundle", size: app.bundleSizeBytes, color: .blue, width: 80)
                
                // Cache
                sizeColumn(title: "Cache", size: app.cacheSizeBytes, color: .orange, width: 80)
                
                // Data
                sizeColumn(title: "Data", size: app.supportSizeBytes + app.containerSizeBytes, color: .purple, width: 80)
            }
            .padding(.trailing, 10)
            
            // Total Size
            Text(Formatters.bytes(app.totalBytes))
                .font(.system(.body, design: .rounded, weight: .semibold))
                .frame(width: 80, alignment: .trailing)
            
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
                .frame(width: 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isHovered ? Color.primary.opacity(0.04) : Color("ListBackground")) // Use asset or fallback
        .background(.background) // Fallback for list bg
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { isHovered = $0 }
    }
    
    private func sizeColumn(title: String, size: Int64, color: Color, width: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(Formatters.bytes(size))
                .font(.caption.weight(.medium))
                .foregroundStyle(size > 0 ? color : .secondary.opacity(0.5))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(width: width, alignment: .trailing)
    }
}
