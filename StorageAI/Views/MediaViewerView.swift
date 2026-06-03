import SwiftUI

struct MediaViewerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accentTheme) private var accentTheme
    @Environment(\.fontScale) private var fontScale
    
    // MARK: - State
    
    @State private var mediaItems: [MediaItem] = []
    @State private var analysisResult: MediaAnalysisResult?
    @State private var selection: Set<UUID> = []
    @State private var operationState: MediaOperationState = .idle
    
    // View options
    @State private var viewMode: MediaViewMode = .grid
    @State private var gridSize: MediaGridSize = .medium
    @State private var selectedFilter: MediaFilter = .all
    @State private var sortOrder: MediaSortOrder = .sizeDesc
    @State private var searchText = ""
    
    // Sheets and alerts
    @State private var showCompressionSheet = false
    @State private var showDeleteConfirmation = false
    @State private var showDetailSheet = false
    @State private var selectedDetailItem: MediaItem?
    @State private var compressionEstimate: CompressionEstimate?
    
    // AI suggestions
    @State private var aiSuggestions: [MediaSuggestion] = []
    @State private var isLoadingAI = false
    
    // Services
    private let analysisService = MediaAnalysisService()
    private let compressionService = MediaCompressionService()
    
    // MARK: - Computed Properties
    
    private var filteredItems: [MediaItem] {
        var items = mediaItems
        
        // Apply filter
        switch selectedFilter {
        case .all:
            break
        case .photos:
            items = items.filter { $0.type == .photo || $0.type == .livePhoto || $0.type == .raw }
        case .videos:
            items = items.filter { $0.type == .video }
        case .screenshots:
            items = items.filter { $0.type == .screenshot }
        case .large:
            items = items.filter { $0.subcategories.contains(.largeFiles) }
        case .old:
            items = items.filter { $0.subcategories.contains(.oldMedia) }
        }
        
        // Apply search
        if !searchText.isEmpty {
            items = items.filter { item in
                item.fileName.localizedCaseInsensitiveContains(searchText) ||
                item.url.path.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        // Apply sort
        items = sortItems(items)
        
        return items
    }
    
    private var selectedItems: [MediaItem] {
        mediaItems.filter { selection.contains($0.id) }
    }
    
    private var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.sizeBytes }
    }
    
    private var hasMediaData: Bool {
        !mediaItems.isEmpty || analysisResult != nil
    }
    
    // MARK: - Body
    
    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Header
                header
                
                Divider()
                
                if operationState.isActive {
                    // Progress overlay
                    MediaProgressView(state: operationState) {
                        cancelOperation()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !hasMediaData && appState.scanService.summary.totalBytes == 0 {
                    // No scan data
                    MediaEmptyState(
                        icon: "photo.stack",
                        title: "No Media Data",
                        message: "Run a scan first to analyze your media files",
                        action: nil
                    )
                } else if !hasMediaData {
                    // Has scan data but hasn't analyzed media yet
                    MediaEmptyState(
                        icon: "wand.and.stars",
                        title: "Analyze Media",
                        message: "Click below to analyze your photos and videos for optimization opportunities",
                        action: { Task { await analyzeMedia() } },
                        actionTitle: "Analyze Media"
                    )
                } else {
                    // Main content
                    VStack(spacing: 0) {
                        // Stats bar
                        if let stats = analysisResult?.stats {
                            MediaStatsCard(stats: stats)
                                .padding(.horizontal, 24)
                                .padding(.top, 16)
                        }
                        
                        // Filter bar
                        MediaFilterBar(
                            selectedFilter: $selectedFilter,
                            stats: analysisResult?.stats
                        )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        
                        // Toolbar
                        MediaToolbar(
                            viewMode: $viewMode,
                            gridSize: $gridSize,
                            sortOrder: $sortOrder,
                            selectionCount: selection.count,
                            totalCount: filteredItems.count,
                            selectedSize: selectedSize,
                            onSelectAll: selectAll,
                            onDeselectAll: deselectAll
                        )
                        
                        Divider()
                        
                        // AI Suggestions (collapsible)
                        if !aiSuggestions.isEmpty || (analysisResult?.suggestions.isEmpty == false) {
                            suggestionsSection
                        }
                        
                        // Content
                        if filteredItems.isEmpty {
                            MediaEmptyState(
                                icon: "magnifyingglass",
                                title: "No Results",
                                message: searchText.isEmpty ? "No media files match the selected filter" : "No files match your search"
                            )
                        } else {
                            mediaContent
                        }
                    }
                }
            }
            
            // Action bar (fixed at bottom when items selected)
            if selection.count > 0 && !operationState.isActive {
                MediaActionBar(
                    selectionCount: selection.count,
                    selectedSize: selectedSize,
                    compressionEstimate: compressionEstimate,
                    onCompress: { showCompressionSheet = true },
                    onOrganize: organizeSelected,
                    onDelete: { showDeleteConfirmation = true },
                    onReveal: revealSelected
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selection.count)
        .sheet(isPresented: $showCompressionSheet) {
            CompressionSheet(
                items: selectedItems,
                onCompress: { quality, keepOriginals in
                    Task { await compressSelected(quality: quality, keepOriginals: keepOriginals) }
                }
            )
        }
        .sheet(item: $selectedDetailItem) { item in
            MediaDetailSheet(item: item) { action in
                handleDetailAction(action, for: item)
            }
        }
        .alert("Delete \(selection.count) items?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteSelected() }
            }
        } message: {
            Text("This will move the selected items to Trash. You can recover them from Trash if needed.")
        }
        .onChange(of: selection) { _, newSelection in
            updateCompressionEstimate()
        }
        .task {
            // Try to load cached media analysis first
            await loadCachedMediaAnalysis()
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Media Library")
                    .font(.title.weight(.semibold))
                
                if let stats = analysisResult?.stats {
                    Text("\(stats.photoCount) photos, \(stats.videoCount) videos • \(stats.formattedTotalSize)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search media...", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
                
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            
            // Refresh button
            Button {
                Task { await analyzeMedia() }
            } label: {
                Image(systemName: operationState.isActive ? "hourglass" : "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(operationState.isActive)
            
            // AI suggestions button
            if appState.settings.ollamaEnabled && hasMediaData {
                Button {
                    Task { await loadAISuggestions() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isLoadingAI ? "hourglass" : "wand.and.stars")
                        Text("AI Tips")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoadingAI)
            }
        }
        .padding(24)
    }
    
    // MARK: - Suggestions Section
    
    @State private var showSuggestions = true
    
    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { showSuggestions.toggle() }
            } label: {
                HStack {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(.yellow)
                    Text("Suggestions")
                        .font(.subheadline.weight(.medium))
                    
                    Spacer()
                    
                    Image(systemName: showSuggestions ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            
            if showSuggestions {
                let suggestions = aiSuggestions.isEmpty ? (analysisResult?.suggestions ?? []) : aiSuggestions
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(suggestions) { suggestion in
                            MediaSuggestionCard(suggestion: suggestion) {
                                applySuggestion(suggestion)
                            }
                            .frame(width: 320)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.yellow.opacity(0.05))
    }
    
    // MARK: - Media Content
    
    @ViewBuilder
    private var mediaContent: some View {
        switch viewMode {
        case .grid:
            mediaGrid
        case .list:
            mediaList
        }
    }
    
    private var mediaGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: gridSize.columns),
                spacing: 8
            ) {
                ForEach(filteredItems) { item in
                    MediaThumbnailCell(
                        item: item,
                        size: gridSize.cellSize,
                        isSelected: selection.contains(item.id),
                        onTap: { toggleSelection(item) },
                        onDoubleTap: { selectedDetailItem = item }
                    )
                }
            }
            .padding(16)
            .padding(.bottom, selection.isEmpty ? 0 : 80) // Space for action bar
        }
    }
    
    private var mediaList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(filteredItems) { item in
                    MediaListRow(
                        item: item,
                        isSelected: selection.contains(item.id),
                        onTap: { toggleSelection(item) }
                    )
                    .contextMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(
                                item.url.path,
                                inFileViewerRootedAtPath: item.url.deletingLastPathComponent().path
                            )
                        }
                        
                        Divider()
                        
                        Button("Delete", role: .destructive) {
                            selection = [item.id]
                            showDeleteConfirmation = true
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, selection.isEmpty ? 0 : 80)
        }
    }
    
    // MARK: - Actions
    
    private func loadCachedMediaAnalysis() async {
        // Try to load cached data first
        do {
            if let cached = try await ScanDataStore.shared.loadMediaAnalysis() {
                await MainActor.run {
                    mediaItems = cached.items
                    analysisResult = MediaAnalysisResult(
                        items: cached.items,
                        duplicateGroups: [], // Duplicates need to be recalculated if needed
                        suggestions: [], // Will be regenerated
                        stats: cached.stats
                    )
                }
                return
            }
        } catch {
            Log.media.error("Failed to load cached media analysis: \(error.localizedDescription, privacy: .public)")
        }
        
        // No cache - don't auto-analyze, let user click the button
    }
    
    private func analyzeMedia() async {
        let mediaFiles = appState.scanService.filesByCategory[.media] ?? []
        guard !mediaFiles.isEmpty else { return }
        
        operationState = .analyzing(progress: 0, currentFile: nil)
        
        let result = await analysisService.performFullAnalysis(files: mediaFiles) { progress, file in
            Task { @MainActor in
                operationState = .analyzing(progress: progress, currentFile: file)
            }
        }
        
        await MainActor.run {
            mediaItems = result.items
            analysisResult = result
            operationState = .idle
        }
        
        // Save to cache
        do {
            try await ScanDataStore.shared.saveMediaAnalysis(result)
        } catch {
            Log.media.error("Failed to cache media analysis: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func sortItems(_ items: [MediaItem]) -> [MediaItem] {
        switch sortOrder {
        case .sizeDesc:
            return items.sorted { $0.sizeBytes > $1.sizeBytes }
        case .sizeAsc:
            return items.sorted { $0.sizeBytes < $1.sizeBytes }
        case .dateDesc:
            return items.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        case .dateAsc:
            return items.sorted { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
        case .nameAsc:
            return items.sorted { $0.fileName.localizedCompare($1.fileName) == .orderedAscending }
        case .typeAsc:
            return items.sorted { $0.type.rawValue < $1.type.rawValue }
        }
    }
    
    private func toggleSelection(_ item: MediaItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }
    
    private func selectAll() {
        selection = Set(filteredItems.map { $0.id })
    }
    
    private func deselectAll() {
        selection.removeAll()
    }
    
    private func updateCompressionEstimate() {
        guard !selection.isEmpty else {
            compressionEstimate = nil
            return
        }
        
        Task {
            let estimate = await compressionService.estimateCompression(
                for: selectedItems,
                quality: .medium
            )
            await MainActor.run {
                compressionEstimate = estimate
            }
        }
    }
    
    private func compressSelected(quality: CompressionQuality, keepOriginals: Bool) async {
        operationState = .compressing(progress: 0, currentFile: nil)
        
        do {
            let result = try await compressionService.compressItems(
                selectedItems,
                quality: quality,
                keepOriginals: keepOriginals
            ) { progress, file in
                Task { @MainActor in
                    operationState = .compressing(progress: progress, currentFile: file)
                }
            }
            
            await MainActor.run {
                operationState = .idle
                selection.removeAll()
                
                // Refresh disk info
                appState.scanService.refreshDiskInfo()
                
                // Show success (could add a toast here)
                Log.media.info("Compressed \(result.successCount) files, saved \(result.formattedSavings, privacy: .public)")
            }
        } catch {
            await MainActor.run {
                operationState = .error(error.localizedDescription)
                
                // Reset after delay
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await MainActor.run {
                        operationState = .idle
                    }
                }
            }
        }
    }
    
    private func deleteSelected() async {
        operationState = .deleting(progress: 0)
        
        let itemsToDelete = selectedItems
        var deletedCount = 0
        
        for (index, item) in itemsToDelete.enumerated() {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                deletedCount += 1
            } catch {
                Log.media.error("Failed to delete \(item.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            
            let progress = Double(index + 1) / Double(itemsToDelete.count)
            await MainActor.run {
                operationState = .deleting(progress: progress)
            }
        }
        
        await MainActor.run {
            // Remove deleted items from list
            mediaItems.removeAll { selection.contains($0.id) }
            selection.removeAll()
            operationState = .idle
            
            // Refresh disk info
            appState.scanService.refreshDiskInfo()
        }
    }
    
    private func organizeSelected() {
        // TODO: Implement organize functionality
        // Could open a sheet with organization options
    }
    
    private func revealSelected() {
        guard let item = selectedItems.first else { return }
        NSWorkspace.shared.selectFile(
            item.url.path,
            inFileViewerRootedAtPath: item.url.deletingLastPathComponent().path
        )
    }
    
    private func cancelOperation() {
        // Cancel current operation
        operationState = .idle
    }
    
    private func handleDetailAction(_ action: MediaDetailAction, for item: MediaItem) {
        switch action {
        case .delete:
            selection = [item.id]
            showDeleteConfirmation = true
        case .reveal:
            NSWorkspace.shared.selectFile(
                item.url.path,
                inFileViewerRootedAtPath: item.url.deletingLastPathComponent().path
            )
        case .compress:
            selection = [item.id]
            showCompressionSheet = true
        }
        selectedDetailItem = nil
    }
    
    private func applySuggestion(_ suggestion: MediaSuggestion) {
        // Select the affected items
        selection = Set(suggestion.affectedItems.map { $0.id })
        
        // Apply the appropriate filter
        switch suggestion.action {
        case .delete:
            if suggestion.title.contains("Screenshot") {
                selectedFilter = .screenshots
            }
        case .compress:
            selectedFilter = .large
        case .organize:
            selectedFilter = .old
        case .review:
            break
        }
    }
    
    private func loadAISuggestions() async {
        guard appState.settings.ollamaEnabled else { return }
        guard let stats = analysisResult?.stats else { return }
        
        isLoadingAI = true
        
        let prompt = """
        Analyze this media library and provide 3-4 specific cleanup recommendations:
        
        Library overview:
        - Total: \(stats.totalCount) files (\(stats.formattedTotalSize))
        - Photos: \(stats.photoCount)
        - Videos: \(stats.videoCount)
        - Screenshots: \(stats.screenshotCount)
        - Large files (>10MB photos, >100MB videos): \(stats.largeFileCount)
        - Files not accessed in 1+ year: \(stats.oldMediaCount)
        - Potential duplicates: \(stats.duplicateCount)
        
        Provide brief, actionable tips as a bullet list. Focus on specific actions that would save the most space.
        """
        
        if let response = await Recommendations.llmSummary(prompt: prompt, model: appState.settings.ollamaModel) {
            let suggestions = response
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { $0.replacingOccurrences(of: "^[-•*]\\s*", with: "", options: .regularExpression) }
                .prefix(4)
                .enumerated()
                .map { index, text in
                    MediaSuggestion(
                        title: "AI Tip \(index + 1)",
                        description: text,
                        icon: "wand.and.stars",
                        color: .purple,
                        potentialSavings: nil,
                        affectedItems: [],
                        action: .review
                    )
                }
            
            await MainActor.run {
                aiSuggestions = Array(suggestions)
                isLoadingAI = false
            }
        } else {
            await MainActor.run {
                isLoadingAI = false
            }
        }
    }
}

// MARK: - Media Detail Sheet

enum MediaDetailAction {
    case delete
    case reveal
    case compress
}

struct MediaDetailSheet: View {
    let item: MediaItem
    let onAction: (MediaDetailAction) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var thumbnail: NSImage?
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(item.fileName)
                    .font(.headline)
                    .lineLimit(1)
                
                Spacer()
                
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            // Preview
            Group {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                        .overlay {
                            ProgressView()
                        }
                }
            }
            .frame(maxHeight: 400)
            .padding()
            
            // Metadata
            VStack(alignment: .leading, spacing: 12) {
                MetadataRow(label: "Type", value: item.type.displayName)
                MetadataRow(label: "Size", value: Formatters.bytes(item.sizeBytes))
                
                if let dimensions = item.formattedDimensions {
                    MetadataRow(label: "Dimensions", value: dimensions)
                }
                
                if let duration = item.formattedDuration {
                    MetadataRow(label: "Duration", value: duration)
                }
                
                if let date = item.modifiedAt {
                    MetadataRow(label: "Modified", value: Formatters.date(date))
                }
                
                MetadataRow(label: "Path", value: item.url.path)
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
            
            // Actions
            HStack(spacing: 12) {
                Button {
                    onAction(.reveal)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                
                Button {
                    onAction(.compress)
                } label: {
                    Label("Compress", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button(role: .destructive) {
                    onAction(.delete)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding()
        }
        .frame(width: 500, height: 650)
        .task {
            await loadThumbnail()
        }
    }
    
    private func loadThumbnail() async {
        thumbnail = await ThumbnailCache.shared.thumbnail(for: item.url, size: CGSize(width: 800, height: 800))
    }
}

struct MetadataRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            
            Text(value)
                .textSelection(.enabled)
            
            Spacer()
        }
        .font(.caption)
    }
}

// MARK: - Compression Sheet

struct CompressionSheet: View {
    let items: [MediaItem]
    let onCompress: (CompressionQuality, Bool) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var selectedQuality: CompressionQuality = .medium
    @State private var keepOriginals = true
    @State private var estimates: [CompressionQuality: CompressionEstimate] = [:]
    
    private let compressionService = MediaCompressionService()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Compress \(items.count) items")
                    .font(.headline)
                
                Spacer()
                
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Summary
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Original Size")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(Formatters.bytes(items.reduce(0) { $0 + $1.sizeBytes }))
                                .font(.title2.weight(.semibold))
                        }
                        
                        Spacer()
                        
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Estimated Size")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            if let estimate = estimates[selectedQuality] {
                                Text(estimate.formattedEstimatedSize)
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.green)
                            } else {
                                ProgressView()
                            }
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    
                    // Quality selector
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Compression Quality")
                            .font(.subheadline.weight(.medium))
                        
                        ForEach(CompressionQuality.allCases) { quality in
                            QualityOption(
                                quality: quality,
                                estimate: estimates[quality],
                                isSelected: selectedQuality == quality
                            ) {
                                selectedQuality = quality
                            }
                        }
                    }
                    
                    // Options
                    Toggle("Keep original files", isOn: $keepOriginals)
                        .padding(.vertical, 8)
                    
                    if !keepOriginals {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Original files will be replaced with compressed versions. This cannot be undone.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                    
                    // Estimated savings
                    if let estimate = estimates[selectedQuality], estimate.savingsBytes > 0 {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            
                            Text("You'll save approximately **\(estimate.formattedSavings)** (\(estimate.formattedSavingsPercent))")
                                .font(.subheadline)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Actions
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button {
                    dismiss()
                    onCompress(selectedQuality, keepOriginals)
                } label: {
                    Text("Compress")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 450, height: 550)
        .task {
            await loadEstimates()
        }
    }
    
    private func loadEstimates() async {
        let allEstimates = await compressionService.estimateAllQualities(for: items)
        await MainActor.run {
            estimates = allEstimates
        }
    }
}

struct QualityOption: View {
    let quality: CompressionQuality
    let estimate: CompressionEstimate?
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Radio button
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? quality.color : Color.secondary.opacity(0.3), lineWidth: 2)
                        .frame(width: 20, height: 20)
                    
                    if isSelected {
                        Circle()
                            .fill(quality.color)
                            .frame(width: 12, height: 12)
                    }
                }
                
                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(quality.displayName)
                        .font(.subheadline.weight(.medium))
                    
                    Text(quality.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // Estimate
                if let estimate = estimate {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(estimate.formattedSavings)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(quality.color)
                        Text("savings")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            .padding(12)
            .background(isSelected ? quality.color.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? quality.color.opacity(0.3) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MediaViewerView()
        .environmentObject(AppState())
        .frame(width: 1000, height: 800)
}
