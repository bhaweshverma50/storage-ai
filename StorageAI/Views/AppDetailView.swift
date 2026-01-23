import SwiftUI

struct AppDetailView: View {
    let apps: [AppEntry]
    var onCleanup: ((Int64) -> Void)?  // Callback when cleanup happens, with bytes freed
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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header with search
                    header
                    
                    // Stats row
                    statsRow(width: geometry.size.width - 48)
                    
                    // Apps list
                    appsSection
                }
                .padding(24)
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
                    .font(.title.weight(.semibold))
                
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
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .frame(width: 220)
        }
    }
    
    // MARK: - Stats Row
    private func statsRow(width: CGFloat) -> some View {
        let spacing: CGFloat = 12
        let cardWidth = (width - spacing * 3) / 4
        
        return HStack(spacing: spacing) {
            StatBentoCard(
                title: "Applications",
                value: "\(filteredApps.count)",
                icon: "square.grid.2x2",
                color: .blue
            )
            .frame(width: cardWidth, height: 90)
            
            StatBentoCard(
                title: "Total Size",
                value: Formatters.bytes(totalBundleSize),
                icon: "app.badge",
                color: .purple
            )
            .frame(width: cardWidth, height: 90)
            
            StatBentoCard(
                title: "Cache",
                value: Formatters.bytes(totalCleanable),
                icon: "archivebox",
                color: .orange
            )
            .frame(width: cardWidth, height: 90)
            
            StatBentoCard(
                title: "Support Data",
                value: Formatters.bytes(totalSupportSize),
                icon: "folder",
                color: .cyan
            )
            .frame(width: cardWidth, height: 90)
        }
    }
    
    // MARK: - Apps Section
    private var appsSection: some View {
        BentoCard {
            VStack(alignment: .leading, spacing: 12) {
                // Header with sort
                HStack(spacing: 12) {
                    Text("Installed Applications")
                        .font(.subheadline.weight(.medium))
                    
                    Text("• \(filteredApps.count) apps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    // Sorting buttons with proper sizing
                    HStack(spacing: 2) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Button {
                                sortOrder = order
                            } label: {
                                Text(order.rawValue)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                            .background(sortOrder == order ? accentTheme : Color.clear)
                            .foregroundStyle(sortOrder == order ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(3)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.trailing, 4)
                
                Divider()
                
                if filteredApps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "square.grid.2x2")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text(searchText.isEmpty ? "No applications detected" : "No apps match your search")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(sortedApps) { app in
                            AppListRow(app: app) {
                                selectedApp = app
                            }
                            
                            if app.id != sortedApps.last?.id {
                                Divider()
                                    .padding(.leading, 56)
                            }
                        }
                    }
                }
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

// MARK: - Stat Bento Card
struct StatBentoCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.1 : 0.3), lineWidth: 1)
        }
    }
}

