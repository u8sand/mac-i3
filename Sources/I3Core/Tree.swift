import Foundation

/// Side effects the core cannot perform itself; returned by `Tree.run`.
public enum Action: Equatable {
    case exec(String)
    case kill(WindowID)
    case mode(String)
    case reload
    case restart
    case exit
}

/// The i3 container tree plus focus state. Pure logic: no AppKit, no Accessibility.
public final class Tree {
    public let root = Con(.root)
    public internal(set) var focused: Con
    /// i3 `focus_wrapping yes`: wrap at the outermost container edge when nothing lies beyond.
    public var focusWrapping = true
    public var tabBarHeight = 22.0
    /// Pixels between tiled windows (`gaps inner`) and around the outputs (`gaps outer`).
    public var innerGap = 0.0
    public var outerGap = 0.0
    public private(set) var previousWorkspaceName: String?
    /// `workspace <name> output <spec>...` from the config: where each workspace should live.
    public internal(set) var workspaceOutputs: [String: [String]] = [:]
    /// Name of the primary output (the one with the menu bar), for the `primary` output spec.
    public var primaryOutputName: String?
    /// Workspace name -> output that was showing it when that output disappeared (so it shows again on return).
    var wasShowingOn: [String: String] = [:]

    public init(outputs: [(name: String, rect: Rect)] = [("main", Rect(0, 0, 1920, 1080))]) {
        let placeholder = Con(.workspace)
        focused = placeholder
        for o in outputs { _ = addOutput(name: o.name, rect: o.rect) }
        if let ws = root.children.first?.focusOrder.first { focus(ws) }
    }

    // MARK: - Lookup

    public var outputs: [Con] { root.children }
    public var activeOutput: Con { focused.output ?? root.children[0] }
    public var activeWorkspace: Con { focused.workspace ?? currentWorkspace(of: activeOutput) }

    public func currentWorkspace(of output: Con) -> Con { output.focusOrder.first ?? output.children[0] }

    public func find(_ id: WindowID) -> Con? {
        for o in root.children { for ws in o.children { if let c = ws.windows().first(where: { $0.windowID == id }) { return c } } }
        return nil
    }

    public var allWindowIDs: [WindowID] {
        root.children.flatMap { $0.children.flatMap { $0.windows().compactMap { $0.windowID } } }
    }

    public var focusedWindowID: WindowID? { focused.isWindow ? focused.windowID : nil }

    public func workspace(named name: String) -> Con? {
        for o in root.children { if let ws = o.children.first(where: { $0.name == name }) { return ws } }
        return nil
    }

    // MARK: - Focus

    /// Focus `con`: it (and every ancestor) becomes most-recently-focused in its parent.
    public func focus(_ con: Con) {
        focused = con
        var c = con
        while let p = c.parent {
            p.focusOrder.removeAll { $0 === c }
            p.focusOrder.insert(c, at: 0)
            c = p
        }
    }

    /// Follow focus lists down to a leaf (or an empty container).
    public func descendFocused(_ con: Con) -> Con {
        var c = con
        while !c.isWindow, let next = c.focusOrder.first { c = next }
        return c
    }

    /// Most recently focused tiling child (falls back to first child).
    func focusedChild(_ c: Con) -> Con? {
        c.focusOrder.first { !$0.isFloating } ?? c.children.first
    }

    /// Focus-descend restricted to tiling windows.
    func descendTiling(_ con: Con) -> Con {
        var c = con
        while !c.isWindow, let next = focusedChild(c) { c = next }
        return c
    }

    /// Descend into `con` preferring the edge nearest to where we came from.
    func descendDirection(_ con: Con, _ dir: Direction) -> Con {
        var c = con
        while !c.isWindow, !c.children.isEmpty {
            if !c.layout.isTabLike && c.layout.orientation == dir.orientation {
                c = dir.isForward ? c.children.first! : c.children.last!
            } else {
                c = focusedChild(c)!
            }
        }
        return c
    }

    /// The OS reports that window `id` took focus.
    public func focusWindow(_ id: WindowID) {
        guard let c = find(id), focused !== c else { return }
        focusSwitchingWorkspace(c)
    }

    func focusSwitchingWorkspace(_ c: Con) {
        let before = activeWorkspace
        focus(c)
        noteWorkspaceChange(from: before)
    }

    func noteWorkspaceChange(from before: Con) {
        if activeWorkspace !== before {
            previousWorkspaceName = before.name
            pruneEmptyWorkspaces()
        }
    }

    // MARK: - Outputs & workspaces

    @discardableResult
    public func addOutput(name: String, rect: Rect) -> Con {
        let out = Con(.output)
        out.name = name
        out.rect = rect
        root.attach(out)
        let ws = createWorkspace(lowestFreeWorkspaceName(for: out), on: out)
        out.focusOrder = [ws]
        return out
    }

    /// Reconcile with the display configuration: update rects, add new outputs, fold removed
    /// outputs' workspaces into the first remaining output.
    public func updateOutputs(_ new: [(name: String, rect: Rect)], labels: [String: String]? = nil, primary: String? = nil) {
        guard !new.isEmpty else { return }
        for n in new {
            if let o = root.children.first(where: { $0.name == n.name }) { o.rect = n.rect } else { addOutput(name: n.name, rect: n.rect) }
        }
        if let labels { setOutputLabels(labels, primary: primary) }
        let names = Set(new.map { $0.name })
        for out in root.children where !names.contains(out.name) {
            guard let dest = root.children.first(where: { names.contains($0.name) }) else { continue }
            let hadFocus = focused.isDescendant(of: out)
            wasShowingOn[currentWorkspace(of: out).name] = out.name
            for ws in out.children {
                ws.detach()
                if ws.children.isEmpty && ws.floating.isEmpty {
                    continue
                }
                if let clash = dest.children.first(where: { $0.name == ws.name }) {
                    for w in ws.windows() { w.detach(); clash.attach(w) }
                    clash.fixPercent()
                } else {
                    insertWorkspace(ws, into: dest)
                }
            }
            out.detach()
            if hadFocus { focus(descendFocused(currentWorkspace(of: dest))) }
        }
        // A workspace whose assigned output just (re)appeared goes back to it.
        enforceWorkspaceOutputs()
    }

