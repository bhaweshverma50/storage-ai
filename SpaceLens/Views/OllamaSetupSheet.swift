import SwiftUI

struct OllamaSetupSheet: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var ollamaSetupService: OllamaSetupService  // observe AI setup state directly (STATE-4)
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accentTheme) private var accentTheme
    
    @State private var errorMessage: String?
    @State private var showManualInstructions = false
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            headerSection
            
            Divider()
            
            // Content based on state
            if appState.ollamaSetupService.state == .complete {
                successSection
            } else if case .failed(let error) = appState.ollamaSetupService.state {
                failedSection(error: error)
            } else if appState.ollamaSetupService.state.isInProgress {
                progressSection
            } else {
                setupPromptSection
            }
            
            Spacer()
            
            // Actions
            actionButtons
        }
        .padding(24)
        .frame(width: 450, height: 380)
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack(spacing: 16) {
            // Ollama Logo placeholder
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [accentTheme, accentTheme.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 56, height: 56)
                
                Image(systemName: "cpu")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Ollama Setup")
                    .font(.title2.weight(.semibold))
                
                Text("Local AI for smart cleanup recommendations")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
    }
    
    // MARK: - Setup Prompt
    
    private var setupPromptSection: some View {
        VStack(spacing: 16) {
            // Status indicator
            statusIndicator
            
            // Info text
            VStack(spacing: 8) {
                Text(statusDescription)
                    .font(.body)
                    .multilineTextAlignment(.center)
                
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            // Storage warning
            HStack(spacing: 8) {
                Image(systemName: "externaldrive")
                    .foregroundStyle(.orange)
                
                Text("Requires approximately 2.5 GB of disk space")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    
    private var statusIndicator: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            
            Text(statusTitle)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(statusColor.opacity(0.1), in: Capsule())
    }
    
    private var statusTitle: String {
        switch appState.ollamaSetupService.status {
        case .notInstalled: return "Ollama Not Installed"
        case .installedNotRunning: return "Ollama Not Running"
        case .runningNoModel: return "Model Required"
        case .ready: return "Ready"
        }
    }
    
    private var statusColor: Color {
        switch appState.ollamaSetupService.status {
        case .notInstalled: return .red
        case .installedNotRunning: return .orange
        case .runningNoModel: return .yellow
        case .ready: return .green
        }
    }
    
    private var statusDescription: String {
        switch appState.ollamaSetupService.status {
        case .notInstalled:
            return "Ollama needs to be installed to enable AI-powered cleanup recommendations."
        case .installedNotRunning:
            return "Ollama is installed but not running. Start Ollama to continue."
        case .runningNoModel:
            return "Ollama is running but the AI model needs to be downloaded."
        case .ready:
            return "Ollama is ready! You can close this dialog."
        }
    }
    
    private var statusDetail: String {
        switch appState.ollamaSetupService.status {
        case .notInstalled:
            return "This will download and install Ollama, then download the llama3.2 model."
        case .installedNotRunning:
            return "Click 'Start Ollama' to launch the Ollama service."
        case .runningNoModel:
            return "Click 'Download Model' to get the llama3.2 AI model."
        case .ready:
            return "AI recommendations are now available."
        }
    }
    
    // MARK: - Progress Section
    
    private var progressSection: some View {
        VStack(spacing: 20) {
            // Animated icon
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
                    .frame(width: 60, height: 60)
                
                Circle()
                    .trim(from: 0, to: appState.ollamaSetupService.progress)
                    .stroke(accentTheme, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 60, height: 60)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: appState.ollamaSetupService.progress)
                
                Image(systemName: progressIcon)
                    .font(.title2)
                    .foregroundStyle(accentTheme)
            }
            
            // Progress info
            VStack(spacing: 8) {
                Text(appState.ollamaSetupService.state.description)
                    .font(.headline)
                
                Text(appState.ollamaSetupService.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                
                // Progress percentage
                Text("\(Int(appState.ollamaSetupService.progress * 100))%")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(accentTheme)
                    .contentTransition(.numericText())
            }
            
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(accentTheme)
                        .frame(width: max(0, geo.size.width * appState.ollamaSetupService.progress))
                        .animation(.easeInOut(duration: 0.3), value: appState.ollamaSetupService.progress)
                }
            }
            .frame(height: 6)
        }
    }
    
    private var progressIcon: String {
        switch appState.ollamaSetupService.state {
        case .downloading, .extracting: return "arrow.down.circle"
        case .installing: return "folder"
        case .launching, .waitingForServer: return "play.circle"
        case .pullingModel: return "cpu"
        default: return "gear"
        }
    }
    
    // MARK: - Success Section
    
    private var successSection: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
            }
            
            VStack(spacing: 8) {
                Text("Setup Complete!")
                    .font(.title2.weight(.semibold))
                
                Text("Ollama is ready. AI-powered cleanup recommendations are now available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
    
    // MARK: - Failed Section
    
    private func failedSection(error: String) -> some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.15))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)
            }
            
            VStack(spacing: 8) {
                Text("Setup Failed")
                    .font(.title2.weight(.semibold))
                
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            // Manual install option
            Button {
                showManualInstructions = true
            } label: {
                Label("Manual Installation", systemImage: "questionmark.circle")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .popover(isPresented: $showManualInstructions) {
                manualInstructionsPopover
            }
        }
    }
    
    private var manualInstructionsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manual Installation")
                .font(.headline)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                instructionRow(number: 1, text: "Visit ollama.com/download")
                instructionRow(number: 2, text: "Download Ollama for macOS")
                instructionRow(number: 3, text: "Open the downloaded file")
                instructionRow(number: 4, text: "Drag Ollama to Applications")
                instructionRow(number: 5, text: "Launch Ollama from Applications")
                instructionRow(number: 6, text: "Open Terminal and run:")
                
                Text("ollama pull llama3.2")
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            
            Button("Open ollama.com") {
                if let url = URL(string: "https://ollama.com/download") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding()
        .frame(width: 280)
    }
    
    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            
            Text(text)
                .font(.caption)
        }
    }
    
    // MARK: - Action Buttons
    
    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Cancel/Close button
            Button(appState.ollamaSetupService.state == .complete ? "Close" : "Cancel") {
                if appState.ollamaSetupService.state.isInProgress {
                    appState.ollamaSetupService.cancel()
                }
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            
            Spacer()
            
            // Primary action button
            if !appState.ollamaSetupService.state.isInProgress && appState.ollamaSetupService.state != .complete {
                Button(action: startSetup) {
                    HStack(spacing: 6) {
                        Image(systemName: primaryButtonIcon)
                        Text(primaryButtonTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            
            if appState.ollamaSetupService.state == .complete {
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            
            if case .failed = appState.ollamaSetupService.state {
                Button("Retry") {
                    startSetup()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }
    
    private var primaryButtonTitle: String {
        switch appState.ollamaSetupService.status {
        case .notInstalled: return "Set Up Ollama"
        case .installedNotRunning: return "Start Ollama"
        case .runningNoModel: return "Download Model"
        case .ready: return "Done"
        }
    }
    
    private var primaryButtonIcon: String {
        switch appState.ollamaSetupService.status {
        case .notInstalled: return "arrow.down.circle"
        case .installedNotRunning: return "play.fill"
        case .runningNoModel: return "arrow.down.circle"
        case .ready: return "checkmark"
        }
    }
    
    // MARK: - Actions
    
    private func startSetup() {
        Task {
            do {
                try await appState.ollamaSetupService.runFullSetup()
            } catch {
                // Error is handled by the service and reflected in state
            }
        }
    }
}

#Preview {
    let state = AppState()
    return OllamaSetupSheet()
        .environmentObject(state)
        .environmentObject(state.ollamaSetupService)
}
