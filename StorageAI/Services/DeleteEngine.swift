import Foundation

enum DeleteEngine {
    static func delete(targets: [CleanupTarget], dryRun: Bool) throws -> [URL] {
        var deleted: [URL] = []
        let fm = FileManager.default
        for target in targets {
            for path in target.paths {
                if dryRun {
                    deleted.append(path)
                    continue
                }
                if fm.fileExists(atPath: path.path) {
                    try fm.removeItem(at: path)
                    deleted.append(path)
                }
            }
        }
        return deleted
    }
}
