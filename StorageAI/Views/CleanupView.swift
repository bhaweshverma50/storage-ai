import SwiftUI

struct CleanupView: View {
    let targets: [CleanupTarget]
    var isLoading: Bool = false
    @State private var selection = Set<UUID>()
    @State private var dryRun = true
    @State private var isDeleting = false
    @State private var lastDeleted: [URL] = []
    @State private var errorMessage: String?
    @State private var showConfirmation = false
    @State private var filter: CleanupScope? = nil
    
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    header
                    
                    // Stats Row
                    statsRow(width: geometry.size.width - 48)
                    
                    // Filter + Action Row
                    filterRow
                    
                    // Targets Grid
                    targetsGrid(width: geometry.size.width - 48)
                    
                    // Messages
                    messagesSection
                    
                    // Action Button
                    if !selection.isEmpty {
                        actionButton
                    }
                }
                .padding(24)
            }
        }
        .alert("Confirm Cleanup", isPresented: $showConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button(dryRun ? "Preview" : "Delete", role: dryRun ? nil : .destructive) {
                runCleanup()
            }
        } message: {
            Text(dryRun 
                 ? "This will show you what would be deleted without actually removing anything."
                 : "This will permanently delete the selected items. This action cannot be undone.")
        }
    }
    
    // MARK: - Header
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cleanup")
                    .font(.title.weight(.semibold))
                
                Text("Free up disk space by removing unnecessary files")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Mode Toggle
            HStack(spacing: 10) {
                Text(dryRun ? "Preview" : "Delete")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(dryRun ? Color.secondary : Color.red)
                
                Toggle("", isOn: $dryRun)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
    
    // MARK: - Stats Row
    private func statsRow(width: CGFloat) -> some View {
        let spacing: CGFloat = 12
        let cardWidth = (width - spacing * 2) / 3
        
        return HStack(spacing: spacing) {
            StatBentoCard(
                title: "Safe Cleanup",
                value: Formatters.bytes(safeTotal),
                icon: "checkmark.shield",
                color: .green
            )
            .frame(width: cardWidth, height: 90)
            
            StatBentoCard(
                title: "Deep Cleanup",
                value: Formatters.bytes(aggressiveTotal),
                icon: "bolt.shield",
                color: .orange
            )
            .frame(width: cardWidth, height: 90)
            
            StatBentoCard(
                title: "Selected",
                value: Formatters.bytes(selectedTotal),
                icon: "trash",
                color: .red
            )
            .frame(width: cardWidth, height: 90)
        }
    }
    
    // MARK: - Filter Row
    private var filterRow: some View {
        HStack(spacing: 10) {
            FilterChip(title: "All", isSelected: filter == nil) {
                filter = nil
            }
            
            FilterChip(title: "Safe", isSelected: filter == .safe, color: .green) {
                filter = .safe
            }
            
            FilterChip(title: "Deep", isSelected: filter == .aggressive, color: .orange) {
                filter = .aggressive
            }
            
            Spacer()
            
            Button {
                if selection.isEmpty {
                    selection = Set(filteredTargets.map(\.id))
                } else {
                    selection.removeAll()
                }
            } label: {
                Text(selection.isEmpty ? "Select All" : "Deselect All")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
    }
    
    // MARK: - Targets Grid
    private func targetsGrid(width: CGFloat) -> some View {
        Group {
            if isLoading {
                BentoCard {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Scanning for cleanup targets...")
                            .font(.subheadline.weight(.medium))
                        Text("This may take a moment")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 200)
            } else if filteredTargets.isEmpty {
                BentoCard {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("All Clean!")
                            .font(.subheadline.weight(.medium))
                        Text("No cleanup targets found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 200)
            } else {
                let spacing: CGFloat = 12
                let columns = 2
                let cardWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                    spacing: spacing
                ) {
                    ForEach(filteredTargets) { target in
                        CleanupBentoCard(
                            target: target,
                            isSelected: selection.contains(target.id),
                            onToggle: {
                                if selection.contains(target.id) {
                                    selection.remove(target.id)
                                } else {
                                    selection.insert(target.id)
                                }
                            }
                        )
                        .frame(height: 120)
                    }
                }
            }
        }
    }
    
    // MARK: - Messages
    private var messagesSection: some View {
        VStack(spacing: 10) {
            if let errorMessage {
                MessageBanner(
                    icon: "exclamationmark.triangle.fill",
                    message: errorMessage,
                    color: .red
                )
            }
            
            if !lastDeleted.isEmpty {
                MessageBanner(
                    icon: "checkmark.circle.fill",
                    message: dryRun 
                        ? "Preview: Would delete \(lastDeleted.count) items"
                        : "Successfully deleted \(lastDeleted.count) items",
                    color: .green
                )
            }
        }
    }
    
    // MARK: - Action Button
    private var actionButton: some View {
        HStack {
            Spacer()
            Button {
                showConfirmation = true
            } label: {
                HStack(spacing: 8) {
                    if isDeleting {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                    Image(systemName: dryRun ? "eye" : "trash")
                    Text(dryRun ? "Preview Cleanup (\(selection.count))" : "Run Cleanup (\(selection.count))")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(dryRun ? .blue : .red)
            .controlSize(.large)
            .disabled(isDeleting)
            Spacer()
        }
    }
    
    // MARK: - Computed Properties
    private var filteredTargets: [CleanupTarget] {
        if let filter {
            return targets.filter { $0.scope == filter }
        }
        return targets
    }
    
    private var safeTotal: Int64 {
        targets.filter { $0.scope == .safe }.reduce(0) { $0 + $1.estimatedBytes }
    }
    
    private var aggressiveTotal: Int64 {
        targets.filter { $0.scope == .aggressive }.reduce(0) { $0 + $1.estimatedBytes }
    }
    
    private var selectedTotal: Int64 {
        targets.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.estimatedBytes }
    }
    
    // MARK: - Actions
    private func runCleanup() {
        isDeleting = true
        errorMessage = nil
        
        let selected = targets.filter { selection.contains($0.id) }
        
        Task {
            do {
                let deleted = try DeleteEngine.delete(targets: selected, dryRun: dryRun)
                await MainActor.run {
                    lastDeleted = deleted
                    if !dryRun {
                        selection.removeAll()
                    }
                    isDeleting = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isDeleting = false
                }
            }
        }
    }
}

// MARK: - Filter Chip
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    var color: Color = .blue
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isSelected ? color : Color.secondary.opacity(0.15), in: Capsule())
                .foregroundStyle(isSelected ? .white : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cleanup Bento Card
struct CleanupBentoCard: View {
    let target: CleanupTarget
    let isSelected: Bool
    let onToggle: () -> Void
    
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 14) {
                // Checkbox
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? target.scope.color : Color.secondary.opacity(0.3), lineWidth: 2)
                        .frame(width: 24, height: 24)
                    
                    if isSelected {
                        Circle()
                            .fill(target.scope.color)
                            .frame(width: 16, height: 16)
                        
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                
                // Icon
                Image(systemName: target.icon)
                    .font(.title2)
                    .foregroundStyle(target.scope.color)
                    .frame(width: 36)
                
                // Info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(target.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        
                        Text(target.scope.displayName)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(target.scope.color.opacity(0.15))
                            .foregroundStyle(target.scope.color)
                            .clipShape(Capsule())
                    }
                    
                    Text(target.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                // Size
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Formatters.bytes(target.estimatedBytes))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    Text("estimated")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected ? target.scope.color.opacity(0.5) : Color.white.opacity(colorScheme == .dark ? 0.1 : 0.3),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Message Banner
struct MessageBanner: View {
    let icon: String
    let message: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(message)
                .font(.caption)
                .foregroundStyle(color)
            Spacer()
        }
        .padding(12)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    CleanupView(targets: [])
        .frame(width: 900, height: 700)
}
