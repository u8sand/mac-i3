import Foundation

extension Tree {
    /// Compact one-line shape of a container, e.g. `H[1 V[2 3*]]` (`*` marks focus,
    /// `~5` a floating window). H/V split, S stacking, T tabbed.
    public func shape(_ c: Con) -> String {
        let mark = focused === c ? "*" : ""
        if c.isWindow { return "\(c.windowID.map(String.init) ?? "?")\(mark)" }
        let tag: String
        switch c.layout {
        case .splitH: tag = "H"
        case .splitV: tag = "V"
        case .stacked: tag = "S"
        case .tabbed: tag = "T"
        }
        var parts = c.children.map { shape($0) }
        parts += c.floating.map { "~\(shape($0))" }
        return "\(tag)[\(parts.joined(separator: " "))]\(mark)"
    }

    public func shape(workspace name: String) -> String? {
        workspace(named: name).map { shape($0) }
    }

    /// Shape of the active workspace.
    public var activeShape: String { shape(activeWorkspace) }

    /// JSON description of the tree (like `i3-msg -t get_tree`).
    public func jsonTree() -> [String: Any] { json(root) }

    private func json(_ c: Con) -> [String: Any] {
        var d: [String: Any] = [
            "type": c.kind.rawValue,
            "focused": focused === c,
            "rect": ["x": c.rect.x, "y": c.rect.y, "width": c.rect.w, "height": c.rect.h],
        ]
        if c.kind != .window && c.kind != .root { d["layout"] = c.layout.rawValue }
        if !c.name.isEmpty { d["name"] = c.name }
        if c.kind == .output && !c.title.isEmpty { d["label"] = c.title }
        if c.isWindow { d["id"] = c.windowID.map { Int($0) } ?? 0; d["title"] = c.title; d["floating"] = c.isFloating; d["fullscreen"] = c.fullscreen }
        if c.kind != .window { d["percent"] = c.percent }
        if !c.children.isEmpty { d["nodes"] = c.children.map { json($0) } }
        if !c.floating.isEmpty { d["floating_nodes"] = c.floating.map { json($0) } }
        return d
    }
}
