import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var newExcludedPath = ""
    @State private var aiTestMessage: String?
    @State private var aiTestError: String?
    @State private var isTestingAI = false
    @State private var isOllamaAvailable = false
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var showResetOnboardingAlert = false
    @State private var showClearCacheAlert = false
    @State private var showCacheCleared = false
    
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                header

                // Two-column layout for top sections
                HStack(alignment: .top, spacing: 16) {
                    // Left column: Appearance
                    appearanceSection
                        .frame(maxWidth: .infinity)

                    // Right column: About + Quick Actions
                    VStack(spacing: 16) {
                        aboutSection
                        quickActionsSection
                    }
                    .frame(maxWidth: .infinity)
                }

                // Scan Settings
                scanSettingsSection

                // AI Settings
                aiSettingsSection

                // Excluded Paths
                excludedPathsSection
            }
            .padding(24)
        }
        .task {
            await checkOllamaStatus()
        }
    }
    
    // MARK: - Header
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.title.weight(.semibold))
            
            Text("Configure Storage AI preferences")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Appearance Section
    private var appearanceSection: some View {
        BentoCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Appearance")
                    .font(.subheadline.weight(.medium))
                
                Divider()
                
                // Color Theme
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accent Color")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    ThemePicker(selectedTheme: $appState.colorTheme)
                }
                
                Divider()
                
                // Font Size
                VStack(alignment: .leading, spacing: 8) {
                    Text("Font Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    FontSizePicker(selectedSize: $appState.fontSize)
                }
                
                Divider()
                
                // Appearance Mode
                VStack(alignment: .leading, spacing: 8) {
                    Text("Theme")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    AppearancePicker(selectedMode: $appState.appearanceMode)
                }
            }
        }
    }
    
    // MARK: - About Section
    private var aboutSection: some View {
        BentoCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("About")
                    .font(.subheadline.weight(.medium))
                
                Divider()
                
                HStack(spacing: 12) {
                    // App Icon placeholder
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 48, height: 48)
                        .overlay {
                            Image(systemName: "externaldrive")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Storage AI")
                            .font(.subheadline.weight(.semibold))
                        
                        Text("Version \(AppVersion.current)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Text("Smart Mac storage analyzer")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
    
    // MARK: - Quick Actions
    private var quickActionsSection: some View {
        BentoCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Quick Actions")
                    .font(.subheadline.weight(.medium))
                
                Divider()
                
                HStack(spacing: 10) {
                    Button {
                        showResetOnboardingAlert = true
                    } label: {
                        Label("Reset Onboarding", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    
                    Button {
                        showClearCacheAlert = true
                    } label: {
                        Label("Clear Cache", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
                
                if showCacheCleared {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Cache cleared successfully")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    .transition(.opacity)
                }
            }
        }
        .alert("Reset Onboarding", isPresented: $showResetOnboardingAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                appState.didCompleteOnboarding = false
            }
        } message: {
            Text("This will show the onboarding flow again on next app launch.")
        }
        .alert("Clear Cache", isPresented: $showClearCacheAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                Task {
                    await appState.scanService.clearCache()
                    withAnimation {
                        showCacheCleared = true
                    }
                    // Hide after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation {
                            showCacheCleared = false
                        }
                    }
                }
            }
        } message: {
            Text("This will delete all cached scan data. You'll need to run a new scan to see storage information.")
        }
    }
    
    // MARK: - Scan Settings
    private var scanSettingsSection: some View {
        BentoCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Scan Options")
                    .font(.subheadline.weight(.medium))
                
                Divider()
                
                // Include System
                CompactSettingsToggle(
                    title: "Include System Folders",
                    description: "Scan /System and /Library directories",
                    icon: "gearshape",
                    color: .gray,
                    isOn: $appState.settings.includeSystem
                )
                
                Divider()
                
                // Include Hidden
                CompactSettingsToggle(
                    title: "Include Hidden Files",
                    description: "Include files starting with a dot (.)",
                    icon: "eye.slash",
                    color: .purple,
                    isOn: $appState.settings.includeHidden
                )
            }
        }
    }
    
    // MARK: - AI Settings
    private var aiSettingsSection: some View {
        BentoCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("AI Recommendations")
                        .font(.subheadline.weight(.medium))
                    
                    Spacer()
                    
                    // Status indicator
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isOllamaAvailable ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        
                        Text(isOllamaAvailable ? "Connected" : "Offline")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Divider()
                
                // Enable Toggle
                CompactSettingsToggle(
                    title: "Enable AI Recommendations",
                    description: "Use local Ollama for cleanup suggestions",
                    icon: "cpu",
                    color: .cyan,
                    isOn: $appState.settings.ollamaEnabled
                )
                
                if appState.settings.ollamaEnabled {
                    Divider()
                    
                    // Connection Info
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connection")
                                    .font(.caption.weight(.medium))
                                
                                Text(isOllamaAvailable 
                                     ? "localhost:11434" 
                                     : "Start with 'ollama serve'")
                                    .font(.caption2)
                                    .foregroundStyle(isOllamaAvailable ? .green : .red)
                            }
                            
                            Spacer()
                            
                            Button {
                                Task { await checkOllamaStatus() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        
                        // Models
                        if !availableModels.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Models")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(availableModels, id: \.self) { model in
                                            Text(model)
                                                .font(.caption2.weight(.medium))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.cyan.opacity(0.15))
                                                .foregroundStyle(.cyan)
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                            }
                        }
                        
                        // Test
                        HStack {
                            Button {
                                Task { await testAI() }
                            } label: {
                                HStack(spacing: 4) {
                                    if isTestingAI {
                                        ProgressView()
                                            .scaleEffect(0.6)
                                    }
                                    Text(isTestingAI ? "Testing..." : "Test Connection")
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(!isOllamaAvailable || isTestingAI)
                            
                            Spacer()
                            
                            if let aiTestMessage {
                                Text(aiTestMessage)
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                            
                            if let aiTestError {
                                Text(aiTestError)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
    
    // MARK: - Excluded Paths
    private var excludedPathsSection: some View {
        BentoCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Excluded Paths")
                    .font(.subheadline.weight(.medium))
                
                Divider()
                
                // Add path
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    
                    TextField("Path to exclude...", text: $newExcludedPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    
                    Button("Add") {
                        addExcludedPath()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newExcludedPath.isEmpty)
                }
                
                // List
                if appState.settings.excludedPaths.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "folder.badge.minus")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                            Text("No excluded paths")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 16)
                        Spacer()
                    }
                } else {
                    VStack(spacing: 6) {
                        ForEach(appState.settings.excludedPaths, id: \.self) { path in
                            HStack {
                                Image(systemName: "folder")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                
                                Text(path)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                
                                Spacer()
                                
                                Button {
                                    removeExcludedPath(path)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(10)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Actions
    private func checkOllamaStatus() async {
        isOllamaAvailable = await OllamaClient.isAvailable()
        
        if isOllamaAvailable {
            isLoadingModels = true
            do {
                availableModels = try await OllamaClient.listModels()
            } catch {
                availableModels = []
            }
            isLoadingModels = false
        } else {
            availableModels = []
        }
    }
    
    private func testAI() async {
        aiTestError = nil
        aiTestMessage = nil
        isTestingAI = true
        
        do {
            let response = try await OllamaClient.generate(
                prompt: "Respond with exactly: AI OK",
                maxTokens: 10
            )
            await MainActor.run {
                aiTestMessage = "OK"
                isTestingAI = false
            }
        } catch {
            await MainActor.run {
                aiTestError = error.localizedDescription
                isTestingAI = false
            }
        }
    }
    
    private func addExcludedPath() {
        let path = newExcludedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !appState.settings.excludedPaths.contains(path) else { return }
        appState.settings.excludedPaths.append(path)
        newExcludedPath = ""
    }
    
    private func removeExcludedPath(_ path: String) {
        appState.settings.excludedPaths.removeAll { $0 == path }
    }
}

// MARK: - Compact Settings Toggle
struct CompactSettingsToggle: View {
    let title: String
    let description: String
    let icon: String
    let color: Color
    @Binding var isOn: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .scaleEffect(0.8)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .frame(width: 900, height: 800)
}
