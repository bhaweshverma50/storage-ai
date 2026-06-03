import SwiftUI

struct CategoryDetailView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedCategory: StorageCategory?
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    header
                    
                    // Bento Grid
                    categoryBentoGrid(width: geometry.size.width - 40)
                }
                .padding(20)
            }
        }
        .sheet(item: $selectedCategory) { category in
            CategoryFilesSheet(category: category)
                .environmentObject(appState)
        }
    }
    
    // MARK: - Header
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Categories")
                .font(.title2.weight(.bold))
            
            Text("Explore storage usage by category")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Bento Grid
    private func categoryBentoGrid(width: CGFloat) -> some View {
        let spacing: CGFloat = 16
        // Min width for cards to ensure they don't get too small
        let minCardWidth: CGFloat = 200
        let columns = [GridItem(.adaptive(minimum: minCardWidth), spacing: spacing)]
        
        return LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(sortedBuckets) { bucket in
                CategoryBentoCard(
                    bucket: bucket,
                    totalBytes: appState.scanService.summary.totalBytes,
                    fileCount: appState.scanService.fileCounts[bucket.category] ?? appState.scanService.filesByCategory[bucket.category]?.count ?? 0
                ) {
                    selectedCategory = bucket.category
                }
                .frame(height: 180)
            }
        }
    }
    
    private var sortedBuckets: [StorageBucket] {
        appState.scanService.summary.buckets.sorted { $0.bytes > $1.bytes }
    }
}

