import SwiftUI

// MARK: - Explorer (treemap) tab

struct ExplorerView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var vm: ExplorerViewModel    // owned by DashboardView so the tree survives tab switches
    @Environment(\.accentTheme) private var accentTheme

    @State private var hovered: FileNode?
    @State private var pendingDelete: FileNode?
    @State private var actionError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .alert("Move to Trash?", isPresented: Binding(get: { pendingDelete != nil },
                                                      set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Move to Trash", role: .destructive) { confirmDelete() }
        } message: {
            Text("“\(pendingDelete?.name ?? "")” will be moved to the Trash. You can recover it from the Trash if needed.")
        }
    }

    // MARK: Header + breadcrumb

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Explorer")
                        .font(.title.weight(.semibold))
                    Text("Treemap of disk usage — bigger tile = more space")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { openFolder() } label: { Label("Open Folder…", systemImage: "folder") }
                    .buttonStyle(.bordered)
                Button { vm.rebuild(settings: appState.settings) } label: {
                    Label("Rebuild", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(vm.isBuilding)
            }
            if vm.breadcrumb.count > 1 || vm.currentRoot != nil {
                breadcrumb
            }
        }
        .padding(20)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(vm.breadcrumb.enumerated()), id: \.offset) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        vm.navigate(to: index)
                    } label: {
                        Text(node.name)
                            .font(.caption.weight(index == vm.breadcrumb.count - 1 ? .semibold : .regular))
                            .foregroundStyle(index == vm.breadcrumb.count - 1 ? Color.primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Content states

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .idle:
            Color.clear.onAppear { vm.buildIfNeeded(settings: appState.settings) }
        case .building(let path):
            buildingView(path)
        case .failed(let errorText):
            messageView(systemImage: "exclamationmark.triangle", title: "Couldn’t build the map", detail: errorText)
        case .empty:
            messageView(systemImage: "tray", title: "Nothing to show",
                        detail: "No readable files were found. Grant Full Disk Access for a complete map, or open a specific folder.")
        case .ready:
            readyView
        }
    }

    private func buildingView(_ path: String) -> some View {
        VStack(spacing: 14) {
            ProgressView().scaleEffect(1.2)
            Text("Building treemap…").font(.headline)
            Text(path).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 460)
            Button("Cancel") { vm.cancel() }.buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func messageView(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Rebuild") { vm.rebuild(settings: appState.settings) }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var readyView: some View {
        if let root = vm.currentRoot {
            VStack(spacing: 0) {
                TreemapCanvas(root: root,
                              hovered: $hovered,
                              selected: vm.selected,
                              accent: accentTheme,
                              onSelect: { vm.selected = $0 },
                              onDrill: { vm.drillInto($0) })
                    .contextMenu { contextMenu(for: hovered ?? vm.selected) }
                    .overlay(alignment: .bottomLeading) { infoOverlay }
                    .padding(12)
                legend
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for node: FileNode?) -> some View {
        if let node, isActionable(node) {
            Button { reveal(node) } label: { Label("Reveal in Finder", systemImage: "folder") }
            Button(role: .destructive) { pendingDelete = node } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        } else {
            Text("No action available")
        }
    }

    private var infoOverlay: some View {
        let node = hovered ?? vm.selected
        return Group {
            if let node {
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(node.url.path).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 8) {
                        Label(Formatters.bytes(node.sizeBytes), systemImage: "internaldrive")
                        Label(node.isDirectory ? "Folder" : node.kind.label, systemImage: node.isDirectory ? "folder" : "doc")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(16)
                .frame(maxWidth: 420, alignment: .leading)
            }
        }
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(FileKind.allCases.filter { $0 != .folder }, id: \.self) { kind in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(kind.color).frame(width: 11, height: 11)
                        Text(kind.label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: Actions

    private func isActionable(_ node: FileNode) -> Bool {
        !node.isSynthetic && FileManager.default.fileExists(atPath: node.url.path)
    }

    private func reveal(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    private func confirmDelete() {
        guard let node = pendingDelete else { return }
        pendingDelete = nil
        guard isActionable(node) else { return }
        let outcome = DeleteEngine.trashFiles([node.url])
        if outcome.trashed.contains(where: { $0.standardizedFileURL.path == node.url.standardizedFileURL.path }) {
            vm.didTrash(node)
            if hovered === node { hovered = nil }
        } else {
            let n = outcome.failedCount + outcome.blockedCount
            actionError = "Couldn’t move “\(node.name)” to Trash\(n > 0 ? " (\(n) blocked/failed)" : "")."
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            vm.open(folder: url)
        }
    }
}

// MARK: - Treemap Canvas

private struct LaidTile {
    let node: FileNode
    let rect: CGRect
}

struct TreemapCanvas: View {
    let root: FileNode
    @Binding var hovered: FileNode?
    let selected: FileNode?
    let accent: Color
    var onSelect: (FileNode) -> Void
    var onDrill: (FileNode) -> Void

    private let maxDrawDepth = 3

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let tiles = topLevelTiles(in: rect)   // hit-test targets (direct children of root)

            Canvas { ctx, _ in
                for tile in tiles {
                    drawNode(tile.node, in: tile.rect, depth: 0, ctx: ctx)
                }
                // Highlight hovered / selected top-level tiles.
                for tile in tiles {
                    if tile.node === selected {
                        ctx.stroke(roundedPath(tile.rect, inset: 0.5),
                                   with: .color(accent), lineWidth: 2.5)
                    } else if tile.node === hovered {
                        ctx.stroke(roundedPath(tile.rect, inset: 0.5),
                                   with: .color(.white.opacity(0.85)), lineWidth: 1.5)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = tiles.last { $0.rect.contains(p) }?.node
                case .ended: hovered = nil
                }
            }
            .gesture(
                SpatialTapGesture().onEnded { event in
                    guard let node = tiles.last(where: { $0.rect.contains(event.location) })?.node else { return }
                    if node.isDirectory && (node.children?.isEmpty == false) {
                        onDrill(node)
                    } else {
                        onSelect(node)
                    }
                }
            )
        }
        .background(Color.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // Direct children of the current root, laid out (these are the interaction targets).
    private func topLevelTiles(in rect: CGRect) -> [LaidTile] {
        layoutChildren(of: root, in: rect)
    }

    private func layoutChildren(of node: FileNode, in rect: CGRect) -> [LaidTile] {
        guard let kids = node.children, !kids.isEmpty else { return [] }
        let sorted = kids.sorted { $0.sizeBytes > $1.sizeBytes }
        let byId = Dictionary(uniqueKeysWithValues: sorted.map { (ObjectIdentifier($0), $0) })
        let items = sorted.map { (id: ObjectIdentifier($0), weight: Double(max($0.sizeBytes, 1))) }
        return TreemapLayout.squarify(items, in: rect).compactMap { tile in
            byId[tile.id].map { LaidTile(node: $0, rect: tile.rect) }
        }
    }

    private func roundedPath(_ rect: CGRect, inset: CGFloat) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0 else { return Path() }
        return Path(roundedRect: r, cornerRadius: min(4, r.width * 0.08))
    }

    // Recursive draw: files = solid kind color; folders = faint background + nested children
    // (the nesting is what gives folders their color, GrandPerspective-style). Decorative only;
    // hit-testing happens against the top-level tiles.
    private func drawNode(_ node: FileNode, in rect: CGRect, depth: Int, ctx: GraphicsContext) {
        guard rect.width > 1.5, rect.height > 1.5 else { return }
        let path = roundedPath(rect, inset: 0.5)

        if node.isDirectory {
            ctx.fill(path, with: .color(Color.secondary.opacity(0.14)))
            if depth < maxDrawDepth, rect.width > 22, rect.height > 22 {
                let inset = rect.insetBy(dx: 2, dy: 2)
                for child in layoutChildren(of: node, in: inset) {
                    drawNode(child.node, in: child.rect, depth: depth + 1, ctx: ctx)
                }
            }
            ctx.stroke(path, with: .color(.black.opacity(0.28)), lineWidth: 0.5)
        } else {
            let base = node.isSynthetic ? Color.secondary.opacity(0.35) : node.kind.color
            ctx.fill(path, with: .color(base.opacity(0.9)))
            // Subtle cushion: a soft highlight along the top edge.
            if rect.height > 8 {
                let hi = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.35)
                ctx.fill(roundedPath(hi, inset: 0.5), with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.22), .clear]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.35)))
            }
            ctx.stroke(path, with: .color(.black.opacity(0.22)), lineWidth: 0.5)
        }

        // Label top-level / large tiles only.
        if depth == 0, rect.width > 64, rect.height > 26 {
            let text = Text(node.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
            ctx.draw(text, at: CGPoint(x: rect.minX + 6, y: rect.minY + 5), anchor: .topLeading)
            if rect.height > 42 {
                let sub = Text(Formatters.bytes(node.sizeBytes)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.85))
                ctx.draw(sub, at: CGPoint(x: rect.minX + 6, y: rect.minY + 20), anchor: .topLeading)
            }
        }
    }
}
