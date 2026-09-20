import AppKit
import I3Core

/// What the bar needs to know about a window beyond its id.
struct BarWindowInfo: Equatable {
    var title: String
    var pid: pid_t
}

/// One workspace cell as laid out in the bar (coordinates in the view, top-left origin).
struct BarCell {
    var rect: NSRect
    var workspace: String
    var showing: Bool
    var focused: Bool
    var icons: [NSImage]
    var extra: Int          // windows (apps) beyond the icons shown
    var numberOrigin: NSPoint
}

struct BarLayout {
    var cells: [BarCell] = []
    var dividers: [CGFloat] = []
    var mode: (text: String, rect: NSRect)?
    var width: CGFloat = 0
    /// 0 = icons everywhere ... 3 = numbers only; raised automatically when the bar would be too wide.
    var level = 0
}

/// A menu bar item that lists the workspaces (grouped by display), marks the one showing on each display
/// and the one with keyboard focus, and shows an icon per app. Click a workspace to switch to it; right-click
/// (or ctrl-click) for a menu of every window.
final class WorkspaceBarController: NSObject {
    var onSwitch: ((String) -> Void)?
    var onFocusWindow: ((WindowID) -> Void)?

    private var item: NSStatusItem?
    private var view: BarView?
    private(set) var summary = BarSummary()
    private var info: [WindowID: BarWindowInfo] = [:]
    private var iconMode = "all"
    private var iconCache: [pid_t: NSImage] = [:]
    private(set) var layout = BarLayout()

    // MARK: - Configuration & updates

    func configure(enabled: Bool, icons: String) {
        iconMode = icons
        if enabled { install(); relayout() } else { remove() }
    }

    func update(_ s: BarSummary, info i: [WindowID: BarWindowInfo]) {
        guard s != summary || i != info else { return }
        summary = s
        info = i
        relayout()
    }

