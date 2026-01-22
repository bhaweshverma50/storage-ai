import Foundation
import AppKit

/// Service responsible for installing and setting up Ollama
@MainActor
final class OllamaSetupService: ObservableObject {
    
    // MARK: - Types
    
    enum SetupState: Equatable {
        case idle
        case checkingStatus
        case downloading
        case extracting
        case installing
        case launching
        case waitingForServer
        case pullingModel
        case complete
        case failed(String)
        
        var description: String {
            switch self {
            case .idle: return "Ready"
            case .checkingStatus: return "Checking Ollama status..."
            case .downloading: return "Downloading Ollama..."
            case .extracting: return "Extracting..."
            case .installing: return "Installing Ollama..."
            case .launching: return "Launching Ollama..."
            case .waitingForServer: return "Starting server..."
            case .pullingModel: return "Downloading AI model..."
            case .complete: return "Setup complete!"
            case .failed(let error): return "Failed: \(error)"
            }
        }
        
        var isInProgress: Bool {
            switch self {
            case .idle, .complete, .failed: return false
            default: return true
            }
        }
    }
    
    enum OllamaStatus: Equatable {
        case notInstalled
        case installedNotRunning
        case runningNoModel
        case ready
    }
    
    enum SetupError: LocalizedError {
        case downloadFailed(String)
        case extractionFailed
        case installationFailed(String)
        case launchFailed
        case serverTimeout
        case modelPullFailed(String)
        case cancelled
        
        var errorDescription: String? {
            switch self {
            case .downloadFailed(let reason): return "Download failed: \(reason)"
            case .extractionFailed: return "Failed to extract Ollama"
            case .installationFailed(let reason): return "Installation failed: \(reason)"
            case .launchFailed: return "Failed to launch Ollama"
            case .serverTimeout: return "Ollama server didn't start in time"
            case .modelPullFailed(let reason): return "Failed to download model: \(reason)"
            case .cancelled: return "Setup was cancelled"
            }
        }
    }
    
    // MARK: - Properties
    
    @Published private(set) var state: SetupState = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var status: OllamaStatus = .notInstalled
    @Published private(set) var statusMessage: String = ""
    
    private let ollamaDownloadURL = URL(string: "https://ollama.com/download/Ollama-darwin.zip")!
    private let defaultModel = "llama3.2"
    private var downloadTask: URLSessionDownloadTask?
    private var isCancelled = false
    
    // Possible Ollama installation paths
    private let installPaths = [
        "/Applications/Ollama.app",
        NSHomeDirectory() + "/Applications/Ollama.app"
    ]
    
    private let cliPaths = [
        "/usr/local/bin/ollama",
        "/opt/homebrew/bin/ollama"
    ]
    
    // MARK: - Status Check
    
    /// Check the current status of Ollama installation
    func checkStatus() async -> OllamaStatus {
        state = .checkingStatus
        
        // Check if installed
        guard isOllamaInstalled() else {
            status = .notInstalled
            state = .idle
            return .notInstalled
        }
        
        // Check if running
        let isRunning = await OllamaClient.isAvailable()
        guard isRunning else {
            status = .installedNotRunning
            state = .idle
            return .installedNotRunning
        }
        
        // Check if model is available
        let hasModel = await OllamaClient.hasModel(defaultModel)
        if hasModel {
            status = .ready
            state = .idle
            return .ready
        } else {
            status = .runningNoModel
            state = .idle
            return .runningNoModel
        }
    }
    
    /// Check if Ollama is installed on the system
    func isOllamaInstalled() -> Bool {
        // Check app bundles
        for path in installPaths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }
        
