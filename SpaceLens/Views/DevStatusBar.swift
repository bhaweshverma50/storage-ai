import SwiftUI

// MARK: - Developer Status Bar

/// A compact status bar showing real-time resource metrics for debugging
struct DevStatusBar: View {
    @StateObject private var monitor = ResourceMonitor.shared
    @State private var showingCopyConfirmation = false
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 0) {
            // Memory section
            StatusMetric(
                icon: "memorychip",
                label: "Mem",
                value: monitor.memoryUsage.formattedResident,
                detail: "Peak: \(monitor.memoryUsage.formattedPeak)",
                color: statusColor(for: monitor.memoryUsage.statusColor)
            )
            
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 8)
            
            // CPU section
            StatusMetric(
                icon: "cpu",
                label: "CPU",
                value: String(format: "%.0f%%", monitor.cpuUsage),
                detail: nil,
                color: statusColor(for: monitor.cpuStatusColor)
            )
            
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 8)
            
            // Tasks section
            StatusMetric(
                icon: "gearshape.2",
                label: "Tasks",
                value: "\(monitor.activeTasks)",
                detail: nil,
                color: statusColor(for: monitor.taskStatusColor)
            )
            
            Divider()
                .frame(height: 14)
                .padding(.horizontal, 8)
            
            // Cache section
            StatusMetric(
                icon: "internaldrive",
                label: "Cache",
                value: monitor.cacheStats.formattedTotal,
                detail: "\(monitor.cacheStats.thumbnailCount) thumbs",
                color: .secondary
            )
            
            Spacer()
            
            // Action buttons
            HStack(spacing: 6) {
                // Copy stats button
                Button {
                    monitor.copyStatsToClipboard()
                    withAnimation {
                        showingCopyConfirmation = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            showingCopyConfirmation = false
                        }
                    }
                } label: {
                    Image(systemName: showingCopyConfirmation ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 10))
                        .foregroundStyle(showingCopyConfirmation ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copy stats to clipboard")
                
                // Clear cache button
                Button {
                    Task {
                        await monitor.clearAllCaches()
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear all caches")
                
                // Refresh button
                Button {
                    monitor.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh metrics")
            }
            .padding(.trailing, 8)
            
            // Dev mode indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text("DEV")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 28)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
        .onAppear {
            monitor.startMonitoring()
        }
        .onDisappear {
            monitor.stopMonitoring()
        }
    }
    
    private func statusColor(for status: ResourceMonitor.StatusColor) -> Color {
        switch status {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

// MARK: - Status Metric Component

private struct StatusMetric: View {
    let icon: String
    let label: String
    let value: String
    let detail: String?
    let color: Color
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color)
            
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.secondary.opacity(0.1) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .help(detail ?? "\(label): \(value)")
    }
}

// MARK: - Developer Settings Section

/// Settings section shown when dev mode is enabled
struct DevSettingsSection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var monitor = ResourceMonitor.shared
    
    var body: some View {
        BentoCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "hammer")
                        .foregroundStyle(.orange)
                    Text("Developer Mode")
                        .font(.subheadline.weight(.medium))
                    
                    Spacer()
                    
                    // Active indicator
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text("Active")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Divider()
                
                // Memory Stats
                VStack(alignment: .leading, spacing: 8) {
                    Text("Resource Usage")
                        .font(.caption.weight(.medium))
                    
                    HStack(spacing: 16) {
                        DevStatItem(
                            label: "Memory",
                            value: monitor.memoryUsage.formattedResident,
                            subvalue: "Peak: \(monitor.memoryUsage.formattedPeak)",
                            color: statusColor(for: monitor.memoryUsage.statusColor)
                        )
                        
                        DevStatItem(
                            label: "CPU",
                            value: String(format: "%.1f%%", monitor.cpuUsage),
                            subvalue: nil,
                            color: statusColor(for: monitor.cpuStatusColor)
                        )
                        
                        DevStatItem(
                            label: "Tasks",
                            value: "\(monitor.activeTasks)",
                            subvalue: nil,
                            color: statusColor(for: monitor.taskStatusColor)
                        )
                    }
                }
                
                Divider()
                
                // Cache Stats
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cache Usage")
                        .font(.caption.weight(.medium))
                    
                    HStack(spacing: 16) {
                        DevStatItem(
                            label: "Thumbnails",
                            value: "\(monitor.cacheStats.thumbnailCount)",
                            subvalue: Formatters.bytes(monitor.cacheStats.thumbnailEstimatedBytes),
                            color: .blue
                        )
                        
                        DevStatItem(
                            label: "Scan Data",
                            value: Formatters.bytes(monitor.cacheStats.scanCacheBytes),
                            subvalue: nil,
                            color: .purple
                        )
                        
                        DevStatItem(
                            label: "Media",
                            value: Formatters.bytes(monitor.cacheStats.mediaCacheBytes),
                            subvalue: nil,
                            color: .green
                        )
                    }
                }
                
                Divider()
                
                // Actions
                HStack(spacing: 10) {
                    Button {
                        monitor.copyStatsToClipboard()
                    } label: {
                        Label("Copy Stats", systemImage: "doc.on.clipboard")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button {
                        Task {
                            await monitor.clearAllCaches()
                        }
                    } label: {
                        Label("Clear Caches", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Spacer()
                    
                    Button {
                        appState.isDevModeEnabled = false
                    } label: {
                        Label("Disable Dev Mode", systemImage: "xmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }
            }
        }
    }
    
    private func statusColor(for status: ResourceMonitor.StatusColor) -> Color {
        switch status {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

// MARK: - Dev Stat Item

private struct DevStatItem: View {
    let label: String
    let value: String
    let subvalue: String?
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            
            if let subvalue = subvalue {
                Text(subvalue)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Dev Mode Toast

/// Toast notification shown when dev mode is toggled
struct DevModeToast: View {
    let isEnabled: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isEnabled ? "hammer.fill" : "hammer")
                .foregroundStyle(isEnabled ? .orange : .secondary)
            
            Text(isEnabled ? "Developer Mode Enabled" : "Developer Mode Disabled")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }
}

#Preview {
    VStack {
        Spacer()
        DevStatusBar()
    }
    .frame(width: 800, height: 400)
}
