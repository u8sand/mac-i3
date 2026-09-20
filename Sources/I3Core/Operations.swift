import Foundation

// i3 semantics for focus / move / split / layout / resize, ported from i3's src/tree.c,
// src/move.c and src/con.c behaviour.
extension Tree {

    // MARK: - focus

    public func focusDirection(_ dir: Direction) {
        if focused.isFloating { return }
        let o = dir.orientation
        var branch = focused
        var outermost: Con?
        while let p = branch.parent, p.isContainer {
            if p.layout.orientation == o {
                outermost = p
                if let i = p.children.firstIndex(where: { $0 === branch }) {
                    let j = dir.isForward ? i + 1 : i - 1
                    if p.children.indices.contains(j) {
                        focusSwitchingWorkspace(descendDirection(p.children[j], dir))
                        return
                    }
                }
            }
            branch = p
        }
        if let out = adjacentOutput(of: activeOutput, dir) {
            focusSwitchingWorkspace(descendFocused(currentWorkspace(of: out)))
            return
        }
        if focusWrapping, let p = outermost, p.children.count > 1 {
            focus(descendDirection(dir.isForward ? p.children.first! : p.children.last!, dir))
        }
    }

    public func focusParent() {
        guard let p = focused.parent, p.isContainer else { return }
        focus(p)
    }

    public func focusChild() {
        guard !focused.isWindow, let c = focused.focusOrder.first else { return }
        focused = c
    }

    public func focusModeToggle() {
        let ws = activeWorkspace
        if focused.isFloating {
            focus(descendTiling(ws))
        } else if let f = ws.focusOrder.first(where: { $0.isFloating }) {
            focus(f)
        }
    }

    func adjacentOutput(of out: Con, _ dir: Direction) -> Con? {
        let r = out.rect
        var best: (Con, Double)?
        for cand in root.children where cand !== out {
            let c = cand.rect
            let eps = 1.0
            let gap: Double
            let overlaps: Bool
            switch dir {
            case .right: gap = c.x - r.maxX; overlaps = c.y < r.maxY && c.maxY > r.y
            case .left: gap = r.x - c.maxX; overlaps = c.y < r.maxY && c.maxY > r.y
            case .down: gap = c.y - r.maxY; overlaps = c.x < r.maxX && c.maxX > r.x
            case .up: gap = r.y - c.maxY; overlaps = c.x < r.maxX && c.maxX > r.x
            }
            guard gap >= -eps, overlaps else { continue }
            if best == nil || gap < best!.1 { best = (cand, gap) }
        }
        return best?.0
    }

    /// `focus output left|right|up|down`
    public func focusOutput(_ dir: Direction) {
        if let out = adjacentOutput(of: activeOutput, dir) {
            focusSwitchingWorkspace(descendFocused(currentWorkspace(of: out)))
        }
    }

    // MARK: - split

    public func split(_ orientation: Orientation) {
        var con = focused
        if con.isFloating { return }
        if con.kind == .workspace {
            if con.children.count < 2 {
                con.layout = .split(orientation)
                con.lastSplit = con.layout
                return
            }
            con = encapsulate(con)
        }
        splitContainer(con, orientation)
    }

    /// Make `con` (a window or split container) the sole occupant of a new split container with the
    /// given orientation, or just reorient its parent when it is an only child (as i3's `split` does).
    func splitContainer(_ con: Con, _ orientation: Orientation) {
        guard let parent = con.parent else { return }
        if parent.children.count == 1 && !parent.layout.isTabLike {
            parent.layout = .split(orientation)
            parent.lastSplit = parent.layout
            return
        }
        let x = Con(.split)
        x.layout = .split(orientation)
        x.lastSplit = x.layout
        x.percent = con.percent
        let idx = con.indexInParent!
        let focusIdx = parent.focusOrder.firstIndex { $0 === con }!
        con.detach()
        parent.children.insert(x, at: idx)
        x.parent = parent
        parent.focusOrder.insert(x, at: min(focusIdx, parent.focusOrder.count))
        x.attach(con, focusFront: true)
        con.percent = 0
        x.fixPercent()
    }

