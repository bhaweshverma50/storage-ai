import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @State private var topApps: [AppEntry] = []
    @State private var cleanupTargets: [CleanupTarget] = []
    @State private var isLoadingApps = false
    @State private var isLoadingCleanup = false
    @State private var selectedNavItem: NavigationItem = .overview
    @State private var aiRecommendations: [String] = []
    @State private var isLoadingAI = false
    
    enum NavigationItem: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case categories = "Categories"
        case media = "Media"
        case applications = "Applications"
        case cleanup = "Cleanup"
        case settings = "Settings"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .overview: return "chart.pie"
            case .categories: return "folder"
            case .media: return "photo.stack"
            case .applications: return "square.grid.2x2"
            case .cleanup: return "trash"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                sidebar
            } detail: {
                detailView
            }
            .tint(accentTheme)
            
            // Developer status bar (only visible when dev mode is enabled)
            if appState.isDevModeEnabled {
                DevStatusBar()
            }
        }
        .task {
            await loadInitialData()
        }
        .onChange(of: appState.scanService.isScanning) { wasScanning, isScanning in
            // When scan finishes, reload app data
            if wasScanning && !isScanning && appState.scanService.summary.totalBytes > 0 {
                Task {
                    await loadAppData()
                }
            }
        }
    }
    
    @Environment(\.accentTheme) private var accentTheme
    @Environment(\.fontScale) private var fontScale
    
    // MARK: - Enhanced Sidebar with Disk Info
    private var sidebar: some View {
        List {
            Section {
                ForEach(NavigationItem.allCases) { item in
                    Button {
                        selectedNavItem = item
                    } label: {
                        HStack {
                            Label(item.rawValue, systemImage: item.icon)
                                .font(.system(size: 13 * fontScale))
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedNavItem == item ? accentTheme.opacity(0.9) : Color.clear)
                        )
                        .foregroundStyle(selectedNavItem == item ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                }
            }
            
            Section("Disk Storage") {
                VStack(alignment: .leading, spacing: 10) {
                    // Disk name and capacity
                    HStack {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(.secondary)
                        Text("Macintosh HD")
                            .font(.system(size: 12 * fontScale, weight: .medium))
                        Spacer()
                    }
                    
                    // Progress bar - always blue for disk
                    DiskProgressBar(
                        used: appState.scanService.summary.diskInfo.usedSpace,
                        total: appState.scanService.summary.diskInfo.totalSpace
                    )
                    
                    // Stats
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Formatters.bytes(appState.scanService.summary.diskInfo.usedSpace))
                                .font(.system(size: 12 * fontScale, weight: .semibold))
                            Text("Used")
                                .font(.system(size: 10 * fontScale))
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Formatters.bytes(appState.scanService.summary.diskInfo.freeSpace))
                                .font(.system(size: 12 * fontScale, weight: .semibold))
                            Text("Available")
                                .font(.system(size: 10 * fontScale))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            
            if appState.scanService.summary.totalBytes > 0 {
                Section("Scanned") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(Formatters.bytes(appState.scanService.summary.totalBytes))
                                .font(.system(size: 12 * fontScale, weight: .semibold))
                            Spacer()
                            Text("\(Formatters.number(appState.scanService.progress.scannedFiles)) files")
                                .font(.system(size: 12 * fontScale))
                                .foregroundStyle(.secondary)
                        }
                        
                        if let lastScan = appState.scanService.lastScanDate {
                            Text(Formatters.relativeDate(lastScan))
                                .font(.system(size: 10 * fontScale))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .listStyle(.sidebar)
        .tint(accentTheme)
        .accentColor(accentTheme)
        .navigationTitle("Storage AI")
        .frame(minWidth: 220)
    }
    
    // MARK: - Detail View
    @ViewBuilder
    private var detailView: some View {
        if appState.scanService.isLoadingCache {
            ProgressView("Loading...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch selectedNavItem {
            case .overview:
                OverviewView(
                    topApps: topApps,
                    aiRecommendations: aiRecommendations,
                    isLoadingAI: isLoadingAI,
                    onStartScan: startScan,
                    onCancelScan: { appState.scanService.cancelScan() },
                    onLoadAI: loadAIRecommendations
                )
                .environmentObject(appState)
            case .categories:
                CategoryDetailView()
            case .media:
                MediaViewerView()
            case .applications:
                AppDetailView(apps: topApps) { _ in
                    // Refresh disk usage and reload the app list so removed/uninstalled apps disappear.
                    appState.scanService.refreshDiskInfo()
                    Task { await loadAppData() }
                }
            case .cleanup:
                CleanupView(
                    targets: cleanupTargets,
                    isLoading: isLoadingCleanup,
                    isScanning: appState.scanService.isScanning,
                    onCleanupCompleted: {
                        appState.scanService.refreshDiskInfo()
                        await loadCleanupTargets()
                    }
                )
            case .settings:
                SettingsView()
            }
        }
    }
    
    // MARK: - Data Loading
    private func loadInitialData() async {
        // Await the cache load rather than polling isLoadingCache for up to 2.5s — this can't
        // time out before the cache is ready, and adds no artificial latency.
        await appState.scanService.awaitCacheLoad()

        // Only load app data if we have cached scan data
        // This prevents permission popups on every app launch
        guard appState.scanService.summary.totalBytes > 0 else {
            return
        }
        
        // Try to load cached apps first
        do {
            if let cachedApps = try await ScanDataStore.shared.loadApps(), !cachedApps.isEmpty {
                await MainActor.run {
                    topApps = cachedApps.sorted { $0.totalBytes > $1.totalBytes }
                }
                // Also load cleanup targets in background
                await loadCleanupTargets()
                return
            }
        } catch {
            print("Failed to load cached apps: \(error)")
        }
        
        // If no cached apps, compute fresh
        await loadAppData()
    }
    
    private func loadAppData() async {
        isLoadingApps = true
        
        let apps = await Task.detached {
            AppAttribution.analyzeApps()
                .sorted { $0.totalBytes > $1.totalBytes }
                .prefix(50)
                .map { $0 }
        }.value
        
        // Save apps to cache
        do {
            try await ScanDataStore.shared.saveApps(Array(apps))
        } catch {
            print("Failed to save apps cache: \(error)")
        }
        
        await loadCleanupTargets()
        
        await MainActor.run {
            topApps = Array(apps)
            isLoadingApps = false
        }
    }
    
    private func loadCleanupTargets() async {
        await MainActor.run {
            isLoadingCleanup = true
        }
        
        let targets = await Task.detached {
            let service = CleanupService()
            service.buildTargets()
            return service.targets
        }.value
        
        await MainActor.run {
            cleanupTargets = targets
            isLoadingCleanup = false
        }
    }
    
    private func startScan() {
        appState.scanService.startScan(settings: appState.settings,
                                       roots: ScanRootsBuilder.roots(settings: appState.settings))
    }
    
    private func loadAIRecommendations() {
        guard appState.settings.ollamaEnabled else { return }
        
        isLoadingAI = true
        
        Task {
            let summary = appState.scanService.summary
            let prompt = """
            Analyze this Mac storage data and provide 3-4 specific, actionable cleanup recommendations:
            
            Total scanned: \(Formatters.bytes(summary.totalBytes))
            Categories:
            \(summary.buckets.map { "- \($0.category.displayName): \(Formatters.bytes($0.bytes))" }.joined(separator: "\n"))
            
            Top apps by size:
            \(topApps.prefix(5).map { "- \($0.name): \(Formatters.bytes($0.totalBytes))" }.joined(separator: "\n"))
            
            Give brief, actionable tips. Format as a simple bullet list without explanations.
            """
            
            if let response = await Recommendations.llmSummary(prompt: prompt) {
                await MainActor.run {
                    aiRecommendations = response
                        .components(separatedBy: "\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        // Strip bullets AND numbered prefixes ("1." / "2)") that small models emit.
                        .map { $0.replacingOccurrences(of: "^\\s*(?:[-•*]|\\d+[.)])\\s*", with: "", options: .regularExpression) }
                    isLoadingAI = false
                }
            } else {
                await MainActor.run {
                    aiRecommendations = Recommendations.ruleBased(summary: summary, topApps: topApps)
                    isLoadingAI = false
                }
            }
        }
    }
}

// MARK: - Disk Progress Bar (Always Blue)
struct DiskProgressBar: View {
    let used: Int64
    let total: Int64
    
    private var percentage: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }
    
    private var barColor: Color {
        if percentage > 0.9 { return .red }
        if percentage > 0.75 { return .orange }
        return .blue
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                
                RoundedRectangle(cornerRadius: 3)
                    .fill(barColor)
                    .frame(width: geometry.size.width * CGFloat(percentage))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Overview View (Bento Box Layout)
struct OverviewView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accentTheme) private var accentTheme
    @Environment(\.fontScale) private var fontScale
    let topApps: [AppEntry]
    let aiRecommendations: [String]
    let isLoadingAI: Bool
    let onStartScan: () -> Void
    let onCancelScan: () -> Void
    let onLoadAI: () -> Void
    
    @State private var scanButtonPressed = false
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    // Header
                    header
                    
                    // Scan Progress
                    if appState.scanService.isScanning || scanButtonPressed {
                        ScanProgressCard(progress: appState.scanService.progress)
                            .transition(.opacity)
                    }
                    
                    // Error
                    if let error = appState.scanService.lastError {
                        errorBanner(error)
                    }

                    // Access advisory (non-fatal): scan likely under-reported without Full Disk Access
                    if let warning = appState.scanService.accessWarning {
                        accessWarningBanner(warning)
                    }
                    
                    // Bento Grid
                    bentoGrid(width: geometry.size.width - 48)
                }
                .padding(24)
            }
        }
        .onChange(of: appState.scanService.isScanning) { _, isScanning in
            if !isScanning {
                withAnimation { scanButtonPressed = false }
            }
        }
    }
    
    // MARK: - Header
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Storage Overview")
                    .font(.title.weight(.semibold))
                
                if let lastScan = appState.scanService.lastScanDate {
                    Text("Last scan: \(Formatters.relativeDate(lastScan))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            scanButton
        }
    }
    
    @ViewBuilder
    private var scanButton: some View {
        if appState.scanService.isScanning || scanButtonPressed {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Scanning...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Button("Cancel") {
                    onCancelScan()
                    scanButtonPressed = false
                }
                .buttonStyle(.bordered)
            }
        } else {
            Button {
                withAnimation { scanButtonPressed = true }
                onStartScan()
            } label: {
                Label(appState.scanService.scanButtonTitle, systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(error)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.red)
        .padding(12)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func accessWarningBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
            Text(message)
            Spacer()
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.caption.weight(.medium))
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    // MARK: - Bento Grid Layout
    private func bentoGrid(width: CGFloat) -> some View {
        let spacing: CGFloat = 16
        let halfWidth = (width - spacing) / 2

        return VStack(spacing: spacing) {
            // Row 1: Chart + Categories
            HStack(spacing: spacing) {
                // Distribution Chart
                BentoCard {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Distribution")
                                .font(.system(size: 14 * fontScale, weight: .medium))
                            Spacer()
                        }
                        
                        if appState.scanService.summary.totalBytes > 0 {
                            DonutChart(
                                segments: appState.scanService.summary.buckets
                                    .filter { $0.bytes > 0 }
                                    .map { ($0.category.color, Double($0.bytes), $0.category.displayName) }
                            )
                            .frame(maxWidth: .infinity)
                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "chart.pie")
                                    .font(.system(size: 32 * fontScale))
                                    .foregroundStyle(.tertiary)
                                Text("Run a scan")
                                    .font(.system(size: 12 * fontScale))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(width: halfWidth, height: 240)
                
                // Categories
                BentoCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Categories")
                                .font(.system(size: 14 * fontScale, weight: .medium))
                            Spacer()
                            if appState.scanService.summary.totalBytes > 0 {
                                Text(Formatters.bytes(appState.scanService.summary.totalBytes))
                                    .font(.system(size: 12 * fontScale))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        if appState.scanService.summary.totalBytes > 0 {
                            ScrollView {
                                VStack(spacing: 6) {
                                    ForEach(appState.scanService.summary.buckets.sorted { $0.bytes > $1.bytes }) { bucket in
                                        if bucket.bytes > 0 {
                                            CompactCategoryRow(
                                                bucket: bucket,
                                                totalBytes: appState.scanService.summary.totalBytes
                                            )
                                        }
                                    }
                                }
                            }
                        } else {
                            Spacer()
                            Text("No data")
                                .font(.system(size: 12 * fontScale))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                            Spacer()
                        }
                    }
                }
                .frame(width: halfWidth, height: 240)
            }
            
            // Row 2: Recommendations + Top Apps
            HStack(spacing: spacing) {
                // Recommendations
                BentoCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "lightbulb")
                                .foregroundStyle(.yellow)
                            Text("Recommendations")
                                .font(.system(size: 14 * fontScale, weight: .medium))
                            Spacer()
                            
                            if appState.scanService.summary.totalBytes > 0 {
                                Button {
                                    onLoadAI()
                                } label: {
                                    Image(systemName: isLoadingAI ? "hourglass" : "arrow.clockwise")
                                        .font(.system(size: 12 * fontScale))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .disabled(isLoadingAI)
                                .accessibilityLabel(isLoadingAI ? "Refreshing recommendations" : "Refresh recommendations")
                            }
                        }
                        
                        if isLoadingAI {
                            Spacer()
                            HStack {
                                Spacer()
                                ProgressView()
                                Text("Analyzing...")
                                    .font(.system(size: 12 * fontScale))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            Spacer()
                        } else {
                            let recs = aiRecommendations.isEmpty 
                                ? Recommendations.ruleBased(summary: appState.scanService.summary, topApps: topApps)
                                : aiRecommendations
                            
                            if recs.isEmpty {
                                Spacer()
                                Text("Run a scan to get recommendations")
                                    .font(.system(size: 12 * fontScale))
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity)
                                Spacer()
                            } else {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(Array(recs.prefix(6).enumerated()), id: \.offset) { index, rec in
                                            // Check if this is an intro line (not an actual recommendation)
                                            let isIntroLine = index == 0 && (
                                                rec.lowercased().contains("here are") ||
                                                rec.lowercased().contains("based on") ||
                                                rec.lowercased().contains("recommendations:")
                                            )
                                            
                                            if isIntroLine {
                                                Text(rec)
                                                    .font(.system(size: 12 * fontScale))
                                                    .foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            } else {
                                                HStack(alignment: .top, spacing: 8) {
                                                    Circle()
                                                        .fill(Color.blue)
                                                        .frame(width: 5, height: 5)
                                                        .padding(.top, 6)
                                                    Text(rec)
                                                        .font(.system(size: 12 * fontScale))
                                                        .fixedSize(horizontal: false, vertical: true)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(width: halfWidth, height: 200)
                
                // Top Apps
                BentoCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Largest Apps")
                            .font(.system(size: 14 * fontScale, weight: .medium))
                        
                        if appState.scanService.summary.totalBytes == 0 {
                            // No scan data yet
                            Spacer()
                            Text("Run a scan first")
                                .font(.system(size: 12 * fontScale))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                            Spacer()
                        } else if topApps.isEmpty {
                            // Has scan data but no apps loaded yet or none found
                            Spacer()
                            Text("No applications detected")
                                .font(.system(size: 12 * fontScale))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                            Spacer()
                        } else {
                            ScrollView {
                                VStack(spacing: 8) {
                                    ForEach(topApps.prefix(5)) { app in
                                        CompactAppRow(app: app)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(width: halfWidth, height: 200)
            }
        }
    }
}

// MARK: - Bento Card
struct BentoCard<Content: View>: View {
    let content: Content
    
    @Environment(\.colorScheme) private var colorScheme
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(colorScheme == .dark ? 0.1 : 0.3),
                        lineWidth: 1
                    )
            }
    }
}

// MARK: - Compact Category Row
struct CompactCategoryRow: View {
    let bucket: StorageBucket
    let totalBytes: Int64
    
    @Environment(\.fontScale) private var fontScale
    
    private var percentage: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bucket.bytes) / Double(totalBytes) * 100
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: bucket.category.icon)
                .font(.system(size: 12 * fontScale))
                .foregroundStyle(bucket.category.color)
                .frame(width: 22)
            
            Text(bucket.category.displayName)
                .font(.system(size: 12 * fontScale))
                .lineLimit(1)
            
            Spacer()
            
            Text(Formatters.bytes(bucket.bytes))
                .font(.system(size: 12 * fontScale))
                .foregroundStyle(.secondary)
            
            // Mini progress
            RoundedRectangle(cornerRadius: 2)
                .fill(bucket.category.color)
                .frame(width: 40 * CGFloat(percentage / 100), height: 4)
                .frame(width: 40, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 2))
        }
    }
}

// MARK: - Compact App Row
struct CompactAppRow: View {
    let app: AppEntry
    
    @Environment(\.fontScale) private var fontScale
    
    var body: some View {
        HStack(spacing: 8) {
            if let icon = app.iconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 26 * fontScale, height: 26 * fontScale)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 26 * fontScale, height: 26 * fontScale)
            }
            
            Text(app.name)
                .font(.system(size: 12 * fontScale))
                .lineLimit(1)
            
            Spacer()
            
            Text(Formatters.bytes(app.totalBytes))
                .font(.system(size: 12 * fontScale))
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    DashboardView()
        .environmentObject(AppState())
        .frame(width: 1000, height: 700)
}
