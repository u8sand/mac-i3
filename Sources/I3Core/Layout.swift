import Foundation

/// One tab in a tabbed/stacked title bar.
public struct BarTab {
    public var title: String
    public var active: Bool
    public var focused: Bool
    /// A window to focus when the tab is clicked (the most recently focused one inside the tab).
    public var windowID: WindowID?
}

/// Title bar drawn by the host for a tabbed/stacked container.
public struct Bar {
    public var rect: Rect
    public var vertical: Bool          // stacked: one row per tab
    public var tabs: [BarTab]
    /// True if this container holds the global focus (drawn with the focused colour).
    public var focused: Bool
}

public struct LayoutResult {
    /// Frames for every window that should currently be visible.
    public var frames: [WindowID: Rect] = [:]
    /// Windows that must be hidden (other workspaces, inactive tabs).
    public var hidden: Set<WindowID> = []
    public var bars: [Bar] = []
    /// Back-to-front raise order for windows that must stack above tiled ones.
    public var floating: [WindowID] = []
    public var fullscreen: WindowID?
    public var focusedWindow: WindowID?
}

extension Tree {
    /// Compute frames for the whole tree. Also stores each container's rect for resize maths.
    public func computeLayout() -> LayoutResult {
        var res = LayoutResult()
        for out in root.children {
            let current = currentWorkspace(of: out)
            for ws in out.children {
                if ws === current {
                    let area = Rect(out.rect.x + outerGap, out.rect.y + outerGap,
                                    out.rect.w - 2 * outerGap, out.rect.h - 2 * outerGap)
                    ws.rect = area
                    let barStart = res.bars.count
                    layoutContainer(ws, area, &res, visible: true)
                    for f in ws.floating.reversed() {
                        guard let id = f.windowID else { continue }
                        res.frames[id] = f.rect
                        res.floating.append(id)
                    }
                    if let fs = ws.windows().first(where: { $0.fullscreen }), let id = fs.windowID {
                        res.frames[id] = out.rect
                        res.hidden.remove(id)   // shown even if it sits in an inactive tab
                        res.fullscreen = id
                        res.bars.removeSubrange(barStart...)  // bars hidden under fullscreen
                    }
                } else {
                    for w in ws.windows() { if let id = w.windowID { res.hidden.insert(id) } }
                }
            }
        }
        let leaf = descendFocused(focused)
        if leaf.isWindow { res.focusedWindow = leaf.windowID }
        return res
    }

    private func layoutContainer(_ c: Con, _ rect: Rect, _ res: inout LayoutResult, visible: Bool) {
        c.rect = rect
        let kids = c.children
        guard !kids.isEmpty else { return }
        switch c.layout {
        case .splitH, .splitV:
            let horizontal = c.layout == .splitH
            let total = horizontal ? rect.w : rect.h
            var acc = 0.0
            var start = horizontal ? rect.x : rect.y
            let gap = innerGap
            for (i, k) in kids.enumerated() {
                acc += k.percent
                let end = (horizontal ? rect.x : rect.y) + (i == kids.count - 1 ? total : (total * acc).rounded())
                let g1 = i == 0 ? 0 : gap / 2
                let g2 = i == kids.count - 1 ? 0 : gap / 2
                let a = start + g1
                let len = max(end - start - g1 - g2, 1)
                let r = horizontal ? Rect(a, rect.y, len, rect.h) : Rect(rect.x, a, rect.w, len)
                place(k, r, &res, visible: visible)
                start = end
            }
        case .tabbed, .stacked:
            let stacked = c.layout == .stacked
            let bh = tabBarHeight
            let barSize = stacked ? bh * Double(kids.count) : bh
            let active = focusedChild(c)
            let barRect = stacked ? Rect(rect.x, rect.y, rect.w, barSize) : Rect(rect.x, rect.y, rect.w, bh)
            let inner = Rect(rect.x, rect.y + barSize, rect.w, max(rect.h - barSize, 1))
            if visible {
                let hasFocus = focused === c || focused.isDescendant(of: c)
                res.bars.append(Bar(rect: barRect, vertical: stacked,
                                    tabs: kids.map { BarTab(title: describe($0), active: $0 === active, focused: hasFocus && $0 === active, windowID: descendTiling($0).windowID) },
                                    focused: hasFocus))
            }
            for k in kids { place(k, inner, &res, visible: visible && k === active) }
        }
    }

    private func place(_ k: Con, _ r: Rect, _ res: inout LayoutResult, visible: Bool) {
        if k.isWindow {
            k.rect = r
            guard let id = k.windowID else { return }
            if visible { res.frames[id] = r } else { res.hidden.insert(id) }
        } else {
            layoutContainer(k, r, &res, visible: visible)
        }
    }

    /// Tab title for a child: a window's title, or a short summary for nested containers.
    func describe(_ c: Con) -> String {
        if c.isWindow { return c.title }
        let names = c.windows().filter { !$0.isFloating }.map { $0.title }
        let tag: String
        switch c.layout {
        case .splitH: tag = "H"
        case .splitV: tag = "V"
        case .stacked: tag = "S"
        case .tabbed: tag = "T"
        }
        return "\(tag)[\(names.joined(separator: " "))]"
    }
}
