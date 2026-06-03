import Foundation

/// A node in the aggregated directory tree backing the treemap.
///
/// Built off-thread by `FileTreeBuilder` and then handed to the `@MainActor` view layer, which
/// is the only place it's mutated afterward (e.g. `removeChild` on delete). That build-then-handoff
/// ownership means it's safe to transfer across the actor boundary, which `@unchecked Sendable`
/// asserts (the alternative, leaving it non-Sendable, breaks the handoff under strict concurrency).
final class FileNode: @unchecked Sendable {
    let name: String
    let url: URL
    let isDirectory: Bool
    private(set) var sizeBytes: Int64
    private(set) var children: [FileNode]?
    weak var parent: FileNode?
    let kind: FileKind

    // File initializer
    init(name: String, url: URL, sizeBytes: Int64, isDirectory: Bool) {
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.children = isDirectory ? [] : nil
        self.kind = isDirectory ? .folder : FileKind.forExtension(url.pathExtension)
    }

    // Folder initializer with children (sizes aggregated)
    convenience init(name: String, url: URL, isDirectory: Bool, children: [FileNode]) {
        self.init(name: name, url: url, sizeBytes: 0, isDirectory: isDirectory)
        self.children = children
        for c in children { c.parent = self }
        self.sizeBytes = children.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Remove a child and propagate the size delta up the ancestor chain.
    func removeChild(_ node: FileNode) {
        guard var kids = children, let idx = kids.firstIndex(where: { $0 === node }) else { return }
        let delta = node.sizeBytes
        kids.remove(at: idx)
        children = kids
        var n: FileNode? = self
        while let cur = n { cur.sizeBytes = max(0, cur.sizeBytes - delta); n = cur.parent }
    }
}