// MARK: - Category Bento Card (Refined)
struct CategoryBentoCard: View {
    let bucket: StorageBucket
    let totalBytes: Int64
    let fileCount: Int
    let action: () -> Void
    
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    
    private var percentage: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bucket.bytes) / Double(totalBytes) * 100
    }
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // Header with icon
                HStack {
                    ZStack {
                        Circle()
                            .fill(bucket.category.color.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: bucket.category.icon)
                            .font(.title3)
                            .foregroundStyle(bucket.category.color)
                    }
                    
                    Spacer()
                    
                    Text(Formatters.percentage(percentage))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(bucket.category.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(bucket.category.color.opacity(0.1), in: Capsule())
                }
                
                Spacer()
                
                // Name and size
                VStack(alignment: .leading, spacing: 4) {
                    Text(bucket.category.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    
                    Text(Formatters.bytes(bucket.bytes))
                        .font(.title3.weight(.bold)) // Improved hierarchy
                        .foregroundStyle(.primary)
                }
                
                Spacer()
                
                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                        
                        Capsule()
                            .fill(bucket.category.color)
                            .frame(width: max(0, geometry.size.width * CGFloat(percentage / 100)))
                    }
                }
                .frame(height: 6)
                
                // File count
                HStack {
                    Text("\(Formatters.number(fileCount)) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .opacity(isHovered ? 1 : 0.5)
                }
                .padding(.top, 12)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(isHovered ? 0.1 : 0.05), radius: isHovered ? 8 : 4, x: 0, y: 2)
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        bucket.category.color.opacity(isHovered ? 0.3 : 0),
                        lineWidth: 1
                    )
            }
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .animation(.easeOut(duration: 0.2), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Category Files Sheet (Virtualization Fix)
struct CategoryFilesSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let category: StorageCategory

    @State private var searchText = ""
    @State private var selection = Set<UUID>()
    @State private var showDeleteAlert = false
    @State private var deleteError: String?
    @State private var sortOrder: SortOrder = .sizeDesc
    @State private var cachedFilteredFiles: [FileEntry] = []

    enum SortOrder: String, CaseIterable {
        case sizeDesc = "Largest First"
        case sizeAsc = "Smallest First"
        case dateDesc = "Newest First"
        case dateAsc = "Oldest First"
        case nameAsc = "Name A-Z"
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
                .padding(16)
                .background(.ultraThinMaterial)
            
            Divider()

            if cachedFilteredFiles.isEmpty {
                EmptyStateView(
                    icon: "doc.text.magnifyingglass",
                    title: "No Files Found",
                    message: searchText.isEmpty ? "No files in this category" : "No files match \"\(searchText)\""
                )
            } else {
                // Use List for Virtualization (Fixes scroll lag on 1000+ files)
                List(selection: $selection) {
                    ForEach(cachedFilteredFiles) { entry in
                        FileRow(entry: entry)
                            .tag(entry.id) // For selection
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.visible)
                            .contextMenu {
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.selectFile(entry.url.path, inFileViewerRootedAtPath: entry.url.deletingLastPathComponent().path)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    selection = [entry.id]
                                    showDeleteAlert = true
                                }
                            }
                    }
                }
                .listStyle(.plain) // Clean look
            }

            if !selection.isEmpty {
                footer
            }
        }
        .frame(width: 800, height: 600) // Increased width for better table view
        .alert("Move \(selection.count) files to Trash?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                deleteSelected()
            }
        } message: {
            Text("The selected files will be moved to the Trash. You can recover them from the Trash if needed.")
        }
        .onAppear { updateFilteredFiles() }
        .onChange(of: searchText) { _, _ in updateFilteredFiles() }
        .onChange(of: sortOrder) { _, _ in updateFilteredFiles() }
    }

    // ... (Keep existing updateFilteredFiles logic)
    private func updateFilteredFiles() {
        var files = allFiles

        if !searchText.isEmpty {
            files = files.filter { entry in
                entry.url.lastPathComponent.localizedCaseInsensitiveContains(searchText) ||
                entry.url.path.localizedCaseInsensitiveContains(searchText)
            }
        }

        switch sortOrder {
        case .sizeDesc: files.sort { $0.sizeBytes > $1.sizeBytes }
        case .sizeAsc: files.sort { $0.sizeBytes < $1.sizeBytes }
        case .dateDesc: files.sort { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        case .dateAsc: files.sort { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
        case .nameAsc: files.sort { $0.url.lastPathComponent.localizedCompare($1.url.lastPathComponent) == .orderedAscending }
        }

        cachedFilteredFiles = files
    }
    
    // ... (Keep existing header/footer logic, just minor style tweaks)
    private var sheetHeader: some View {
        HStack {
            Image(systemName: category.icon)
                .font(.title2)
                .foregroundStyle(category.color)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(category.displayName)
                    .font(.headline)
                
                Text("\(Formatters.number(cachedFilteredFiles.count)) files • \(Formatters.bytes(totalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Picker("Sort", selection: $sortOrder) {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
            
            TextField("Search...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }
    
    private var footer: some View {
        HStack {
            Text("\(selection.count) selected")
                .foregroundStyle(.secondary)
            
            Spacer()
            
            if let deleteError {
                Text(deleteError)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            
            Button("Reveal in Finder") {
                if let id = selection.first,
                   let entry = cachedFilteredFiles.first(where: { $0.id == id }) {
                    NSWorkspace.shared.selectFile(entry.url.path, inFileViewerRootedAtPath: entry.url.deletingLastPathComponent().path)
                }
            }
            .disabled(selection.isEmpty)
            
            Button("Delete Selected", role: .destructive) {
                showDeleteAlert = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selection.isEmpty)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .overlay(Divider(), alignment: .top)
    }
    
    private var allFiles: [FileEntry] {
        appState.scanService.filesByCategory[category] ?? []
    }

    private var totalBytes: Int64 {
        cachedFilteredFiles.reduce(0) { $0 + $1.sizeBytes }
    }

    private func deleteSelected() {
        let toDelete = cachedFilteredFiles.filter { selection.contains($0.id) }

        // Move to Trash via the safe engine. We never permanently delete: items that can't be
        // trashed are reported and left in place, and critical system paths are refused.
        let urls = toDelete.map(\.url)
        let outcome = DeleteEngine.trashFiles(urls)

        // Map trashed URLs back to FileEntry ids so we update in-memory state accurately.
        let trashedURLPaths = Set(outcome.trashed.map { $0.standardizedFileURL.path })
        let deletedIds = Set(toDelete.filter { trashedURLPaths.contains($0.url.standardizedFileURL.path) }.map(\.id))

        if !deletedIds.isEmpty {
            appState.scanService.removeEntries(category: category, ids: deletedIds)
            selection.subtract(deletedIds)
            appState.scanService.refreshDiskInfo()
        }

        let problemCount = outcome.failedCount + outcome.blockedCount
        if problemCount == 0 {
            deleteError = nil
        } else if deletedIds.isEmpty {
            let first = outcome.failed.first?.url.lastPathComponent ?? outcome.blocked.first?.lastPathComponent ?? "Item"
            deleteError = "\"\(first)\" couldn't be moved to Trash."
        } else {
            deleteError = "Moved \(deletedIds.count) to Trash. \(problemCount) couldn't be removed."
        }

        updateFilteredFiles()
    }
}

// MARK: - File Row (Optimized)
struct FileRow: View {
    let entry: FileEntry

    var body: some View {
        HStack(spacing: 12) {
            // Optimized Icon
            CachedAsyncIcon(path: entry.url.path, size: 28)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.url.lastPathComponent)
                    .font(.body) // Larger font for readability
                    .lineLimit(1)
                    .truncationMode(.middle) // Middle truncation is better for filenames

                Text(entry.url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head) // Head truncation shows folder context better
            }

            Spacer()

            if let date = entry.modifiedAt {
                Text(Formatters.relativeDate(date))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 80, alignment: .trailing)
            }

            Text(Formatters.bytes(entry.sizeBytes))
                .font(.body.monospacedDigit()) // Monospaced numbers align better
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }
}
