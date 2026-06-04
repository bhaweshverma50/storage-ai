import os

/// Centralized structured logging via the unified logging system (visible in Console.app /
/// log archives), replacing scattered print() calls that were invisible in release builds.
/// Paths are logged with .public privacy only where they aid debugging; avoid logging file
/// contents or anything sensitive.
enum Log {
    private static let subsystem = "com.storageai.app"

    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let cache = Logger(subsystem: subsystem, category: "cache")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let app = Logger(subsystem: subsystem, category: "app")
    static let ai = Logger(subsystem: subsystem, category: "ai")
}
