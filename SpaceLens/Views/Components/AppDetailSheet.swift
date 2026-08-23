import SwiftUI

// MARK: - App Detail Sheet
struct AppDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accentTheme) private var accentTheme
    let app: AppEntry
    var onCleanup: ((Int64, [URL]) -> Void)?  // Callback with bytes freed + trashed URLs
    
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
                // Use new CachedAsyncIcon for better perf here too
                CachedAsyncIcon(path: app.bundleURL.path, size: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 2)
                
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
                .accessibilityLabel("Close")
            }
            .padding(20)
            .background(.ultraThinMaterial) // Match the new aesthetic
            .onAppear {
                if !didInitializeSizes {
                    currentBundleSize = app.bundleSizeBytes
                    currentSupportSize = app.supportSizeBytes
                    currentCacheSize = app.cacheSizeBytes
                    currentContainerSize = app.containerSizeBytes
                    // Recalc other data logic if needed, or default to 0 for now as it wasn't in original struct
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
        .frame(width: 450, height: 550) // Increased height slightly for breathing room
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
    
    // MARK: - Path discovery

    /// Cache directories attributable to this app (by display name and bundle id).
    private var cachePaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [home.appendingPathComponent("Library/Caches/\(app.name)")]
        if let bundleId = app.bundleIdentifier {
            paths.append(home.appendingPathComponent("Library/Caches/\(bundleId)"))
        }
        return paths.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// All support/cache/container directories for this app. For orphaned data entries the
    /// bundleURL itself points at the data folder, so include it.
    private var dataPaths: [URL] {
        let related = AppAttribution.relatedSupportPaths(appName: app.name, bundleId: app.bundleIdentifier)
        var all = related.support + related.caches + related.containers
        if isOrphanedApp { all.append(app.bundleURL) }
        return all.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Real cleanup actions (move to Trash; never permanent, never simulated)

    /// Build an error message that says WHY nothing was trashed (e.g. a permissions failure),
    /// not just how many items were skipped — otherwise failures look like silent no-ops.
    private func failureSummary(_ prefix: String, outcome: DeleteEngine.Outcome) -> String {
        if let reason = outcome.failed.first?.reason {
            return "\(prefix): \(reason)"
        }
        if outcome.blockedCount > 0 {
            return "\(prefix): \(outcome.blockedCount) item(s) are outside the safe cleanup locations."
        }
        return "\(prefix) (\(outcome.failedCount + outcome.blockedCount) items skipped)."
    }

    private func cleanCache() {
        isProcessing = true
        operationError = nil
        operationResult = nil

        let targets = [CleanupTarget(title: "Cache", description: "App Cache", scope: .safe,
                                     paths: cachePaths, estimatedBytes: currentCacheSize, icon: "trash")]
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                DeleteEngine.delete(targets: targets, dryRun: false)
            }.value
            await MainActor.run {
                isProcessing = false
                if outcome.didTrashNothing {
                    operationError = targets[0].paths.isEmpty
                        ? "No cache found to remove."
                        : failureSummary("Couldn't clean cache", outcome: outcome)
                } else {
                    currentCacheSize = 0
                    operationResult = "Moved \(Formatters.bytes(outcome.freedBytes)) of cache to Trash. Empty the Trash to reclaim the space."
                    onCleanup?(outcome.freedBytes, outcome.removed)
                }
            }
        }
    }

    private func removeAppData() {
        isProcessing = true
        operationError = nil
        operationResult = nil

        let paths = dataPaths
        let target = CleanupTarget(title: "App Data", description: "Support, cache & containers",
                                   scope: .aggressive, paths: paths,
                                   estimatedBytes: currentSupportSize + currentCacheSize + currentContainerSize,
                                   icon: "folder.badge.minus")
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                DeleteEngine.delete(targets: [target], dryRun: false)
            }.value
            await MainActor.run {
                isProcessing = false
                if outcome.didTrashNothing {
                    operationError = paths.isEmpty
                        ? "No app data found to remove."
                        : failureSummary("Couldn't remove app data", outcome: outcome)
                } else {
                    currentSupportSize = 0
                    currentCacheSize = 0
                    currentContainerSize = 0
                    let skipped = outcome.failedCount + outcome.blockedCount
                    operationResult = skipped > 0
                        ? "Moved \(Formatters.bytes(outcome.freedBytes)) to Trash (\(skipped) skipped). Empty the Trash to reclaim the space."
                        : "Moved \(Formatters.bytes(outcome.freedBytes)) of app data to Trash. Empty the Trash to reclaim the space."
                    onCleanup?(outcome.freedBytes, outcome.removed)
                }
            }
        }
    }

    private func uninstallApp() {
        isProcessing = true
        operationError = nil
        operationResult = nil

        let bundle = app.bundleURL
        let bundleSize = currentBundleSize
        let dataTarget = CleanupTarget(title: "App Data", description: "", scope: .aggressive,
                                       paths: dataPaths, estimatedBytes: 0, icon: "trash")
        Task {
            // 1) Remove associated data via the safe engine.
            let dataOutcome = await Task.detached(priority: .userInitiated) {
                DeleteEngine.delete(targets: [dataTarget], dryRun: false)
            }.value

            // 2) Move the .app bundle to Trash via NSWorkspace (prompts for auth when needed).
            let bundleResult: Result<Int64, Error> = await withCheckedContinuation { continuation in
                NSWorkspace.shared.recycle([bundle]) { _, error in
                    if let error {
                        continuation.resume(returning: .failure(error))
                    } else {
                        continuation.resume(returning: .success(bundleSize))
                    }
                }
            }

            await MainActor.run {
                isProcessing = false
                switch bundleResult {
                case .success(let removedBundleBytes):
                    let freed = dataOutcome.freedBytes + removedBundleBytes
                    onCleanup?(freed, dataOutcome.removed + [bundle])
                    dismiss()
                case .failure(let error):
                    // Bundle couldn't be moved; still credit any data we did trash.
                    if dataOutcome.freedBytes > 0 { onCleanup?(dataOutcome.freedBytes, dataOutcome.removed) }
                    operationError = "Couldn't move \(app.name) to Trash: \(error.localizedDescription)"
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