    /// Wrap all tiling children of `ws` into one new split container that inherits ws's layout.
    @discardableResult
    func encapsulate(_ ws: Con) -> Con {
        let x = Con(.split)
        x.layout = ws.layout
        x.lastSplit = ws.lastSplit
        x.percent = 1.0
        let kids = ws.children
        let order = ws.focusOrder.filter { !$0.isFloating }
        let floats = ws.focusOrder.filter { $0.isFloating }
        ws.children = []
        ws.focusOrder = floats
        for k in kids { k.parent = x }
        x.children = kids
        x.focusOrder = order
        ws.children = [x]
        x.parent = ws
        ws.focusOrder.append(x)
        // preserve focus recency: put x where the most recent tiling child was
        if let f = order.first, let fi = ws.focusOrder.firstIndex(where: { $0 === x }), fi != 0, focused.isDescendant(of: f) {
            ws.focusOrder.remove(at: fi)
            ws.focusOrder.insert(x, at: 0)
        }
        return x
    }

    // MARK: - layout

    public enum LayoutRequest { case set(Layout), toggleSplit, toggleAll }

    public func setLayout(_ req: LayoutRequest) {
        let target: Con = focused.kind == .workspace ? focused : (focused.parent ?? focused)
        guard target.isContainer else { return }
        switch req {
        case .set(let l):
            if l.isTabLike { if !target.layout.isTabLike { target.lastSplit = target.layout } }
            else { target.lastSplit = l }
            target.layout = l
        case .toggleSplit:
            if target.layout.isTabLike {
                target.layout = target.lastSplit
            } else {
                target.layout = target.layout == .splitH ? .splitV : .splitH
                target.lastSplit = target.layout
            }
        case .toggleAll:
            let order: [Layout] = [.splitH, .splitV, .stacked, .tabbed]
            let i = order.firstIndex(of: target.layout) ?? 0
            let next = order[(i + 1) % order.count]
            if next.isTabLike && !target.layout.isTabLike { target.lastSplit = target.layout }
            target.layout = next
            if !next.isTabLike { target.lastSplit = next }
        }
    }

    // MARK: - fullscreen / floating

    public func toggleFullscreen() {
        guard focused.isWindow else { return }
        let ws = focused.workspace
        let now = !focused.fullscreen
        for w in ws?.windows() ?? [] { w.fullscreen = false }
        focused.fullscreen = now
    }

    public func toggleFloating() {
        let con = focused
        guard con.isWindow, let ws = con.workspace else { return }
        if con.isFloating {
            con.detach()
            con.isFloating = false
            insertTiled(con, in: ws)
            focus(con)
        } else {
            let parent = con.parent!
            let r = con.rect
            con.detach()
            cleanup(parent)
            con.isFloating = true
            con.fullscreen = false
            con.percent = 0
            if r.w > 0 {
                con.rect = Rect(r.x + r.w * 0.1, r.y + r.h * 0.1, r.w * 0.8, r.h * 0.8)
            } else {
                con.rect = defaultFloatingRect(in: ws)
            }
            ws.attach(con, focusFront: true)
            focus(con)
        }
    }

    public func floatingFrameChanged(_ id: WindowID, _ r: Rect) {
        if let c = find(id), c.isFloating { c.rect = r }
    }

    // MARK: - move

    public func move(_ dir: Direction, px: Double = 10) {
        let con = focused
        guard con.isWindow || con.kind == .split else { return }
        if con.isFloating {
            switch dir {
            case .left: con.rect.x -= px
            case .right: con.rect.x += px
            case .up: con.rect.y -= px
            case .down: con.rect.y += px
            }
            return
        }
        let o = dir.orientation
        var above = con
        var same: Con?
        while let p = above.parent, p.isContainer {
            if p.layout.orientation == o { same = p; break }
            above = p
        }
        guard let s = same else {
            // No ancestor lays out along this axis: turn the workspace around (i3 wraps the
            // existing content in a container and flips the workspace orientation).
            guard let ws = con.workspace else { return }
            if ws.children.count == 1 && ws.children[0] === con {
                moveAcrossOutput(con, dir)
                return
            }
            let x = encapsulate(ws)
            ws.layout = .split(o)
            ws.lastSplit = ws.layout
            relocate(con, near: x, after: dir.isForward)
            return
        }
        let i = above.indexInParent!
        if con !== above {
            // Nested in a perpendicular container: step out beside it.
            relocate(con, near: above, after: dir.isForward)
            return
        }
        let j = dir.isForward ? i + 1 : i - 1
        if s.children.indices.contains(j) {
            let neighbor = s.children[j]
            if neighbor.isWindow {
                s.children.swapAt(i, j)
                focus(con)
            } else {
                let target = descendDirection(neighbor, dir)
                if target.isWindow {
                    relocate(con, near: target, after: !dir.isForward)
                } else {
                    relocateInto(con, target)
                }
            }
            return
        }
        // Edge of `s`: leave it.
        if s.kind == .workspace {
            moveAcrossOutput(con, dir)
        } else {
            relocate(con, near: s, after: dir.isForward)
        }
    }

