import Foundation

enum PermissionsChecker {
    static func hasFullDiskAccess() -> Bool {
        let tccDB = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        return FileManager.default.isReadableFile(atPath: tccDB.path)
    }
}
