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
        temperature: Double = 0.7,
        maxTokens: Int? = nil
    ) async throws -> String {
        // First check if Ollama is available
        guard await isAvailable() else {
            throw OllamaError.notRunning
        }
        
        let url = URL(string: "\(baseURL)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        
        var payload: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": temperature
            ]
        ]
        
        if let maxTokens {
            var options = payload["options"] as? [String: Any] ?? [:]
            options["num_predict"] = maxTokens
            payload["options"] = options
        }
        
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
            if error.code == .timedOut {
                throw OllamaError.timeout
            }
            throw OllamaError.connectionFailed
        } catch is DecodingError {
            throw OllamaError.invalidResponse
        }
    }
    
    // MARK: - Generate with Retry
    static func generateWithRetry(
        prompt: String,
        model: String = defaultModel,
        maxRetries: Int = 2
    ) async throws -> String {
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                return try await generate(prompt: prompt, model: model)
            } catch OllamaError.timeout {
                lastError = OllamaError.timeout
                // Wait before retry
                try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (attempt + 1)))
            } catch {
                throw error // Don't retry other errors
            }
        }
        
        throw lastError ?? OllamaError.connectionFailed
    }
}
