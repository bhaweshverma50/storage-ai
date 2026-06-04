import SwiftUI
import AppKit

struct OnboardingFlow: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var ollamaSetupService: OllamaSetupService  // observe AI setup state directly (STATE-4)
    @State private var currentStep = 0
    @State private var fullDiskAccessGranted = false
    @State private var hasCheckedAccess = false
    @State private var isAnimating = false
    @State private var showOllamaSetup = false
    @State private var enableAI = true
    
    private let steps: [OnboardingStep] = [
        OnboardingStep(
            icon: "sparkles",
            iconColor: .purple,
            title: "Welcome to SpaceLens",
            subtitle: "Your intelligent storage companion",
            description: "We'll help you understand exactly where your disk space is going and how to reclaim it. Let's set up a few permissions to get started.",
            buttonTitle: nil,
            buttonAction: nil
        ),
        OnboardingStep(
            icon: "externaldrive.badge.checkmark",
            iconColor: .blue,
            title: "Full Disk Access",
            subtitle: "Required for complete scans",
            description: "This permission allows SpaceLens to scan all files on your Mac, including system files and app data. Without it, some areas may be inaccessible.",
            buttonTitle: "Open System Settings",
            buttonAction: { openPrivacyPane("Privacy_AllFiles") }
        ),
        OnboardingStep(
            icon: "folder.badge.gearshape",
            iconColor: .orange,
            title: "Files & Folders",
            subtitle: "Access your documents",
            description: "Grant access to common folders like Downloads, Documents, and Desktop for a complete picture of your storage usage.",
            buttonTitle: "Open System Settings",
            buttonAction: { openPrivacyPane("Privacy_FilesAndFolders") }
        ),
        OnboardingStep(
            icon: "cpu",
            iconColor: .cyan,
            title: "AI Recommendations",
            subtitle: "Optional: Local AI insights",
            description: "SpaceLens can use Ollama (local AI) to provide smart cleanup recommendations. This runs entirely on your Mac for privacy.",
            buttonTitle: nil, // We'll use custom UI for this step
            buttonAction: nil
        ),
        OnboardingStep(
            icon: "checkmark.circle.fill",
            iconColor: .green,
            title: "You're All Set!",
            subtitle: "Ready to analyze your storage",
            description: "Everything is configured. Start your first scan to see a detailed breakdown of your storage usage with actionable recommendations.",
            buttonTitle: nil,
            buttonAction: nil
        )
    ]
    
    var body: some View {
        HStack(spacing: 0) {
            // Left Panel - Illustration
            leftPanel
            
            // Right Panel - Content
            rightPanel
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Left Panel
    private var leftPanel: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    steps[currentStep].iconColor.opacity(0.8),
                    steps[currentStep].iconColor.opacity(0.4)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 40) {
                // Animated Icon
                ZStack {
                    // Pulse rings
                    ForEach(0..<3) { i in
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            .frame(width: CGFloat(120 + i * 40), height: CGFloat(120 + i * 40))
                            .scaleEffect(isAnimating ? 1.2 : 1.0)
                            .opacity(isAnimating ? 0 : 0.5)
                            .animation(
                                .easeOut(duration: 2)
                                    .repeatForever(autoreverses: false)
                                    .delay(Double(i) * 0.4),
                                value: isAnimating
                            )
                    }
                    
                    // Main icon background
                    Circle()
                        .fill(.white.opacity(0.2))
                        .frame(width: 120, height: 120)
                    
                    // Icon
                    Image(systemName: steps[currentStep].icon)
                        .font(.system(size: 50))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, value: currentStep)
                }
                
                // Step indicator dots
                HStack(spacing: 8) {
                    ForEach(0..<steps.count, id: \.self) { index in
                        Circle()
                            .fill(index == currentStep ? .white : .white.opacity(0.4))
                            .frame(width: index == currentStep ? 10 : 8, height: index == currentStep ? 10 : 8)
                            .animation(.spring(response: 0.3), value: currentStep)
                    }
                }
                
                // Step counter
                Text("Step \(currentStep + 1) of \(steps.count)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(width: 350)
        .onAppear {
            isAnimating = true
        }
    }
    
    // MARK: - Right Panel
    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            
            VStack(alignment: .leading, spacing: 24) {
                // Badge
                Text(steps[currentStep].subtitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(steps[currentStep].iconColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(steps[currentStep].iconColor.opacity(0.1))
                    .clipShape(Capsule())
                
                // Title
                Text(steps[currentStep].title)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                
                // Description
                Text(steps[currentStep].description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                
                // Permission check for step 1
                if currentStep == 1 {
                    permissionCheckSection
                }
                
                // AI setup for step 3
                if currentStep == 3 {
                    aiSetupSection
                }
                
                // Action button
                if let buttonTitle = steps[currentStep].buttonTitle,
                   let action = steps[currentStep].buttonAction {
                    Button {
                        action()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.up.right.square")
                            Text(buttonTitle)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 48)
            .animation(.spring(response: 0.4), value: currentStep)
            
            Spacer()
            
            // Navigation
            navigationButtons
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Permission Check Section
    private var permissionCheckSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .padding(.vertical, 8)
            
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(fullDiskAccessGranted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: fullDiskAccessGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(fullDiskAccessGranted ? .green : .orange)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(fullDiskAccessGranted ? "Full Disk Access Granted" : "Full Disk Access Required")
                        .font(.subheadline.weight(.medium))
                    
                    Text(fullDiskAccessGranted ? "You're all set to scan your entire disk" : "Enable access in System Settings, then check again")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button("Check Access") {
                    checkFullDiskAccess()
                }
                .buttonStyle(.borderedProminent)
                .tint(fullDiskAccessGranted ? .green : .blue)
            }
            .padding(16)
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
    
    // MARK: - AI Setup Section
    private var aiSetupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .padding(.vertical, 8)
            
            // Enable AI Toggle
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(0.15))
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: "cpu")
                        .foregroundStyle(.cyan)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable AI Recommendations")
                        .font(.subheadline.weight(.medium))
                    
                    Text("Get smart cleanup suggestions powered by local AI")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Toggle("", isOn: $enableAI)
                    .toggleStyle(.switch)
                    .onChange(of: enableAI) { _, newValue in
                        appState.settings.ollamaEnabled = newValue
                    }
            }
            .padding(16)
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            
            // Setup Section (only if AI is enabled)
            if enableAI {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(aiStatusColor.opacity(0.15))
                            .frame(width: 40, height: 40)
                        
                        Image(systemName: aiStatusIcon)
                            .foregroundStyle(aiStatusColor)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(aiStatusTitle)
                            .font(.subheadline.weight(.medium))
                        
                        Text(aiStatusDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    if appState.ollamaSetupService.status != .ready {
                        Button("Set Up Ollama") {
                            showOllamaSetup = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                    }
                }
                .padding(16)
                .background(Color.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                
                // Info about disk space
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    
                    Text("Requires ~2.5 GB of disk space. You can set this up later in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $showOllamaSetup) {
            OllamaSetupSheet()
                .environmentObject(appState)
        }
        .task {
            _ = await appState.ollamaSetupService.checkStatus()
        }
    }
    
    private var aiStatusColor: Color {
        switch appState.ollamaSetupService.status {
        case .ready: return .green
        case .runningNoModel: return .yellow
        case .installedNotRunning: return .orange
        case .notInstalled: return .gray
        }
    }
    
    private var aiStatusIcon: String {
        switch appState.ollamaSetupService.status {
        case .ready: return "checkmark.circle.fill"
        case .runningNoModel: return "arrow.down.circle"
        case .installedNotRunning: return "play.circle"
        case .notInstalled: return "arrow.down.circle"
        }
    }
    
    private var aiStatusTitle: String {
        switch appState.ollamaSetupService.status {
        case .ready: return "Ollama Ready"
        case .runningNoModel: return "Model Download Required"
        case .installedNotRunning: return "Ollama Not Running"
        case .notInstalled: return "Ollama Not Installed"
        }
    }
    
    private var aiStatusDescription: String {
        switch appState.ollamaSetupService.status {
        case .ready: return "AI recommendations are available"
        case .runningNoModel: return "Ollama is running but needs the AI model"
        case .installedNotRunning: return "Click Set Up to start Ollama"
        case .notInstalled: return "Click Set Up to install Ollama"
        }
    }
    
    // MARK: - Navigation Buttons
    private var navigationButtons: some View {
        HStack {
            // Back button
            if currentStep > 0 {
                Button {
                    withAnimation(.spring(response: 0.4)) {
                        currentStep -= 1
                    }
                } label: {
                    HStack {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Skip button (for optional steps)
            if currentStep == 2 || currentStep == 3 {
                Button("Skip") {
                    withAnimation(.spring(response: 0.4)) {
                        currentStep += 1
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            
            // Continue/Finish button
            Button {
                if currentStep == steps.count - 1 {
                    completeOnboarding()
                } else {
                    withAnimation(.spring(response: 0.4)) {
                        currentStep += 1
                    }
                }
            } label: {
                HStack {
                    Text(currentStep == steps.count - 1 ? "Get Started" : "Continue")
                    Image(systemName: currentStep == steps.count - 1 ? "sparkles" : "chevron.right")
                }
                .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // Don't trap the user on the Full Disk Access step: granting it typically needs an
            // app relaunch (so re-checking keeps returning false this session), and the app works
            // without it — scans just show an advisory when access is missing.
        }
        .padding(32)
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Actions
    private func checkFullDiskAccess() {
        fullDiskAccessGranted = PermissionsChecker.hasFullDiskAccess()
        hasCheckedAccess = true
    }
    
    private func completeOnboarding() {
        withAnimation(.spring(response: 0.4)) {
            appState.didCompleteOnboarding = true
        }
    }
}

// MARK: - Onboarding Step Model
struct OnboardingStep {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let description: String
    let buttonTitle: String?
    let buttonAction: (() -> Void)?
}

// MARK: - Helper Functions
private func openPrivacyPane(_ pane: String) {
    let urlString = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
    if let url = URL(string: urlString) {
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    let state = AppState()
    return OnboardingFlow()
        .environmentObject(state)
        .environmentObject(state.ollamaSetupService)
        .frame(width: 900, height: 600)
}