    /// Detach `con` and re-attach it next to `anchor` in anchor's parent. The new spot is filled before the
    /// old one is cleaned up, so a destination that only existed because of `con` is not deleted.
    func relocate(_ con: Con, near anchor: Con, after: Bool) {
        guard let dest = anchor.parent else { return }
        let oldParent = con.parent!
        con.detach()
        con.percent = 0
        let idx = (anchor.indexInParent ?? dest.children.count) + (after ? 1 : 0)
        dest.attach(con, at: idx)
        dest.fixPercent()
        cleanup(oldParent)
        focus(con)
    }

    /// Append `con` to container `dest` (used when descending into an empty/foreign container).
    func relocateInto(_ con: Con, _ dest: Con) {
        let oldParent = con.parent!
        con.detach()
        con.percent = 0
        dest.attach(con)
        dest.fixPercent()
        cleanup(oldParent)
        focus(con)
    }

    /// Move `con` to the neighbouring output in `dir` (if any), landing on its visible workspace.
    func moveAcrossOutput(_ con: Con, _ dir: Direction) {
        guard let out = adjacentOutput(of: activeOutput, dir) else { return }
        let ws = currentWorkspace(of: out)
        let oldParent = con.parent!
        con.detach()
        con.percent = 0
        cleanup(oldParent)
        if ws.children.isEmpty {
            ws.attach(con)
        } else {
            ws.attach(con, at: dir.isForward ? 0 : ws.children.count)
        }
        ws.fixPercent()
        focusSwitchingWorkspace(con)
    }

    // MARK: - move to workspace

    public func moveContainerToWorkspace(_ name: String, follow: Bool = false) {
        let con = focused
        guard con.isWindow || con.kind == .split, let from = con.workspace else { return }
        let target = workspace(named: name) ?? createWorkspace(name, on: activeOutput)
        if target === from { return }
        let oldParent = con.parent!
        con.detach()
        cleanup(oldParent)
        con.percent = 0
        if con.isFloating {
            target.attach(con)
        } else {
            let ref = descendTiling(target)
            if ref.isWindow {
                ref.parent!.attach(con, at: ref.indexInParent! + 1)
                ref.parent!.fixPercent()
            } else {
                ref.attach(con)
                ref.fixPercent()
            }
        }
        if follow {
            focus(con)
            noteWorkspaceChange(from: from)
        } else {
            focus(descendFocused(from))
            // keep the recency chain of the target untouched
        }
        pruneEmptyWorkspaces()
    }

    // MARK: - resize

    public enum ResizeUnit { case px, ppt }

    public func resize(grow: Bool, horizontal: Bool, amount: Double, unit: ResizeUnit) {
        let con = focused
        if con.isFloating {
            let d = grow ? amount : -amount
            if horizontal { con.rect.w = max(50, con.rect.w + d) } else { con.rect.h = max(50, con.rect.h + d) }
            return
        }
        let o: Orientation = horizontal ? .horizontal : .vertical
        var branch = con
        var container: Con?
        while let p = branch.parent, p.isContainer {
            if p.layout.orientation == o, !p.layout.isTabLike, p.children.count > 1 { container = p; break }
            branch = p
        }
        guard let p = container, let i = p.children.firstIndex(where: { $0 === branch }) else { return }
        let second = i + 1 < p.children.count ? p.children[i + 1] : p.children[i - 1]
        let size = horizontal ? p.rect.w : p.rect.h
        let ppt: Double
        switch unit {
        case .ppt: ppt = amount / 100
        case .px: ppt = size > 0 ? amount / size : 0
        }
        let delta = grow ? ppt : -ppt
        let a = branch.percent + delta
        let b = second.percent - delta
        guard a >= 0.05, b >= 0.05 else { return }
        branch.percent = a
        second.percent = b
    }
}
