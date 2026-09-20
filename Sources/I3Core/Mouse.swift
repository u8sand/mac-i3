// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import Foundation

/// Where on a window a dragged window was dropped.
public enum DropZone: String {
    case left, right, top, bottom, center

    /// Outer quarter of each edge selects that side; the middle of the window means "join its group".
    public static func at(x: Double, y: Double, in r: Rect) -> DropZone {
        let u = (x - r.x) / max(r.w, 1), v = (y - r.y) / max(r.h, 1)
        let nearest = [(DropZone.left, u), (.right, 1 - u), (.top, v), (.bottom, 1 - v)].min { $0.1 < $1.1 }!
        return nearest.1 > 0.25 ? .center : nearest.0
    }

    /// The part of the target window the dragged window would occupy (for the drop preview).
    public func preview(in r: Rect) -> Rect {
        switch self {
        case .left: return Rect(r.x, r.y, r.w / 2, r.h)
        case .right: return Rect(r.midX, r.y, r.w / 2, r.h)
        case .top: return Rect(r.x, r.y, r.w, r.h / 2)
        case .bottom: return Rect(r.x, r.midY, r.w, r.h / 2)
        case .center: return r
        }
    }
}

/// What a mouse press hit, relative to a window frame. Decides whether a drag moves or resizes it:
/// the *grab point* says what the user meant, whereas the size after the drag can lie (macOS clamps a
/// window that no longer fits when it is dropped on a smaller display).
public enum Grab {
    case interior   // title bar or content: dragging moves the window
    case border     // on or just outside an edge: dragging resizes it
    case outside

    public static func at(x: Double, y: Double, in f: Rect, inset: Double = 6, outset: Double = 8) -> Grab {
        let inner = Rect(f.x + inset, f.y + inset, f.w - 2 * inset, f.h - 2 * inset)
        if inner.w > 0, inner.h > 0, inner.contains(x: x, y: y) { return .interior }
        let outer = Rect(f.x - outset, f.y - outset, f.w + 2 * outset, f.h + 2 * outset)
        return outer.contains(x: x, y: y) ? .border : .outside
    }
}

/// How far each edge of a window moved outward during a resize drag (negative = inward).
public struct EdgeDeltas: Equatable {
    public var left = 0.0, right = 0.0, top = 0.0, bottom = 0.0

    public init(left: Double = 0, right: Double = 0, top: Double = 0, bottom: Double = 0) {
        self.left = left; self.right = right; self.top = top; self.bottom = bottom
    }

    /// A real edge drag moves one edge per axis. If both opposite edges moved a long way in the same
    /// direction the window was really *moved* (and possibly clamped by the OS), so that axis is dropped.
    public init(from a: Rect, to b: Rect, translationLimit: Double = 20) {
        left = a.x - b.x; right = b.maxX - a.maxX
        top = a.y - b.y; bottom = b.maxY - a.maxY
        if abs(left) > translationLimit && abs(right) > translationLimit && left * right < 0 { left = 0; right = 0 }
        if abs(top) > translationLimit && abs(bottom) > translationLimit && top * bottom < 0 { top = 0; bottom = 0 }
    }
}

// Mouse-driven changes: the host reports what the user did with the mouse, the tree applies i3 semantics.
extension Tree {

    /// The tiled window at a point, or nil over a floating window / empty space. Uses the layout as
    /// last computed, i.e. where windows are *supposed* to be, not where a dragged window currently is.
    public func windowAt(x: Double, y: Double, excluding: WindowID? = nil) -> (id: WindowID, rect: Rect)? {
        let res = computeLayout()
        for id in res.floating { if let f = res.frames[id], f.contains(x: x, y: y) { return nil } }
        for (id, f) in res.frames where id != excluding && !res.floating.contains(id) && f.contains(x: x, y: y) {
            return (id, f)
        }
        return nil
    }

    /// The output whose area contains a point.
    public func outputAt(x: Double, y: Double) -> Con? {
        root.children.first { $0.rect.contains(x: x, y: y) }
    }

    // MARK: - drag to resize

    /// The user dragged the edges of window `id` outward by these many pixels (negative = inward).
    /// Each moved edge shifts the boundary between the window (or the container holding it) and its
    /// neighbour on that side; edges on the outer border of the screen are ignored.
    public func resizeByEdges(_ id: WindowID, left: Double = 0, right: Double = 0, top: Double = 0, bottom: Double = 0,
                              threshold: Double = 6) {
        guard let con = find(id), !con.isFloating else { return }
        for (side, amount) in [(Direction.left, left), (.right, right), (.up, top), (.down, bottom)] where abs(amount) >= threshold {
            moveBoundary(of: con, side: side, outward: amount)
        }
    }

