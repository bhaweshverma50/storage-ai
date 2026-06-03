import Foundation

final class FileNode {
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

    func addChild(_ node: FileNode) {
        node.parent = self
        children?.append(node)
        sizeBytes += node.sizeBytes
    }

    /// Set size directly (used by the builder while aggregating bottom-up).
    func setSize(_ bytes: Int64) { sizeBytes = bytes }

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
