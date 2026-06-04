import SwiftUI

/// Drives the treemap Explorer with bounded memory: one walk builds a compact folder-size index,
/// then levels are materialized on demand (current root's children + one nested level for the
/// classic look). Only the visible path is retained, so memory stays in the tens of MB.
@MainActor
final class ExplorerViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case building(progress: String)
        case ready
        case failed(String)
        case empty
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var rootStack: [FileNode] = []   // breadcrumb; last element = current root
    @Published var selected: FileNode?

    private var index: FileTreeBuilder.SizeIndex?
    private var buildTask: Task<Void, Never>?
    private var token: CancellationToken?

    var currentRoot: FileNode? { rootStack.last }
    var breadcrumb: [FileNode] { rootStack }
    var isBuilding: Bool { if case .building = state { return true } else { return false } }

    func buildIfNeeded(settings: AppSettings) {
        guard index == nil, case .idle = state else { return }
        rebuild(settings: settings)
    }

    /// Index the whole-disk scan roots, then show them as the top level.
    func rebuild(settings: AppSettings) {
        let roots = ScanRootsBuilder.roots(settings: settings)
        startIndexing(roots: roots) {
            let children = roots.map { FileNode(name: $0.lastPathComponent, url: $0,
                                                sizeBytes: self.index?.size(of: $0) ?? 0, isDirectory: true) }
            let all = FileNode(name: "All Locations", url: URL(fileURLWithPath: "/"), isDirectory: true, children: children)
            all.isSynthetic = true
            return all
        }
    }

    /// Index a single user-chosen folder and show it as the root.
    func open(folder: URL) {
        startIndexing(roots: [folder]) {
            FileNode(name: folder.lastPathComponent, url: folder,
                     sizeBytes: self.index?.size(of: folder) ?? 0, isDirectory: true)
        }
    }

    private func startIndexing(roots: [URL], makeRoot: @escaping () -> FileNode) {
        cancel()
        let token = CancellationToken()
        self.token = token
        state = .building(progress: "Scanning…")
        buildTask = Task { [weak self] in
            let idx = await FileTreeBuilder.indexSizes(roots: roots, token: token) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.isBuilding else { return }
                    self.state = .building(progress: progress.currentPath)
                }
            }
            guard !token.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !token.isCancelled else { return }
                guard let idx, !idx.sizes.isEmpty else { self.state = .empty; return }
                self.index = idx
                let root = makeRoot()
                self.rootStack = [root]
                self.selected = nil
            }
            await self?.prepare(self?.currentRoot)
            await MainActor.run { [weak self] in
                guard let self, !token.isCancelled else { return }
                self.state = (self.currentRoot?.children?.isEmpty == false) ? .ready : .empty
            }
        }
    }

    /// Materialize a node's children + one nested level (for the classic nested look). Off-main I/O.
    private func prepare(_ node: FileNode?) async {
        guard let node, let index else { return }
        await Task.detached(priority: .userInitiated) {
            if !node.childrenLoaded {
                node.setChildren(FileTreeBuilder.levelChildren(of: node.url, index: index))
            }
            for child in node.children ?? [] where child.isDirectory && !child.childrenLoaded {
                child.setChildren(FileTreeBuilder.levelChildren(of: child.url, index: index))
            }
        }.value
    }

    func drillInto(_ node: FileNode) {
        guard node.isDirectory, !node.isSynthetic else { return }
        rootStack.append(node)
        selected = nil
        Task { [weak self] in
            await self?.prepare(node)
            await MainActor.run { self?.objectWillChange.send() }
        }
    }

    func navigate(to index: Int) {
        guard index >= 0, index < rootStack.count else { return }
        rootStack = Array(rootStack.prefix(index + 1))
        selected = nil
    }

    /// Reflect a node having been trashed: drop it and update ancestor sizes.
    func didTrash(_ node: FileNode) {
        node.parent?.removeChild(node)
        if selected === node { selected = nil }
        objectWillChange.send()
    }

    func cancel() {
        buildTask?.cancel()
        token?.cancel()
        buildTask = nil
    }
}