    func moveBoundary(of con: Con, side: Direction, outward: Double) {
        let o = side.orientation
        var branch = con
        while let p = branch.parent, p.isContainer {
            if p.layout.orientation == o, !p.layout.isTabLike, let i = p.children.firstIndex(where: { $0 === branch }) {
                let j = side.isForward ? i + 1 : i - 1
                if p.children.indices.contains(j) {
                    let size = o == .horizontal ? p.rect.w : p.rect.h
                    guard size > 0 else { return }
                    let neighbor = p.children[j]
                    let minShare = 0.05
                    var g = outward / size
                    g = min(g, neighbor.percent - minShare)
                    g = max(g, minShare - branch.percent)
                    branch.percent += g
                    neighbor.percent -= g
                    return
                }
            }
            branch = p
        }
    }

    // MARK: - drag to move

    /// Drop window `id` onto another tiled window. Dropping on an edge puts it beside the target on that
    /// side (splitting the target's slot if the layout runs the other way). Dropping in the middle adds it
    /// to the target's *group*: it is inserted right after the target inside the target's own container, so
    /// in a tabbed or stacked container it becomes a tab / row (and the active one). With `swapInstead` the
    /// middle exchanges the two windows' places instead.
    public func dropWindow(_ id: WindowID, onto targetID: WindowID, zone: DropZone, swapInstead: Bool = false) {
        guard id != targetID, let d = find(id), let t = find(targetID), !d.isFloating, !t.isFloating else { return }
        let before = activeWorkspace
        if zone == .center {
            if swapInstead { swap(d, t) } else { relocate(d, near: t, after: true) }
        } else {
            let o: Orientation = (zone == .left || zone == .right) ? .horizontal : .vertical
            if t.parent?.layout.orientation != o { splitContainer(t, o) }
            relocate(d, near: t, after: zone == .right || zone == .bottom)
        }
        noteWorkspaceChange(from: before)
        sanitizeFocus()
    }

    /// Where a window dropped at a point would go.
    public struct DropTarget: Equatable {
        public var id: WindowID
        public var zone: DropZone
        /// The area to highlight while dragging.
        public var preview: Rect
    }

    /// The drop target under a point: a tiled window (with the zone inside it) or the title bar of a
    /// tabbed / stacked container (which always means "join this group"). Nil over floating windows and
    /// empty space. `excluding` is the window being dragged.
    public func dropTarget(x: Double, y: Double, excluding: WindowID? = nil) -> DropTarget? {
        let res = computeLayout()
        for id in res.floating { if let f = res.frames[id], f.contains(x: x, y: y) { return nil } }
        for bar in res.bars where bar.rect.contains(x: x, y: y) {
            let candidates = bar.tabs.filter { $0.windowID != nil && $0.windowID != excluding }
            guard let tab = candidates.first(where: { $0.active }) ?? candidates.first, let id = tab.windowID else { return nil }
            return DropTarget(id: id, zone: .center, preview: bar.rect)
        }
        guard let hit = windowAt(x: x, y: y, excluding: excluding) else { return nil }
        let zone = DropZone.at(x: x, y: y, in: hit.rect)
        return DropTarget(id: hit.id, zone: zone, preview: zone.preview(in: hit.rect))
    }

    /// Drop window `id` on an output that has nothing under the cursor: it joins that output's visible workspace.
    public func dropWindow(_ id: WindowID, onOutput name: String) {
        guard let d = find(id), !d.isFloating, let out = root.children.first(where: { $0.name == name }) else { return }
        let ws = currentWorkspace(of: out)
        if d.workspace === ws { return }
        let before = activeWorkspace
        let old = d.parent!
        d.detach()
        d.percent = 0
        cleanup(old)
        let ref = descendTiling(ws)
        if ref.isWindow { ref.parent!.attach(d, at: ref.indexInParent! + 1); ref.parent!.fixPercent() }
        else { ref.attach(d); ref.fixPercent() }
        focus(d)
        noteWorkspaceChange(from: before)
        sanitizeFocus()
    }

    /// Exchange the places of two tiled windows, each keeping the size share of the slot it moves into.
    func swap(_ a: Con, _ b: Con) {
        guard let pa = a.parent, let pb = b.parent,
              let ia = pa.children.firstIndex(where: { $0 === a }), let ib = pb.children.firstIndex(where: { $0 === b }) else { return }
        let percentA = a.percent, percentB = b.percent
        if pa === pb {
            pa.children.swapAt(ia, ib)
        } else {
            let fa = pa.focusOrder.firstIndex { $0 === a }, fb = pb.focusOrder.firstIndex { $0 === b }
            pa.children[ia] = b
            pb.children[ib] = a
            a.parent = pb
            b.parent = pa
            if let fa { pa.focusOrder[fa] = b }
            if let fb { pb.focusOrder[fb] = a }
        }
        a.percent = percentB
        b.percent = percentA
        focus(a)
    }
}