// MARK: - App List Row
struct AppListRow: View {
    let app: AppEntry
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 12) {
            // App Icon
            if let icon = app.iconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            } else {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "app")
                            .foregroundStyle(.secondary)
                    }
            }
            
            // App Info
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                
                if let bundleId = app.bundleIdentifier {
                    Text(bundleId)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Size breakdown
            HStack(spacing: 20) {
                SizeLabel(title: "Bundle", size: app.bundleSizeBytes, color: .blue)
                SizeLabel(title: "Cache", size: app.cacheSizeBytes, color: .orange)
                SizeLabel(title: "Data", size: app.supportSizeBytes + app.containerSizeBytes, color: .purple)
            }
            
            // Total
            VStack(alignment: .trailing, spacing: 1) {
                Text(Formatters.bytes(app.totalBytes))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                Text("Total")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 80)
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            action()
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Size Label
struct SizeLabel: View {
    let title: String
    let size: Int64
    let color: Color
    
    var body: some View {
        VStack(spacing: 1) {
            Text(Formatters.bytes(size))
                .font(.caption.weight(.medium))
                .foregroundStyle(size > 0 ? color : .secondary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 60)
    }
}

// MARK: - App Detail Sheet
struct AppDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accentTheme) private var accentTheme
    let app: AppEntry
    var onCleanup: ((Int64) -> Void)?  // Callback with bytes cleaned
    
    @State private var showCleanCacheAlert = false
    @State private var showRemoveDataAlert = false
    @State private var showUninstallAlert = false
    @State private var isProcessing = false
    @State private var operationResult: String?
    @State private var operationError: String?
    
    // Track current sizes (start with app's values, update after cleanup)
    @State private var currentCacheSize: Int64 = 0
    @State private var currentSupportSize: Int64 = 0
    @State private var currentContainerSize: Int64 = 0
    @State private var currentBundleSize: Int64 = 0
    @State private var currentOtherDataSize: Int64 = 0  // Prefs + saved state
    @State private var didInitializeSizes = false
    
    // Computed properties for current totals
    private var currentTotalBytes: Int64 {
        currentBundleSize + currentSupportSize + currentCacheSize + currentContainerSize + currentOtherDataSize
    }
    
    private var currentCleanableBytes: Int64 {
        currentCacheSize + currentContainerSize
    }
    
    /// Check if this is an orphaned app (has data but no actual .app bundle)
    private var isOrphanedApp: Bool {
        app.bundleSizeBytes == 0 || !app.bundleURL.pathExtension.lowercased().contains("app")
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 14) {
                if let icon = app.iconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.title3.bold())
                    
                    if let bundleId = app.bundleIdentifier {
                        Text(bundleId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Text("Total: \(Formatters.bytes(currentTotalBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .onAppear {
                if !didInitializeSizes {
                    currentBundleSize = app.bundleSizeBytes
                    currentSupportSize = app.supportSizeBytes
                    currentCacheSize = app.cacheSizeBytes
                    currentContainerSize = app.containerSizeBytes
                    currentOtherDataSize = calculateOtherDataSize()
                    didInitializeSizes = true
                }
            }
            
            Divider()
            
            ScrollView {
                VStack(spacing: 16) {
                    // Storage breakdown
                    BentoCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Storage Breakdown")
                                .font(.subheadline.weight(.medium))
                            
                            // Visual bar
                            GeometryReader { geometry in
                                HStack(spacing: 2) {
                                    if currentBundleSize > 0 {
                                        Rectangle().fill(Color.blue)
                                            .frame(width: geometry.size.width * proportion(currentBundleSize))
                                    }
                                    if currentSupportSize > 0 {
                                        Rectangle().fill(Color.purple)
                                            .frame(width: geometry.size.width * proportion(currentSupportSize))
                                    }
                                    if currentCacheSize > 0 {
                                        Rectangle().fill(Color.orange)
                                            .frame(width: geometry.size.width * proportion(currentCacheSize))
                                    }
                                    if currentContainerSize > 0 {
                                        Rectangle().fill(Color.cyan)
                                            .frame(width: geometry.size.width * proportion(currentContainerSize))
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .frame(height: 20)
                            
                            // Legend
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                LegendRow(color: .blue, title: "Bundle", size: currentBundleSize)
                                LegendRow(color: .purple, title: "Support", size: currentSupportSize)
                                LegendRow(color: .orange, title: "Cache", size: currentCacheSize)
                                LegendRow(color: .cyan, title: "Containers", size: currentContainerSize)
                            }
                        }
                    }
                    
                    // Actions
                    BentoCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Actions")
                                .font(.subheadline.weight(.medium))
                            
                            HStack(spacing: 10) {
                                Button {
                                    NSWorkspace.shared.selectFile(app.bundleURL.path, inFileViewerRootedAtPath: "/Applications")
                                } label: {
                                    Label("Reveal", systemImage: "folder")
                                }
                                .buttonStyle(.bordered)
                                
                                Button {
                                    NSWorkspace.shared.open(app.bundleURL)
                                } label: {
                                    Label("Open", systemImage: "arrow.up.right.square")
                                }
                                .buttonStyle(.bordered)
                            }
                            
                            if currentCleanableBytes > 0 {
                                Divider()
                                
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Cleanable Data")
                                            .font(.caption.weight(.medium))
                                        Text("Cache data that can be removed")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Text(Formatters.bytes(currentCleanableBytes))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    
                    // Cleanup Section
                    BentoCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Cleanup")
                                .font(.subheadline.weight(.medium))
                            
                            // Result/Error messages
                            if let result = operationResult {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text(result)
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                            }
                            
                            if let error = operationError {
                                HStack {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.red)
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                            }
                            
                            // Clean Cache
                            if currentCacheSize > 0 {
                                cleanupRow(
                                    icon: "trash",
                                    iconColor: .orange,
                                    title: "Clean Cache",
                                    description: "Remove cached files only",
                                    size: currentCacheSize,
                                    action: { showCleanCacheAlert = true }
                                )
                            }
                            
                            // Remove App Data
                            if currentCleanableBytes > 0 || currentSupportSize > 0 {
                                cleanupRow(
                                    icon: "folder.badge.minus",
                                    iconColor: .purple,
                                    title: "Remove App Data",
                                    description: "Remove cache, containers & support files",
                                    size: currentSupportSize + currentCacheSize + currentContainerSize,
                                    action: { showRemoveDataAlert = true }
                                )
                            }
                            
                            // Only show Uninstall for real apps (not orphaned data)
                            if !isOrphanedApp {
                                Divider()
                                
                                // Uninstall App
                                cleanupRow(
                                    icon: "trash.fill",
                                    iconColor: .red,
                                    title: "Uninstall App",
                                    description: "Move app to Trash and remove all data",
                                    size: currentTotalBytes,
                                    isDestructive: true,
                                    action: { showUninstallAlert = true }
                                )
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 450, height: 520)
        .alert("Clean Cache", isPresented: $showCleanCacheAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clean", role: .destructive) { cleanCache() }
        } message: {
            Text("This will remove \(Formatters.bytes(currentCacheSize)) of cached data for \(app.name). The app will recreate cache as needed.")
        }
        .alert("Remove App Data", isPresented: $showRemoveDataAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { removeAppData() }
        } message: {
            Text("This will remove all support files, cache, and container data for \(app.name). The app itself will remain installed but may need to be set up again.")
        }
        .alert("Uninstall \(app.name)?", isPresented: $showUninstallAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) { uninstallApp() }
        } message: {
            Text("This will move \(app.name) to Trash and remove all associated data (\(Formatters.bytes(currentTotalBytes))). You can restore it from Trash if needed.")
        }
    }
    
    // MARK: - Cleanup Row
    private func cleanupRow(
        icon: String,
        iconColor: Color,
        title: String,
        description: String,
        size: Int64,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .background(iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Text(Formatters.bytes(size))
                .font(.caption.weight(.semibold))
                .foregroundStyle(iconColor)
            
            Button {
                action()
            } label: {
                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Text(isDestructive ? "Uninstall" : "Clean")
                        .font(.caption.weight(.medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(isDestructive ? .red : accentTheme)
            .controlSize(.small)
            .disabled(isProcessing)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
    
    private func proportion(_ bytes: Int64) -> CGFloat {
        guard currentTotalBytes > 0 else { return 0 }
        return CGFloat(bytes) / CGFloat(currentTotalBytes)
    }
    
    // MARK: - Cleanup Actions
    
    private var cachePaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths: [URL] = []
        var addedPaths: Set<String> = []
        
        // ~/Library/Caches/{appName}
        let cachesByName = home.appendingPathComponent("Library/Caches/\(app.name)")
        if FileManager.default.fileExists(atPath: cachesByName.path) {
            paths.append(cachesByName)
            addedPaths.insert(cachesByName.path)
        }
        
        // ~/Library/Caches/{bundleIdentifier}
        if let bundleId = app.bundleIdentifier {
            let cachesByBundleId = home.appendingPathComponent("Library/Caches/\(bundleId)")
            if FileManager.default.fileExists(atPath: cachesByBundleId.path),
               !addedPaths.contains(cachesByBundleId.path) {
                paths.append(cachesByBundleId)
            }
        }
        
        return paths
    }
    
    private var allDataPaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths: [URL] = []
        var addedPaths: Set<String> = []  // Track added paths to avoid duplicates
        
        // ~/Library/Caches/{appName}
        let cachesByName = home.appendingPathComponent("Library/Caches/\(app.name)")
        if FileManager.default.fileExists(atPath: cachesByName.path) {
            paths.append(cachesByName)
            addedPaths.insert(cachesByName.path)
        }
        
        // ~/Library/Caches/{bundleIdentifier}
        if let bundleId = app.bundleIdentifier {
            let cachesByBundleId = home.appendingPathComponent("Library/Caches/\(bundleId)")
            if FileManager.default.fileExists(atPath: cachesByBundleId.path),
               !addedPaths.contains(cachesByBundleId.path) {
                paths.append(cachesByBundleId)
                addedPaths.insert(cachesByBundleId.path)
            }
        }
        
        // ~/Library/Application Support/{appName}
        let supportByName = home.appendingPathComponent("Library/Application Support/\(app.name)")
        if FileManager.default.fileExists(atPath: supportByName.path) {
            paths.append(supportByName)
            addedPaths.insert(supportByName.path)
        }
        
        // ~/Library/Application Support/{bundleIdentifier}
        if let bundleId = app.bundleIdentifier {
            let supportByBundleId = home.appendingPathComponent("Library/Application Support/\(bundleId)")
            if FileManager.default.fileExists(atPath: supportByBundleId.path),
               !addedPaths.contains(supportByBundleId.path) {
                paths.append(supportByBundleId)
                addedPaths.insert(supportByBundleId.path)
            }
            
            // ~/Library/Containers/{bundleIdentifier}
            let containers = home.appendingPathComponent("Library/Containers/\(bundleId)")
            if FileManager.default.fileExists(atPath: containers.path) {
                paths.append(containers)
                addedPaths.insert(containers.path)
            }
            
            // ~/Library/Group Containers/{bundleIdentifier}
            let groupContainers = home.appendingPathComponent("Library/Group Containers/\(bundleId)")
            if FileManager.default.fileExists(atPath: groupContainers.path) {
                paths.append(groupContainers)
                addedPaths.insert(groupContainers.path)
            }
            
            // Dynamically match additional group containers by team ID or bundle ID suffix
            // This matches the logic in AppAttribution.relatedSupportPaths()
            let groupContainersDir = home.appendingPathComponent("Library/Group Containers")
            if let contents = try? FileManager.default.contentsOfDirectory(at: groupContainersDir, includingPropertiesForKeys: nil) {
                let bundleComponents = bundleId.components(separatedBy: ".")
                let teamId = bundleComponents.first ?? ""
                
                for item in contents {
                    let containerName = item.lastPathComponent
                    // Skip if already added
                    if addedPaths.contains(item.path) { continue }
                    
                    let containerComponents = containerName.components(separatedBy: ".")
                    let containerTeamId = containerComponents.first ?? ""
                    
                    // Match by team ID if both have one (team IDs are typically 10 alphanumeric chars)
                    let hasMatchingTeamId = teamId.count >= 8 && containerTeamId == teamId
                    
                    // Match by full bundle ID suffix (e.g., "UBF8T346G9.com.microsoft.Word" matches bundle "com.microsoft.Word")
                    let hasMatchingSuffix = containerName.lowercased().hasSuffix(".\(bundleId.lowercased())")
                    
                    if hasMatchingTeamId || hasMatchingSuffix {
                        if FileManager.default.fileExists(atPath: item.path) {
                            paths.append(item)
                            addedPaths.insert(item.path)
                        }
                    }
                }
            }
            
            // ~/Library/Preferences/{bundleIdentifier}.plist
            let prefs = home.appendingPathComponent("Library/Preferences/\(bundleId).plist")
            if FileManager.default.fileExists(atPath: prefs.path) {
                paths.append(prefs)
            }
            
            // ~/Library/Saved Application State/{bundleIdentifier}.savedState
            let savedState = home.appendingPathComponent("Library/Saved Application State/\(bundleId).savedState")
            if FileManager.default.fileExists(atPath: savedState.path) {
                paths.append(savedState)
            }
        }
        
        return paths
    }
    
    private func cleanCache() {
        isProcessing = true
        operationResult = nil
        operationError = nil
        
        let bytesBeforeClean = currentCacheSize
        
        Task {
            var successCount = 0
            var failCount = 0
            
            for path in cachePaths {
                let deleted = deletePathSafely(path)
                if deleted { successCount += 1 } else { failCount += 1 }
            }
            
            // Recalculate actual cache size after cleanup
            let newCacheSize = recalculateCacheSize()
            let bytesFreed = bytesBeforeClean - newCacheSize
            
            await MainActor.run {
                currentCacheSize = newCacheSize
                isProcessing = false
                
                if bytesFreed > 0 {
                    if failCount > 0 {
                        operationResult = "Cleaned \(Formatters.bytes(bytesFreed)) (some items need Full Disk Access)"
                    } else {
                        operationResult = "Cleaned \(Formatters.bytes(bytesFreed)) of cache"
                    }
                    onCleanup?(bytesFreed)
                } else if failCount > 0 {
                    operationError = "Permission denied. Grant Full Disk Access in System Settings → Privacy & Security."
                } else {
                    operationResult = "Cache already clean"
                }
            }
        }
    }
    
    /// Safely delete a path - tries multiple methods and deletes contents if container is protected
    private func deletePathSafely(_ path: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else { return true }
        
        // First, try moving to Trash (often works for protected items)
        do {
            try fm.trashItem(at: path, resultingItemURL: nil)
            return true
        } catch {
            // Trash failed, try direct removal
        }
        
        // Try direct removal
        do {
            try fm.removeItem(at: path)
            return true
        } catch {
            // Direct removal failed
        }
        
        // For directories, try to delete contents instead
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path.path, isDirectory: &isDir) && isDir.boolValue {
            return deleteContents(of: path)
        }
        
        return false
    }
    
    /// Delete contents of a directory (useful for protected containers)
    private func deleteContents(of directory: URL) -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        
        var deletedAny = false
        for item in contents {
            // Try trash first, then remove
            do {
                try fm.trashItem(at: item, resultingItemURL: nil)
                deletedAny = true
            } catch {
                do {
                    try fm.removeItem(at: item)
                    deletedAny = true
                } catch {
                    // Skip items that can't be deleted
                }
            }
        }
        return deletedAny
    }
    
    private func recalculateCacheSize() -> Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var total: Int64 = 0
        var scannedPaths: Set<String> = []
        
        // Scan by app name
        let cachesByName = home.appendingPathComponent("Library/Caches/\(app.name)")
        if !scannedPaths.contains(cachesByName.path) {
            scannedPaths.insert(cachesByName.path)
            total += FileIndexer.sizeOfPath(cachesByName)
        }
        
        // Scan by bundle ID if available (only if different path to avoid double-counting)
        if let bundleId = app.bundleIdentifier {
            let cachesByBundleId = home.appendingPathComponent("Library/Caches/\(bundleId)")
            if !scannedPaths.contains(cachesByBundleId.path) {
                total += FileIndexer.sizeOfPath(cachesByBundleId)
            }
        }
        
        return total
    }
    
    private func recalculateSupportSize() -> Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var total: Int64 = 0
        var scannedPaths: Set<String> = []
        
        // Scan by bundle ID if available
        if let bundleId = app.bundleIdentifier {
            let support = home.appendingPathComponent("Library/Application Support/\(bundleId)")
            if !scannedPaths.contains(support.path) {
                scannedPaths.insert(support.path)
                total += FileIndexer.sizeOfPath(support)
            }
        }
        
        // Scan by app name (only if different from bundleId to avoid double-counting)
        let supportByName = home.appendingPathComponent("Library/Application Support/\(app.name)")
        if !scannedPaths.contains(supportByName.path) {
            total += FileIndexer.sizeOfPath(supportByName)
        }
        
        return total
    }
    
    private func recalculateContainerSize() -> Int64 {
        guard let bundleId = app.bundleIdentifier else { return 0 }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var total: Int64 = 0
        var scannedPaths: Set<String> = []
        
        // ~/Library/Containers/{bundleIdentifier}
        let containers = home.appendingPathComponent("Library/Containers/\(bundleId)")
        if !scannedPaths.contains(containers.path) {
            scannedPaths.insert(containers.path)
            total += FileIndexer.sizeOfPath(containers)
        }
        
        // ~/Library/Group Containers/{bundleIdentifier}
        let groupContainers = home.appendingPathComponent("Library/Group Containers/\(bundleId)")
        if !scannedPaths.contains(groupContainers.path) {
            scannedPaths.insert(groupContainers.path)
            total += FileIndexer.sizeOfPath(groupContainers)
        }
        
        // Dynamically match additional group containers by team ID or bundle ID suffix
        // This matches the logic in AppAttribution.relatedSupportPaths() and allDataPaths
        let groupContainersDir = home.appendingPathComponent("Library/Group Containers")
        if let contents = try? FileManager.default.contentsOfDirectory(at: groupContainersDir, includingPropertiesForKeys: nil) {
            let bundleComponents = bundleId.components(separatedBy: ".")
            let teamId = bundleComponents.first ?? ""
            
            for item in contents {
                let containerName = item.lastPathComponent
                // Skip if already added
                if scannedPaths.contains(item.path) { continue }
                
                let containerComponents = containerName.components(separatedBy: ".")
                let containerTeamId = containerComponents.first ?? ""
                
                // Match by team ID if both have one (team IDs are typically 10 alphanumeric chars)
                let hasMatchingTeamId = teamId.count >= 8 && containerTeamId == teamId
                
                // Match by full bundle ID suffix
                let hasMatchingSuffix = containerName.lowercased().hasSuffix(".\(bundleId.lowercased())")
                
                if hasMatchingTeamId || hasMatchingSuffix {
                    scannedPaths.insert(item.path)
                    total += FileIndexer.sizeOfPath(item)
                }
            }
        }
        
        return total
    }
    
    /// Calculate the size of preferences and saved application state
    private func calculateOtherDataSize() -> Int64 {
        guard let bundleId = app.bundleIdentifier else { return 0 }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var total: Int64 = 0
        
        // Preferences plist
        let prefs = home.appendingPathComponent("Library/Preferences/\(bundleId).plist")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: prefs.path),
           let size = attrs[.size] as? Int64 {
            total += size
        }
        
        // Saved Application State
        let savedState = home.appendingPathComponent("Library/Saved Application State/\(bundleId).savedState")
        total += FileIndexer.sizeOfPath(savedState)
        
        return total
    }
    
    /// Recalculate the size of preferences and saved application state after cleanup
    private func recalculateOtherDataSize() -> Int64 {
        return calculateOtherDataSize()
    }
    
    private func removeAppData() {
        isProcessing = true
        operationResult = nil
        operationError = nil
        
        // Include all data types in the calculation (cache, support, container, prefs, saved state)
        let bytesBeforeClean = currentCacheSize + currentSupportSize + currentContainerSize + currentOtherDataSize
        
        Task {
            var successCount = 0
            var failCount = 0
            
            for path in allDataPaths {
                let deleted = deletePathSafely(path)
                if deleted { successCount += 1 } else { failCount += 1 }
            }
            
            // Recalculate actual sizes after cleanup (including prefs and saved state)
            let newCacheSize = recalculateCacheSize()
            let newSupportSize = recalculateSupportSize()
            let newContainerSize = recalculateContainerSize()
            let newOtherDataSize = recalculateOtherDataSize()
            let totalBytesFreed = bytesBeforeClean - (newCacheSize + newSupportSize + newContainerSize + newOtherDataSize)
            
            await MainActor.run {
                currentCacheSize = newCacheSize
                currentSupportSize = newSupportSize
                currentContainerSize = newContainerSize
                currentOtherDataSize = newOtherDataSize
                isProcessing = false
                
                if totalBytesFreed > 0 {
                    if failCount > 0 && (newSupportSize > 0 || newContainerSize > 0) {
                        operationResult = "Removed \(Formatters.bytes(totalBytesFreed)). Some data needs Full Disk Access to remove."
                    } else {
                        operationResult = "Removed \(Formatters.bytes(totalBytesFreed)) of app data"
                    }
                    onCleanup?(totalBytesFreed)
                } else if failCount > 0 {
                    operationError = "Permission denied. Grant Full Disk Access in System Settings → Privacy & Security."
                } else {
                    operationResult = "No data to remove"
                }
            }
        }
    }
    
    private func uninstallApp() {
        // Safety check: don't uninstall orphaned apps (they don't have a real .app bundle)
        guard !isOrphanedApp else {
            operationError = "Cannot uninstall: This is orphaned app data, not an installed app. Use 'Remove App Data' instead."
            return
        }
        
        isProcessing = true
        operationResult = nil
        operationError = nil
        
        let totalBytesFreed = currentTotalBytes
        
        Task {
            var dataRemovalFailures: [String] = []
            
            // First remove app data - track failures instead of silently ignoring
            for path in allDataPaths {
                let deleted = deletePathSafely(path)
                if !deleted && FileManager.default.fileExists(atPath: path.path) {
                    dataRemovalFailures.append(path.lastPathComponent)
                }
            }
            
            do {
                // Move app bundle to trash
                try FileManager.default.trashItem(at: app.bundleURL, resultingItemURL: nil)
                
                // Recalculate actual sizes after cleanup (including prefs and saved state)
                let newCacheSize = recalculateCacheSize()
                let newSupportSize = recalculateSupportSize()
                let newContainerSize = recalculateContainerSize()
                let newOtherDataSize = recalculateOtherDataSize()
                let remainingDataSize = newCacheSize + newSupportSize + newContainerSize + newOtherDataSize
                let actualBytesFreed = totalBytesFreed - remainingDataSize
                
                await MainActor.run {
                    // Update sizes to reflect what's actually left
                    currentBundleSize = 0
                    currentCacheSize = newCacheSize
                    currentSupportSize = newSupportSize
                    currentContainerSize = newContainerSize
                    currentOtherDataSize = newOtherDataSize
                    
                    isProcessing = false
                    
                    if dataRemovalFailures.isEmpty && remainingDataSize == 0 {
                        operationResult = "\(app.name) uninstalled successfully"
                    } else if remainingDataSize > 0 {
                        operationResult = "\(app.name) uninstalled. Some data couldn't be removed (needs Full Disk Access)."
                    } else {
                        operationResult = "\(app.name) uninstalled successfully"
                    }
                    
                    // Notify parent
                    onCleanup?(actualBytesFreed)
                    
                    // Close sheet after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    operationError = "Failed to uninstall: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Legend Row
struct LegendRow: View {
    let color: Color
    let title: String
    let size: Int64
    
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(Formatters.bytes(size)).font(.caption.weight(.medium))
        }
    }
}

#Preview {
    AppDetailView(apps: [])
        .frame(width: 1000, height: 700)
}
