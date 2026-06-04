import Foundation

enum OllamaClient {
    
    // MARK: - Configuration
    private static let baseURL = "http://127.0.0.1:11434"
    private static let defaultModel = "llama3.2"
    private static let timeout: TimeInterval = 60
    
    // MARK: - Response Models
    struct GenerateResponse: Decodable {
        let response: String
        let done: Bool
        let context: [Int]?
        let totalDuration: Int64?
        let loadDuration: Int64?
        let promptEvalCount: Int?
        let promptEvalDuration: Int64?
        let evalCount: Int?
        let evalDuration: Int64?
        
        enum CodingKeys: String, CodingKey {
            case response, done, context
            case totalDuration = "total_duration"
            case loadDuration = "load_duration"
            case promptEvalCount = "prompt_eval_count"
            case promptEvalDuration = "prompt_eval_duration"
            case evalCount = "eval_count"
            case evalDuration = "eval_duration"
        }
    }
    
    struct ModelInfo: Decodable {
        let name: String
        let size: Int64
        let digest: String
    }
    
    struct ModelsResponse: Decodable {
        let models: [ModelInfo]
    }
    
    // MARK: - Errors
    enum OllamaError: LocalizedError {
        case connectionFailed
        case notRunning
        case badStatus(Int)
        case emptyResponse
        case modelNotFound(String)
        case timeout
        case invalidResponse
        
        var errorDescription: String? {
            switch self {
            case .connectionFailed:
                return "Could not connect to Ollama. Make sure it's installed and running."
            case .notRunning:
                return "Ollama is not running. Start Ollama and try again."
            case .badStatus(let code):
                return "Ollama request failed with status \(code)."
            case .emptyResponse:
                return "Ollama returned an empty response."
            case .modelNotFound(let model):
                return "Model '\(model)' not found. Run 'ollama pull \(model)' to download it."
            case .timeout:
                return "Request timed out. The model may be loading or your Mac may be busy."
            case .invalidResponse:
                return "Received an invalid response from Ollama."
            }
        }
        
        var recoverySuggestion: String? {
            switch self {
            case .connectionFailed, .notRunning:
                return "1. Open Terminal\n2. Run: ollama serve\n3. Try again"
            case .modelNotFound(let model):
                return "Run: ollama pull \(model)"
            case .timeout:
                return "Try again or use a smaller model"
            default:
                return nil
            }
        }
    }
    
    // MARK: - Health Check
    static func isAvailable() async -> Bool {
        do {
            let url = URL(string: "\(baseURL)/api/tags")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200...299).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }
    