    func remove() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        view = nil
    }

    private func install() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.autosaveName = "mac-i3-workspaces"       // macOS remembers where you Cmd-dragged it
        let v = BarView()
        v.controller = self
        v.autoresizingMask = [.width, .height]
        it.button?.addSubview(v)
        item = it
        view = v
    }

    // MARK: - Layout

    private static let height: CGFloat = 22
    private var budget: CGFloat { min(600, (NSScreen.screens.first?.frame.width ?? 1500) * 0.33) }

    private func icon(for pid: pid_t) -> NSImage? {
        if let c = iconCache[pid] { return c }
        guard let app = NSRunningApplication(processIdentifier: pid), let src = app.icon else { return nil }
        let size = NSSize(width: 15, height: 15)
        let img = NSImage(size: size, flipped: false) { r in src.draw(in: r); return true }
        iconCache[pid] = img
        return img
    }

    /// One icon per app, in window order.
    private func icons(for ws: BarWorkspace) -> [(NSImage, pid_t)] {
        var seen = Set<pid_t>()
        var out: [(NSImage, pid_t)] = []
        for id in ws.windows {
            guard let pid = info[id]?.pid, pid != 0, seen.insert(pid).inserted, let img = icon(for: pid) else { continue }
            out.append((img, pid))
        }
        return out
    }

    private func iconLimit(level: Int, showing: Bool) -> Int {
        switch level {
        case 0: return 3
        case 1: return showing ? 3 : 0
        case 2: return showing ? 2 : 0
        default: return 0
        }
    }

    private func makeLayout(level: Int) -> BarLayout {
        var l = BarLayout()
        l.level = level
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let small = NSFont.systemFont(ofSize: 10, weight: .medium)
        let h = WorkspaceBarController.height
        var x: CGFloat = 4
        let pad: CGFloat = 7
        for (i, out) in summary.outputs.enumerated() where !out.workspaces.isEmpty {
            if i > 0, !l.cells.isEmpty { x += 4; l.dividers.append(x); x += 6 }
            for ws in out.workspaces {
                let textW = (ws.name as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
                let all = icons(for: ws)
                let shown = Array(all.prefix(iconLimit(level: level, showing: ws.showing)))
                let extra = shown.isEmpty ? 0 : all.count - shown.count
                var w = pad + textW
                if !shown.isEmpty { w += 4 + CGFloat(shown.count) * 15 + CGFloat(shown.count - 1) * 2 }
                var extraW: CGFloat = 0
                if extra > 0 { extraW = ("+\(extra)" as NSString).size(withAttributes: [.font: small]).width + 3; w += extraW }
                w += pad
                let rect = NSRect(x: x, y: 0, width: w, height: h)
                l.cells.append(BarCell(rect: rect, workspace: ws.name, showing: ws.showing, focused: ws.focused,
                                       icons: shown.map { $0.0 }, extra: extra, numberOrigin: NSPoint(x: x + pad, y: 0)))
                x += w + 2
            }
        }
        if summary.mode != "default" {
            let text = summary.mode
            let w = (text as NSString).size(withAttributes: [.font: small]).width + 14
            x += 8
            l.mode = (text, NSRect(x: x, y: 0, width: w, height: 16))
            x += w
        }
        l.width = x + 4
        return l
    }

    private func relayout() {
        guard let view, let button = item?.button else { return }
        // Lowest level (most detail) that fits the budget; an explicit icons setting only raises the floor.
        let floor = iconMode == "none" ? 3 : (iconMode == "active" ? 1 : 0)
        var chosen = makeLayout(level: floor)
        var level = floor
        while chosen.width > budget, level < 3 {
            level += 1
            chosen = makeLayout(level: level)
        }
        layout = chosen
        item?.length = chosen.width
        view.frame = NSRect(x: 0, y: 0, width: chosen.width, height: max(button.bounds.height, WorkspaceBarController.height))
        view.layoutData = chosen
        view.needsDisplay = true
    }

    // MARK: - Actions

    func click(cell: BarCell) { onSwitch?(cell.workspace) }

    func menu() -> NSMenu {
        let menu = NSMenu()
        for out in summary.outputs where !out.workspaces.isEmpty {
            if summary.outputs.count > 1 {
                let header = NSMenuItem(title: "Display \(out.number)", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            }
            for ws in out.workspaces {
                let title = "Workspace \(ws.name)" + (ws.showing ? "  (showing)" : "")
                let head = NSMenuItem(title: title, action: #selector(pickWorkspace(_:)), keyEquivalent: "")
                head.target = self
                head.representedObject = ws.name
                head.state = ws.focused ? .on : .off
                menu.addItem(head)
                for id in ws.windows {
                    let w = info[id]
                    let name = (w?.title.isEmpty ?? true) ? "(untitled)" : w!.title
                    let it = NSMenuItem(title: name, action: #selector(pickWindow(_:)), keyEquivalent: "")
                    it.target = self
                    it.representedObject = NSNumber(value: id)
                    it.indentationLevel = 1
                    if let pid = w?.pid, let img = icon(for: pid) { it.image = img }
                    menu.addItem(it)
                }
            }
            menu.addItem(.separator())
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu
    }

    @objc private func pickWorkspace(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { onSwitch?(name) }
    }

    @objc private func pickWindow(_ sender: NSMenuItem) {
        if let n = sender.representedObject as? NSNumber { onFocusWindow?(WindowID(truncating: n)) }
    }

    // MARK: - Introspection (mac-i3 bar, tests)

    /// Screen frame of the item in AX coordinates (top-left origin), and whether it is actually on a display.
    func screenFrame() -> (rect: Rect, visible: Bool)? {
        guard let w = item?.button?.window else { return nil }
        let r = Displays.axRect(w.frame)
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(w.frame) }
        return (r, onScreen && w.occlusionState.contains(.visible))
    }

    func debugDictionary() -> [String: Any] {
        var d: [String: Any] = ["enabled": item != nil, "level": layout.level, "mode": summary.mode]
        d["outputs"] = summary.outputs.map { o -> [String: Any] in
            ["number": o.number, "name": o.name, "workspaces": o.workspaces.map {
                ["name": $0.name, "showing": $0.showing, "focused": $0.focused, "windows": $0.windows.count] as [String: Any] }]
        }
        if let f = screenFrame() {
            d["frame"] = ["x": f.rect.x, "y": f.rect.y, "w": f.rect.w, "h": f.rect.h]
            d["visible"] = f.visible
        }
        if let v = view, let win = v.window {
            d["cells"] = layout.cells.map { c -> [String: Any] in
                let r = Displays.axRect(win.convertToScreen(v.convert(c.rect, to: nil)))
                return ["workspace": c.workspace, "x": r.x, "y": r.y, "w": r.w, "h": r.h]
            }
        }
        return d
    }
}

/// The custom-drawn content of the status item.
private final class BarView: NSView {
    weak var controller: WorkspaceBarController?
    var layoutData = BarLayout()

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func cellRect(_ c: BarCell) -> NSRect {
        NSRect(x: c.rect.minX, y: (bounds.height - c.rect.height) / 2, width: c.rect.width, height: c.rect.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let small = NSFont.systemFont(ofSize: 10, weight: .medium)
        for x in layoutData.dividers {
            NSColor.labelColor.withAlphaComponent(0.35).setFill()
            NSRect(x: x, y: bounds.midY - 8, width: 1, height: 16).fill()
        }
        for c in layoutData.cells {
            let r = cellRect(c)
            var text = NSColor.labelColor.withAlphaComponent(0.75)
            if c.focused {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
                text = .white
            } else if c.showing {
                NSColor.labelColor.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
                text = .labelColor
            }
            let name = c.workspace as NSString
            let size = name.size(withAttributes: [.font: font])
            name.draw(at: NSPoint(x: r.minX + 7, y: r.midY - size.height / 2), withAttributes: [.font: font, .foregroundColor: text])
            var x = r.minX + 7 + size.width.rounded(.up) + 4
            for img in c.icons {
                img.draw(in: NSRect(x: x, y: r.midY - 7.5, width: 15, height: 15), from: .zero, operation: .sourceOver,
                         fraction: (c.showing || c.focused) ? 1 : 0.7, respectFlipped: true, hints: nil)
                x += 17
            }
            if c.extra > 0 {
                let t = "+\(c.extra)" as NSString
                let s = t.size(withAttributes: [.font: small])
                t.draw(at: NSPoint(x: x + 1, y: r.midY - s.height / 2), withAttributes: [.font: small, .foregroundColor: text])
            }
        }
        if let m = layoutData.mode {
            let r = NSRect(x: m.rect.minX, y: (bounds.height - m.rect.height) / 2, width: m.rect.width, height: m.rect.height)
            NSColor.systemOrange.setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            let t = m.text as NSString
            let s = t.size(withAttributes: [.font: small])
            t.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: [.font: small, .foregroundColor: NSColor.black])
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) == false else { return showMenu(event) }
        let p = convert(event.locationInWindow, from: nil)
        if let c = layoutData.cells.first(where: { cellRect($0).insetBy(dx: -1, dy: -4).contains(p) }) {
            controller?.click(cell: c)
        }
    }

    override func rightMouseDown(with event: NSEvent) { showMenu(event) }

    private func showMenu(_ event: NSEvent) {
        guard let menu = controller?.menu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
