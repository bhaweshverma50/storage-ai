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
                    categoryBentoGrid(width: geometry.size.width - 48)
                }
                .padding(24)
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
                .font(.title.weight(.semibold))
            
            Text("Explore storage usage by category")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Bento Grid
    private func categoryBentoGrid(width: CGFloat) -> some View {
        let spacing: CGFloat = 16
        let columns = 3
        let cardWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
            spacing: spacing
        ) {
            ForEach(sortedBuckets) { bucket in
                CategoryBentoCard(
                    bucket: bucket,
                    totalBytes: appState.scanService.summary.totalBytes,
                    fileCount: appState.scanService.filesByCategory[bucket.category]?.count ?? 0
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

// MARK: - Category Bento Card
struct CategoryBentoCard: View {
    let bucket: StorageBucket
    let totalBytes: Int64
    let fileCount: Int
    let action: () -> Void
    
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
                    Image(systemName: bucket.category.icon)
                        .font(.title2)
                        .foregroundStyle(bucket.category.color)
                    
                    Spacer()
                    
                    Text(Formatters.percentage(percentage))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(bucket.category.color)
                }
                
                Spacer()
                
                // Name and size
                VStack(alignment: .leading, spacing: 4) {
                    Text(bucket.category.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    
                    Text(Formatters.bytes(bucket.bytes))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                
                Spacer()
                
                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.15))
                        
                        RoundedRectangle(cornerRadius: 3)
                            .fill(bucket.category.color)
                            .frame(width: max(0, geometry.size.width * CGFloat(percentage / 100)))
                    }
                }
                .frame(height: 6)
                
                // File count
                HStack {
                    Text("\(Formatters.number(fileCount)) files")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 8)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        bucket.category.color.opacity(0.2),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Category Files Sheet
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
            Divider()

            if cachedFilteredFiles.isEmpty {
                EmptyStateView(
                    icon: "doc.text.magnifyingglass",
                    title: "No Files Found",
                    message: searchText.isEmpty ? "No files in this category" : "No files match your search"
                )
            } else {
                fileList
            }

            if !selection.isEmpty {
                footer
            }
        }
        .frame(width: 700, height: 600)
        .alert("Delete \(selection.count) files?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteSelected()
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .onAppear { updateFilteredFiles() }
        .onChange(of: searchText) { _, _ in updateFilteredFiles() }
        .onChange(of: sortOrder) { _, _ in updateFilteredFiles() }
    }

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
    
    private var sheetHeader: some View {
        HStack {
            Image(systemName: category.icon)
                .font(.title2)
                .foregroundStyle(category.color)
            
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
                .frame(width: 150)
            
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }
    
    private var fileList: some View {
        List(cachedFilteredFiles, selection: $selection) { entry in
            FileRow(entry: entry)
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
    }
    
    private var allFiles: [FileEntry] {
        appState.scanService.filesByCategory[category] ?? []
    }

    private var totalBytes: Int64 {
        cachedFilteredFiles.reduce(0) { $0 + $1.sizeBytes }
    }

    private func deleteSelected() {
        let toDelete = cachedFilteredFiles.filter { selection.contains($0.id) }
        
        do {
            for file in toDelete {
                try FileManager.default.removeItem(at: file.url)
            }
            appState.scanService.removeEntries(category: category, ids: selection)
            selection.removeAll()
            deleteError = nil
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

// MARK: - File Row
struct FileRow: View {
    let entry: FileEntry
    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = icon {
                    Image(nsImage: icon)
                        .resizable()
                } else {
                    Image(systemName: "doc")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.url.lastPathComponent)
                    .font(.subheadline)
                    .lineLimit(1)

                Text(entry.url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if let date = entry.modifiedAt {
                Text(Formatters.relativeDate(date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(Formatters.bytes(entry.sizeBytes))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .task {
            icon = await loadIcon()
        }
    }

    private func loadIcon() async -> NSImage {
        await Task.detached {
            NSWorkspace.shared.icon(forFile: entry.url.path)
        }.value
    }
}

#Preview {
    CategoryDetailView()
        .environmentObject(AppState())
        .frame(width: 900, height: 700)
}
