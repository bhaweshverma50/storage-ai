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
            return try await OllamaClient.generate(prompt: prompt)
        } catch {
            return nil
        }
    }
}
