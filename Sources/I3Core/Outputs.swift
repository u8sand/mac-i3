import Foundation

// Workspace <-> output assignment (`workspace 1 output HDMI-1`, `move workspace to output ...`).
extension Tree {

    /// Names for outputs beyond their id, e.g. the display's product name, used to match output specs.
    public func setOutputLabels(_ labels: [String: String], primary: String?) {
        for o in root.children { if let l = labels[o.name] { o.title = l } }
        primaryOutputName = primary
    }

    /// Replace the workspace -> output assignments (from the config) and apply them right away.
    public func setWorkspaceOutputs(_ prefs: [String: [String]]) {
        workspaceOutputs = prefs
        enforceWorkspaceOutputs()
    }

    /// The primary output (the one with the menu bar); the first output when none is marked.
    public var primaryOutput: Con? { root.children.first { $0.name == primaryOutputName } ?? root.children.first }

    /// Outputs in user-facing order: `output 1` is the primary display, then the others left to right.
    public var numberedOutputs: [Con] {
        let primary = primaryOutput
        return [primary].compactMap { $0 } + root.children.filter { $0 !== primary }
    }

    /// Match an output spec: a number (`1` = primary, `2`, `3`... = the others left to right), `primary`, an
    /// output's name or label (case-insensitive), or a substring of a label that identifies exactly one
    /// output. Nil when nothing matches, e.g. `2` with a single display. `left|right|up|down` are relative
    /// and handled by callers.
    public func resolveOutput(_ spec: String) -> Con? {
        let s = spec.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        guard !s.isEmpty else { return nil }
        if let n = Int(s) { return numberedOutputs.indices.contains(n - 1) ? numberedOutputs[n - 1] : nil }
        if s == "primary" { return primaryOutput }
        if let exact = root.children.first(where: { $0.name.lowercased() == s || $0.title.lowercased() == s }) { return exact }
        let partial = root.children.filter { $0.title.lowercased().contains(s) }
        return partial.count == 1 ? partial[0] : nil
    }

    /// Where an assigned workspace should live: the first of its outputs that is connected, otherwise the
    /// primary output. Nil for a workspace with no assignment.
    func preferredOutput(for workspaceName: String) -> Con? {
        guard let specs = workspaceOutputs[workspaceName] else { return nil }
        for spec in specs { if let o = resolveOutput(spec) { return o } }
        return primaryOutput
    }

    /// Move every existing workspace to its assigned output (called after the config or the displays change).
    /// Which workspaces were showing is decided up front, so two showing workspaces that swap outputs both
    /// stay showing.
    public func enforceWorkspaceOutputs() {
        func key(_ n: String) -> (Int, String) { (Int(n) ?? Int.max, n) }
        let showing = Set(root.children.map { ObjectIdentifier(currentWorkspace(of: $0)) })
        let focusedOutput = focused.output
        var arrivals: [(out: Con, ws: Con)] = []
        for name in workspaceOutputs.keys.sorted(by: { key($0) < key($1) }) {
            guard let ws = workspace(named: name), let target = preferredOutput(for: name), ws.parent !== target else { continue }
            let returning = wasShowingOn[name] == target.name
            if returning { wasShowingOn[name] = nil }
            relocateWorkspace(ws, to: target, showing: showing.contains(ObjectIdentifier(ws)) || returning)
            arrivals.append((target, ws))
        }
        // An output that would be left showing an empty workspace shows a workspace that just arrived
        // on it instead (e.g. a display plugged in while its assigned workspace already has windows).
        for (out, ws) in arrivals where !ws.windows().isEmpty && currentWorkspace(of: out).windows().isEmpty {
            out.focusOrder.removeAll { $0 === ws }
            out.focusOrder.insert(ws, at: 0)
        }
        // If the focused workspace was pushed out of view (another workspace took its place on that
        // output), focus follows the output to what is showing there now. Must precede pruning, which
        // would otherwise delete an empty, hidden, focused workspace.
        let stillShowing = focused.isDescendant(of: root)
            && focused.workspace.map { ws in ws.output.map { currentWorkspace(of: $0) === ws } ?? false } ?? false
        if !stillShowing, let out = focusedOutput.flatMap({ o in root.children.first { $0 === o } }) ?? root.children.first {
            focus(descendFocused(currentWorkspace(of: out)))
        }
        pruneEmptyWorkspaces()
    }

    /// Put `ws` on `target`, showing it there if `showing`. The output it left is never left without a workspace.
    func relocateWorkspace(_ ws: Con, to target: Con, showing: Bool) {
        guard let src = ws.parent, src !== target else { return }
        ws.detach()
        insertWorkspace(ws, into: target)
        if src.children.isEmpty {
            let fresh = createWorkspace(lowestFreeWorkspaceName(for: src), on: src)
            src.focusOrder = [fresh]
        }
        if showing {
            target.focusOrder.removeAll { $0 === ws }
            target.focusOrder.insert(ws, at: 0)
        }
    }

    /// `move workspace to output ...`: the focused workspace moves to `out` and keeps the focus.
    public func moveActiveWorkspace(to out: Con) {
        let ws = activeWorkspace
        guard let src = ws.parent, src !== out else { return }
        relocateWorkspace(ws, to: out, showing: currentWorkspace(of: src) === ws)
        focus(descendFocused(ws))
        pruneEmptyWorkspaces()
    }
}