    /// Lowest unused workspace number, skipping numbers assigned to a different output than `out`.
    func lowestFreeWorkspaceName(for out: Con? = nil) -> String {
        var n = 1
        while true {
            let name = String(n)
            if workspace(named: name) == nil {
                if let out, let pref = preferredOutput(for: name), pref !== out { n += 1; continue }
                return name
            }
            n += 1
        }
    }

    @discardableResult
    func createWorkspace(_ name: String, on out: Con) -> Con {
        let ws = Con(.workspace)
        ws.name = name
        ws.layout = .splitH
        insertWorkspace(ws, into: out)
        return ws
    }

    func insertWorkspace(_ ws: Con, into out: Con) {
        func key(_ c: Con) -> (Int, String) { (Int(c.name) ?? Int.max, c.name) }
        var idx = out.children.count
        for (i, c) in out.children.enumerated() where key(c) > key(ws) { idx = i; break }
        out.attach(ws, at: idx)
    }

    /// Remove empty workspaces that are not visible on any output.
    func pruneEmptyWorkspaces() {
        for out in root.children {
            let current = currentWorkspace(of: out)
            for ws in out.children where ws !== current && ws.children.isEmpty && ws.floating.isEmpty {
                ws.detach()
            }
        }
    }

    public func switchWorkspace(_ name: String) {
        let before = activeWorkspace
        if before.name == name { return }
        let ws = workspace(named: name) ?? createWorkspace(name, on: preferredOutput(for: name) ?? activeOutput)
        focus(descendFocused(ws))
        noteWorkspaceChange(from: before)
    }

    // MARK: - Windows

    /// A new OS window appeared. Tiled windows open next to the focused container, like i3.
    @discardableResult
    public func addWindow(_ id: WindowID, title: String = "", floating: Bool = false, rect: Rect? = nil) -> Con {
        if let existing = find(id) { existing.title = title; return existing }
        let ws = activeWorkspace
        let con = Con(.window)
        con.windowID = id
        con.title = title
        if floating {
            con.isFloating = true
            con.rect = rect ?? defaultFloatingRect(in: ws)
            ws.attach(con, focusFront: true)
            focus(con)
        } else {
            insertTiled(con, in: ws)
            focus(con)
        }
        return con
    }

    func defaultFloatingRect(in ws: Con) -> Rect {
        let r = (ws.parent ?? activeOutput).rect
        return Rect(r.x + r.w * 0.15, r.y + r.h * 0.15, r.w * 0.7, r.h * 0.7)
    }

    /// Insert a detached window after the focused tiling container of `ws`.
    func insertTiled(_ con: Con, in ws: Con) {
        let ref: Con = (focused.workspace === ws && !focused.isFloating) ? focused : descendTiling(ws)
        // i3 opens the new container right after the focused one, even when that is a whole split
        // container (`focus parent`); only an empty workspace is filled directly.
        let parent: Con
        let index: Int
        if ref.kind == .workspace {
            parent = ref
            index = ref.children.count
        } else {
            parent = ref.parent!
            index = ref.indexInParent! + 1
        }
        con.percent = 0
        parent.attach(con, at: index)
        parent.fixPercent()
    }

    public func removeWindow(_ id: WindowID) {
        guard let con = find(id) else { return }
        let ws = con.workspace!
        let hadFocus = focused === con || focused.isDescendant(of: con)
        let parent = con.parent!
        con.detach()
        cleanup(parent)
        if hadFocus {
            focus(descendFocused(ws))
        }
        sanitizeFocus()
        if focused.workspace !== ws { pruneEmptyWorkspaces() }
    }

    /// Focus must always point at a node that is still in the tree (a focused container can vanish
    /// when its last window closes). Fall back to the visible workspace of the first output.
    func sanitizeFocus() {
        if focused.isDescendant(of: root) && focused.kind != .output && focused.kind != .root { return }
        guard let out = root.children.first else { return }
        focus(descendFocused(currentWorkspace(of: out)))
    }

    public func setTitle(_ id: WindowID, _ title: String) { find(id)?.title = title }

    /// Remove empty split containers and flatten pointless nesting after `start` lost a child.
    func cleanup(_ start: Con) {
        var p: Con? = start
        while let c = p, c.kind == .split {
            let up = c.parent
            if c.children.isEmpty && c.floating.isEmpty {
                c.detach()
                p = up
                continue
            }
            break
        }
        guard let survivor = p else { return }
        survivor.fixPercent()
        flatten(survivor)
    }

    /// A split container whose only child is another split container is pointless (i3 tree_flatten).
    func flatten(_ c: Con) {
        guard c.kind == .split, c.children.count == 1, c.floating.isEmpty,
              let child = c.children.first, child.kind == .split, let parent = c.parent,
              let idx = c.indexInParent else { return }
        let wasFocused = focused === c
        child.percent = c.percent
        let cOrderIndex = parent.focusOrder.firstIndex { $0 === c }
        c.detach()
        child.detach()
        parent.children.insert(child, at: idx)
        child.parent = parent
        parent.focusOrder.insert(child, at: cOrderIndex ?? 0)
        if wasFocused { focused = child }
        flatten(parent)
    }
}