        // Check CLI installations
        for path in cliPaths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }
        
        return false
    }
    
    // MARK: - Full Setup Flow
    
    /// Run the complete setup flow based on current status
    func runFullSetup() async throws {
        isCancelled = false
        
        let currentStatus = await checkStatus()
        
        switch currentStatus {
        case .ready:
            state = .complete
            return
            
        case .notInstalled:
            try await downloadAndInstallOllama()
            if isCancelled { throw SetupError.cancelled }
            try await launchOllama()
            if isCancelled { throw SetupError.cancelled }
            try await waitForServer()
            if isCancelled { throw SetupError.cancelled }
            try await pullModel(defaultModel)
            
        case .installedNotRunning:
            try await launchOllama()
            if isCancelled { throw SetupError.cancelled }
            try await waitForServer()
            if isCancelled { throw SetupError.cancelled }
            // Re-check if model exists after server starts
            let hasModel = await OllamaClient.hasModel(defaultModel)
            if !hasModel {
                try await pullModel(defaultModel)
            }
            
        case .runningNoModel:
            try await pullModel(defaultModel)
        }
        
        state = .complete
        status = .ready
        progress = 1.0
    }
    
    /// Cancel ongoing setup
    func cancel() {
        isCancelled = true
        downloadTask?.cancel()
        state = .idle
        progress = 0
    }
    
    // MARK: - Download and Install
    
    private func downloadAndInstallOllama() async throws {
        state = .downloading
        progress = 0
        statusMessage = "Downloading Ollama (~60 MB)..."
        
        // Download using URLSession with progress
        let (localURL, _) = try await downloadWithProgress(from: ollamaDownloadURL)
        
        if isCancelled { throw SetupError.cancelled }
        
        // Extract ZIP
        state = .extracting
        statusMessage = "Extracting Ollama..."
        progress = 0.35
        
        let extractedURL = try await extractZip(at: localURL)
        
        if isCancelled { throw SetupError.cancelled }
        
        // Install to Applications
        state = .installing
        statusMessage = "Installing to Applications..."
        progress = 0.4
        
        try await installApp(from: extractedURL)
        
        progress = 0.45
    }
    
    private func downloadWithProgress(from url: URL) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate { [weak self] progressValue in
                Task { @MainActor in
                    self?.progress = progressValue * 0.3 // Download is 0-30% of total
                }
            }
            
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url) { localURL, response, error in
                if let error = error {
                    continuation.resume(throwing: SetupError.downloadFailed(error.localizedDescription))
                    return
                }
                
                guard let localURL = localURL, let response = response else {
                    continuation.resume(throwing: SetupError.downloadFailed("No data received"))
                    return
                }
                
                // Move to temp location that won't be auto-deleted
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Ollama-download.zip")
                try? FileManager.default.removeItem(at: tempURL)
                
                do {
                    try FileManager.default.moveItem(at: localURL, to: tempURL)
                    continuation.resume(returning: (tempURL, response))
                } catch {
                    continuation.resume(throwing: SetupError.downloadFailed("Failed to save download"))
                }
            }
            
            downloadTask = task
            task.resume()
        }
    }
    
    private func extractZip(at zipURL: URL) async throws -> URL {
        let extractDir = FileManager.default.temporaryDirectory.appendingPathComponent("Ollama-extract")
        
        // Clean up any existing extraction
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        
        // Use ditto to extract (handles macOS apps properly)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, extractDir.path]
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw SetupError.extractionFailed
        }
        
        // Find the .app in extracted contents
        let contents = try FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw SetupError.extractionFailed
        }
        
        // Clean up zip
        try? FileManager.default.removeItem(at: zipURL)
        
        return appURL
    }
    
    private func installApp(from appURL: URL) async throws {
        let destinationURL = URL(fileURLWithPath: "/Applications/Ollama.app")
        
        // Remove existing installation if present
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        
        do {
            try FileManager.default.moveItem(at: appURL, to: destinationURL)
        } catch {
            // If we can't write to /Applications, try user's Applications folder
            let userAppsURL = URL(fileURLWithPath: NSHomeDirectory() + "/Applications/Ollama.app")
            
            // Create user Applications folder if needed
            let userAppsDir = URL(fileURLWithPath: NSHomeDirectory() + "/Applications")
            if !FileManager.default.fileExists(atPath: userAppsDir.path) {
                try FileManager.default.createDirectory(at: userAppsDir, withIntermediateDirectories: true)
            }
            
            // Remove existing if present
            if FileManager.default.fileExists(atPath: userAppsURL.path) {
                try? FileManager.default.removeItem(at: userAppsURL)
            }
            
            do {
                try FileManager.default.moveItem(at: appURL, to: userAppsURL)
            } catch {
                throw SetupError.installationFailed(error.localizedDescription)
            }
        }
        
        // Clean up extraction directory
        let extractDir = appURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: extractDir)
    }
    
    // MARK: - Launch Ollama
    
    private func launchOllama() async throws {
        state = .launching
        statusMessage = "Launching Ollama..."
        progress = 0.5
        
        // Find the installed app
        var appURL: URL?
        for path in installPaths {
            if FileManager.default.fileExists(atPath: path) {
                appURL = URL(fileURLWithPath: path)
                break
            }
        }
        
        guard let appURL = appURL else {
            throw SetupError.launchFailed
        }
        
        // Launch the app
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false // Don't bring to foreground
        
        do {
            try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } catch {
            throw SetupError.launchFailed
        }
    }
    
    private func waitForServer() async throws {
        state = .waitingForServer
        statusMessage = "Waiting for Ollama server..."
        
        // Wait up to 30 seconds for server to become available
        let maxAttempts = 30
        for attempt in 0..<maxAttempts {
            if isCancelled { throw SetupError.cancelled }
            
            progress = 0.5 + (Double(attempt) / Double(maxAttempts)) * 0.05
            
            if await OllamaClient.isAvailable() {
                return
            }
            
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
        
        throw SetupError.serverTimeout
    }
    
    // MARK: - Model Pull
    
    private func pullModel(_ model: String) async throws {
        state = .pullingModel
        statusMessage = "Downloading \(model) model (~2 GB)..."
        progress = 0.55
        
        try await OllamaClient.pullModel(model) { [weak self] pullProgress, status in
            Task { @MainActor in
                guard let self = self else { return }
                // Model pull is 55-100% of total progress
                self.progress = 0.55 + (pullProgress * 0.45)
                self.statusMessage = status
            }
        }
    }
}

// MARK: - Download Delegate

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progressHandler: (Double) -> Void
    
    init(progressHandler: @escaping (Double) -> Void) {
        self.progressHandler = progressHandler
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler(progress)
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled in completion handler
    }
}
