import SwiftUI

/// Owns the directory tree for the treemap Explorer: builds it on demand, tracks the
/// drill-down stack (breadcrumb), and exposes load/build state for the view.
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

    private var fullRoot: FileNode?
    private var buildTask: Task<Void, Never>?
    private var token: CancellationToken?

    var currentRoot: FileNode? { rootStack.last }
    var breadcrumb: [FileNode] { rootStack }
    var isBuilding: Bool { if case .building = state { return true } else { return false } }

    /// Build once on first appearance (no-op if already built or building).
    func buildIfNeeded(settings: AppSettings) {
        guard fullRoot == nil, case .idle = state else { return }
        rebuild(settings: settings)
    }

    /// Build the whole-disk tree from the configured scan roots.
    func rebuild(settings: AppSettings) {
        cancel()
        let token = CancellationToken()
        self.token = token
        state = .building(progress: "Scanning…")
        let roots = ScanRootsBuilder.roots(settings: settings)
        buildTask = Task { [weak self] in
            let node = await FileTreeBuilder.buildAll(roots: roots, token: token) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.isBuilding else { return }
                    self.state = .building(progress: progress.currentPath)
                }
            }
            await MainActor.run { [weak self] in
                guard let self, !token.isCancelled else { return }
                self.apply(builtRoot: node)
            }
        }
    }

    /// Build the tree for a single user-chosen folder.
    func open(folder: URL) {
        cancel()
        let token = CancellationToken()
        self.token = token
        state = .building(progress: folder.path)
        buildTask = Task { [weak self] in
            let node = await FileTreeBuilder.build(root: folder, token: token) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.isBuilding else { return }
                    self.state = .building(progress: progress.currentPath)
                }
            }
            await MainActor.run { [weak self] in
                guard let self, !token.isCancelled else { return }
                self.apply(builtRoot: node)
            }
        }
    }

    private func apply(builtRoot node: FileNode?) {
        if let node, (node.children?.isEmpty == false) {
            fullRoot = node
            rootStack = [node]
            selected = nil
            state = .ready
        } else {
            state = .empty
        }
    }

    /// Drill into a folder tile (becomes the new current root).
    func drillInto(_ node: FileNode) {
        guard node.isDirectory, (node.children?.isEmpty == false) else { return }
        rootStack.append(node)
        selected = nil
    }

    /// Jump to a breadcrumb level.
    func navigate(to index: Int) {
        guard index >= 0, index < rootStack.count else { return }
        rootStack = Array(rootStack.prefix(index + 1))
        selected = nil
    }

    /// Reflect a node having been trashed: drop it and update ancestor sizes.
    func didTrash(_ node: FileNode) {
        node.parent?.removeChild(node)
        if selected === node { selected = nil }
        objectWillChange.send()  // FileNode is a reference type; nudge the view to re-lay-out
    }

    func cancel() {
        buildTask?.cancel()
        token?.cancel()
        buildTask = nil
    }
}