    // MARK: - List Available Models
    static func listModels() async throws -> [String] {
        let url = URL(string: "\(baseURL)/api/tags")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw OllamaError.badStatus(http.statusCode)
            }
            
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.models.map(\.name)
        } catch is URLError {
            throw OllamaError.connectionFailed
        }
    }
    
    // MARK: - Generate Response
    static func generate(
        prompt: String,
        model: String = defaultModel,
        temperature: Double = 0.3,
        maxTokens: Int? = nil,
        system: String? = nil,
        format: String? = nil
    ) async throws -> String {
        // No separate /api/tags pre-check: the POST below already surfaces connection/timeout
        // errors, so we avoid the extra round-trip (and its 5s timeout) on every call.
        let url = URL(string: "\(baseURL)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        var options: [String: Any] = ["temperature": temperature]
        if let maxTokens { options["num_predict"] = maxTokens }

        var payload: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": options
        ]
        if let system { payload["system"] = system }
        if let format { payload["format"] = format }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        do {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout * 2
            let session = URLSession(configuration: config)

            let (data, response) = try await session.data(for: request)

            if let http = response as? HTTPURLResponse {
                if http.statusCode == 404 {
                    throw OllamaError.modelNotFound(model)
                }
                if !(200...299).contains(http.statusCode) {
                    throw OllamaError.badStatus(http.statusCode)
                }
            }

            let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
            let trimmed = decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                throw OllamaError.emptyResponse
            }

            return trimmed

        } catch let error as OllamaError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw OllamaError.timeout
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                throw OllamaError.notRunning
            default:
                throw OllamaError.connectionFailed
            }
        } catch is DecodingError {
            throw OllamaError.invalidResponse
        }
    }

    // MARK: - Generate with Retry
    /// Runs `generate`, retrying only on timeouts. `maxAttempts` is the TOTAL number of tries.
    static func generateWithRetry(
        prompt: String,
        model: String = defaultModel,
        temperature: Double = 0.3,
        maxTokens: Int? = nil,
        system: String? = nil,
        maxAttempts: Int = 2
    ) async throws -> String {
        var lastError: Error = OllamaError.connectionFailed
        for attempt in 0..<max(1, maxAttempts) {
            do {
                return try await generate(prompt: prompt, model: model, temperature: temperature, maxTokens: maxTokens, system: system)
            } catch OllamaError.timeout {
                lastError = OllamaError.timeout
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (attempt + 1)))
            } catch {
                throw error // Don't retry non-timeout errors
            }
        }
        throw lastError
    }
    
    // MARK: - Check if Model Exists
    
    /// Does an installed model name satisfy a request for `requested`? Compares on the base
    /// (pre-colon) name so that "llama3.2" does NOT match "llama3", while ":latest"/tag
    /// variants of the same base do match.
    static func modelNameMatches(requested: String, installed: String) -> Bool {
        guard !installed.isEmpty, !requested.isEmpty else { return false }
        if requested == installed { return true }
        func base(_ s: String) -> String { s.split(separator: ":").first.map(String.init) ?? s }
        let rb = base(requested), ib = base(installed)
        return !ib.isEmpty && rb == ib
    }

    /// Check if a specific model is available locally
    static func hasModel(_ model: String) async -> Bool {
        do {
            let models = try await listModels()
            return models.contains { modelNameMatches(requested: model, installed: $0) }
        } catch {
            return false
        }
    }
    
    // MARK: - Pull Model
    
    /// Response structure for pull progress
    private struct PullProgressResponse: Decodable {
        let status: String
        let digest: String?
        let total: Int64?
        let completed: Int64?
    }
    
    /// Pull a model from Ollama registry with progress tracking
    /// - Parameters:
    ///   - model: Model name to pull (e.g., "llama3.2")
    ///   - progress: Callback with progress (0-1) and status message
    static func pullModel(
        _ model: String,
        shouldCancel: @escaping () -> Bool = { false },
        progress: @escaping (Double, String) -> Void
    ) async throws {
        let url = URL(string: "\(baseURL)/api/pull")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3600 // 1 hour timeout for large models
        
        let payload: [String: Any] = [
            "name": model,
            "stream": true
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        // Use bytes stream for progress tracking
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config)
        
        let (bytes, response) = try await session.bytes(for: request)
        
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OllamaError.badStatus(http.statusCode)
        }
        
        var buffer = Data()
        // Each pull-progress JSON line is tiny; cap the line buffer so a malicious or broken
        // server can't stream gigabytes without a newline and exhaust memory.
        let maxLineBytes = 64 * 1024

        for try await byte in bytes {
            // Cooperative cancellation: stop streaming if the task is cancelled or the caller
            // signals cancellation (e.g. the user pressed Cancel during a multi-GB pull).
            if Task.isCancelled || shouldCancel() { throw CancellationError() }

            buffer.append(byte)
            if buffer.count > maxLineBytes {
                throw OllamaError.invalidResponse
            }

            // Check for newline (each JSON object is on its own line)
            if byte == UInt8(ascii: "\n") {
                if let line = String(data: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !line.isEmpty,
                   let jsonData = line.data(using: .utf8) {
                    
                    if let progressResponse = try? JSONDecoder().decode(PullProgressResponse.self, from: jsonData) {
                        let statusMessage = formatPullStatus(progressResponse)
                        let progressValue = calculatePullProgress(progressResponse)
                        progress(progressValue, statusMessage)
                        
                        // Check for completion
                        if progressResponse.status == "success" {
                            progress(1.0, "Download complete!")
                            return
                        }
                    }
                }
                buffer.removeAll()
            }
        }
    }
    
    private static func formatPullStatus(_ response: PullProgressResponse) -> String {
        switch response.status {
        case "pulling manifest":
            return "Fetching model info..."
        case let status where status.starts(with: "pulling"):
            if let completed = response.completed, let total = response.total, total > 0 {
                let percent = Int((Double(completed) / Double(total)) * 100)
                let completedMB = completed / 1_000_000
                let totalMB = total / 1_000_000
                return "Downloading: \(completedMB) MB / \(totalMB) MB (\(percent)%)"
            }
            return "Downloading model..."
        case "verifying sha256 digest":
            return "Verifying download..."
        case "writing manifest":
            return "Saving model..."
        case "removing any unused layers":
            return "Cleaning up..."
        case "success":
            return "Download complete!"
        default:
            return response.status.capitalized
        }
    }
    
    private static func calculatePullProgress(_ response: PullProgressResponse) -> Double {
        guard let completed = response.completed, let total = response.total, total > 0 else {
            // For non-download phases, return small progress values
            switch response.status {
            case "pulling manifest": return 0.01
            case "verifying sha256 digest": return 0.95
            case "writing manifest": return 0.97
            case "removing any unused layers": return 0.98
            case "success": return 1.0
            default: return 0.0
            }
        }
        
        // Download progress (scaled to 0.02 - 0.94 range)
        let downloadProgress = Double(completed) / Double(total)
        return 0.02 + (downloadProgress * 0.92)
    }
}
