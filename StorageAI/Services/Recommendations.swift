import Foundation

enum Recommendations {
    static func ruleBased(summary: StorageSummary, topApps: [AppEntry]) -> [String] {
        var items: [String] = []
        if summary.totalBytes > 200 * 1024 * 1024 * 1024 {
            items.append("Your disk usage is above 200GB. Consider archiving large media libraries.")
        }
        if let app = topApps.sorted(by: { $0.totalBytes > $1.totalBytes }).first {
            items.append("Largest app footprint: \(app.name). Review its caches and support data.")
        }
        if summary.buckets.first(where: { $0.category == .documents && $0.bytes > 30 * 1024 * 1024 * 1024 }) != nil {
            items.append("Documents exceed 30GB. Look for large archives or downloads.")
        }
        return items
    }

    static func llmSummary(prompt: String) async -> String? {
        do {
            // Cap output length so a small local model can't run to the 60s timeout, lower the
            // temperature for a factual task, add a system prompt to keep output on-format, and
            // retry once on timeout.
            return try await OllamaClient.generateWithRetry(
                prompt: prompt,
                temperature: 0.2,
                maxTokens: 400,
                system: "You are a concise macOS storage-cleanup assistant. Output ONLY a plain bullet list — one short, actionable tip per line. No preamble, no numbering, no markdown headers.",
                maxAttempts: 2
            )
        } catch {
            return nil
        }
    }
}
