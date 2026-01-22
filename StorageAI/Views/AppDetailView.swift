import SwiftUI

struct AppDetailView: View {
    let apps: [AppEntry]
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
            AppDetailSheet(app: app)
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
    
    @State private var showCleanCacheAlert = false
    @State private var showRemoveDataAlert = false
    @State private var showUninstallAlert = false
    @State private var isProcessing = false
    @State private var operationResult: String?
    @State private var operationError: String?
    
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
                    
                    Text("Total: \(Formatters.bytes(app.totalBytes))")
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
                                    if app.bundleSizeBytes > 0 {
                                        Rectangle().fill(Color.blue)
                                            .frame(width: geometry.size.width * proportion(app.bundleSizeBytes))
                                    }
                                    if app.supportSizeBytes > 0 {
                                        Rectangle().fill(Color.purple)
                                            .frame(width: geometry.size.width * proportion(app.supportSizeBytes))
                                    }
                                    if app.cacheSizeBytes > 0 {
                                        Rectangle().fill(Color.orange)
                                            .frame(width: geometry.size.width * proportion(app.cacheSizeBytes))
                                    }
                                    if app.containerSizeBytes > 0 {
                                        Rectangle().fill(Color.cyan)
                                            .frame(width: geometry.size.width * proportion(app.containerSizeBytes))
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .frame(height: 20)
                            
                            // Legend
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                LegendRow(color: .blue, title: "Bundle", size: app.bundleSizeBytes)
                                LegendRow(color: .purple, title: "Support", size: app.supportSizeBytes)
                                LegendRow(color: .orange, title: "Cache", size: app.cacheSizeBytes)
                                LegendRow(color: .cyan, title: "Containers", size: app.containerSizeBytes)
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
                            
                            if app.cleanableBytes > 0 {
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
                                    
                                    Text(Formatters.bytes(app.cleanableBytes))
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
                            if app.cacheSizeBytes > 0 {
                                cleanupRow(
                                    icon: "trash",
                                    iconColor: .orange,
                                    title: "Clean Cache",
                                    description: "Remove cached files only",
                                    size: app.cacheSizeBytes,
                                    action: { showCleanCacheAlert = true }
                                )
                            }
                            
                            // Remove App Data
                            if app.cleanableBytes > 0 {
                                cleanupRow(
                                    icon: "folder.badge.minus",
                                    iconColor: .purple,
                                    title: "Remove App Data",
                                    description: "Remove cache, containers & support files",
                                    size: app.supportSizeBytes + app.cacheSizeBytes + app.containerSizeBytes,
                                    action: { showRemoveDataAlert = true }
                                )
                            }
                            
                            Divider()
                            
                            // Uninstall App
                            cleanupRow(
                                icon: "trash.fill",
                                iconColor: .red,
                                title: "Uninstall App",
                                description: "Move app to Trash and remove all data",
                                size: app.totalBytes,
                                isDestructive: true,
                                action: { showUninstallAlert = true }
                            )
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
            Text("This will remove \(Formatters.bytes(app.cacheSizeBytes)) of cached data for \(app.name). The app will recreate cache as needed.")
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
            Text("This will move \(app.name) to Trash and remove all associated data (\(Formatters.bytes(app.totalBytes))). You can restore it from Trash if needed.")
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
        guard app.totalBytes > 0 else { return 0 }
        return CGFloat(bytes) / CGFloat(app.totalBytes)
    }
    
    // MARK: - Cleanup Actions
    
    private var cachePaths: [URL] {
        guard let bundleId = app.bundleIdentifier else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths: [URL] = []
        
        // ~/Library/Caches/{bundleIdentifier}
        let caches = home.appendingPathComponent("Library/Caches/\(bundleId)")
        if FileManager.default.fileExists(atPath: caches.path) {
            paths.append(caches)
        }
        
        return paths
    }
    
    private var allDataPaths: [URL] {
        guard let bundleId = app.bundleIdentifier else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths: [URL] = []
        
        // ~/Library/Caches/{bundleIdentifier}
        let caches = home.appendingPathComponent("Library/Caches/\(bundleId)")
        if FileManager.default.fileExists(atPath: caches.path) {
            paths.append(caches)
        }
        
        // ~/Library/Application Support/{bundleIdentifier}
        let support = home.appendingPathComponent("Library/Application Support/\(bundleId)")
        if FileManager.default.fileExists(atPath: support.path) {
            paths.append(support)
        }
        
        // Also try app name for Application Support
        let supportByName = home.appendingPathComponent("Library/Application Support/\(app.name)")
        if FileManager.default.fileExists(atPath: supportByName.path) {
            paths.append(supportByName)
        }
        
        // ~/Library/Containers/{bundleIdentifier}
        let containers = home.appendingPathComponent("Library/Containers/\(bundleId)")
        if FileManager.default.fileExists(atPath: containers.path) {
            paths.append(containers)
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
        
        return paths
    }
    
    private func cleanCache() {
        isProcessing = true
        operationResult = nil
        operationError = nil
        
        Task {
            do {
                var deletedCount = 0
                for path in cachePaths {
                    try FileManager.default.removeItem(at: path)
                    deletedCount += 1
                }
                
                await MainActor.run {
                    isProcessing = false
                    operationResult = "Cleaned cache successfully"
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    operationError = error.localizedDescription
                }
            }
        }
    }
    
    private func removeAppData() {
        isProcessing = true
        operationResult = nil
        operationError = nil
        
        Task {
            do {
                var deletedCount = 0
                for path in allDataPaths {
                    try FileManager.default.removeItem(at: path)
                    deletedCount += 1
                }
                
                await MainActor.run {
                    isProcessing = false
                    operationResult = "Removed \(deletedCount) data locations"
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    operationError = error.localizedDescription
                }
            }
        }
    }
    
    private func uninstallApp() {
        isProcessing = true
        operationResult = nil
        operationError = nil
        
        Task {
            do {
                // First remove app data
                for path in allDataPaths {
                    try? FileManager.default.removeItem(at: path)
                }
                
                // Move app to trash
                try FileManager.default.trashItem(at: app.bundleURL, resultingItemURL: nil)
                
                await MainActor.run {
                    isProcessing = false
                    operationResult = "\(app.name) uninstalled successfully"
                    
                    // Close sheet after a delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    operationError = error.localizedDescription
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
