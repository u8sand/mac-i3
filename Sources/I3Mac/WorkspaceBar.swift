import AppKit
import I3Core

/// What the bar needs to know about a window beyond its id.
struct BarWindowInfo: Equatable {
    var title: String
    var pid: pid_t
    var appName: String
}

/// One drawn piece of a workspace's container tree: `h[icon icon]`.
enum BarToken {
    case letter(String)                         // h v t s f: the container's layout, drawn before its bracket
    case open                                   // [
    case close                                  // ]
    case icon(NSImage?, focused: Bool)          // the window's app icon (nil: a dot)
}

/// How much a workspace cell shows.
enum CellDetail: Equatable {
    case tree               // the container tree with layout letters, brackets and one icon per window
    case flat(Int)          // up to N app icons (one per app), no structure
    case none               // just the number
}

enum CellContent {
    case none
    case flat([NSImage], extra: Int)
    case tree([BarToken])
}

/// One workspace cell as laid out in the bar (coordinates in the view, top-left origin).
struct BarCell {
    var rect: NSRect
    var workspace: String
    var showing: Bool
    var focused: Bool
    var content: CellContent
}

struct BarLayout {
    var cells: [BarCell] = []
    var dividers: [CGFloat] = []
    var mode: (text: String, rect: NSRect)?
    var width: CGFloat = 0
    /// Position in the fallback chain (0 = most detail); raised automatically when the bar would be too wide.
    var level = 0
    var detail = ""
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
    private var layoutMode = "tree"
    private var iconCache: [pid_t: NSImage] = [:]
    private(set) var layout = BarLayout()

    // MARK: - Configuration & updates

    func configure(enabled: Bool, icons: String, layout: String) {
        iconMode = icons
        layoutMode = layout
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

    fileprivate static let bracketFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    fileprivate static let letterFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)

    /// Width of a token by itself, and the gap that follows it, which depends on what comes next so that
    /// `]]` stays tight while `] t[` and `icon icon` get a little air.
    fileprivate static func baseWidth(_ t: BarToken) -> CGFloat {
        switch t {
        case .letter(let l): return (l as NSString).size(withAttributes: [.font: letterFont]).width
        case .open: return ("[" as NSString).size(withAttributes: [.font: bracketFont]).width
        case .close: return ("]" as NSString).size(withAttributes: [.font: bracketFont]).width
        case .icon: return 15
        }
    }

    fileprivate static func gap(after i: Int, in toks: [BarToken]) -> CGFloat {
        guard i + 1 < toks.count else { return 0 }
        let next = toks[i + 1]
        switch toks[i] {
        case .letter: return 0
        case .open: return 1
        case .icon: return (next.isIcon || next.isLetter) ? 2 : 0       // before another icon or a nested container
        case .close: return next.isClose ? 0 : 3                          // ]] tight, but "] t[" separated
        }
    }

    fileprivate static func treeWidth(_ toks: [BarToken]) -> CGFloat {
        toks.indices.reduce(0) { $0 + baseWidth(toks[$1]) + gap(after: $1, in: toks) }
    }

    /// The workspace as tokens, or nil when it has too many windows to be worth drawing as a tree.
    private func tokens(for ws: BarWorkspace) -> [BarToken]? {
        guard ws.windows.count <= 8 else { return nil }
        var out: [BarToken] = []
        func walk(_ n: BarNode) {
            switch n {
            case .window(let id, let focused):
                let img = info[id].flatMap { $0.pid != 0 ? icon(for: $0.pid) : nil }
                out.append(.icon(img, focused: focused))
            case .container(let letter, let kids):
                out += [.letter(String(letter)), .open]
                kids.forEach(walk)
                out.append(.close)
            }
        }
        // The workspace's own container is drawn like any other, except that plain horizontal stays implicit.
        (ws.layout == "h" ? ws.nodes : [BarNode.container(ws.layout, ws.nodes)]).forEach(walk)
        if !ws.floating.isEmpty { walk(.container("f", ws.floating.map { .window($0, focused: false) })) }
        return out
    }

    /// Fallback chain, most detail first: each step gives (inactive workspaces, showing workspaces).
    private func chain() -> [(inactive: CellDetail, showing: CellDetail)] {
        var c: [(inactive: CellDetail, showing: CellDetail)] = layoutMode == "flat"
            ? [(.flat(3), .flat(3)), (.none, .flat(3)), (.none, .flat(2)), (.none, .none)]
            : [(.tree, .tree), (.flat(3), .tree), (.none, .tree), (.none, .flat(3)), (.none, .flat(2)), (.none, .none)]
        switch iconMode {
        case "none": c = [c[c.count - 1]]
        case "active": c = c.filter { $0.inactive == .none }
        default: break
        }
        return c
    }

    private func describe(_ d: CellDetail) -> String {
        switch d { case .tree: return "tree"; case .flat(let n): return "icons(\(n))"; case .none: return "number" }
    }

    private func makeLayout(step: (inactive: CellDetail, showing: CellDetail), level: Int) -> BarLayout {
        var l = BarLayout()
        l.level = level
        l.detail = "inactive: \(describe(step.inactive)), showing: \(describe(step.showing))"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let small = NSFont.systemFont(ofSize: 10, weight: .medium)
        let h = WorkspaceBarController.height
        var x: CGFloat = 4
        let pad: CGFloat = 7
        for (i, out) in summary.outputs.enumerated() where !out.workspaces.isEmpty {
            if i > 0, !l.cells.isEmpty { x += 4; l.dividers.append(x); x += 6 }
            for ws in out.workspaces {
                let textW = (ws.name as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
                var w = pad + textW
                var content = CellContent.none
                var detail = (ws.showing || ws.focused) ? step.showing : step.inactive
                if case .tree = detail, ws.windows.isEmpty { detail = .none }
                if case .tree = detail {
                    if let toks = tokens(for: ws) {
                        content = .tree(toks)
                        w += 5 + WorkspaceBarController.treeWidth(toks)
                    } else {
                        detail = .flat(3)          // too many windows for a tree: icons only
                    }
                }
                if case .flat(let limit) = detail {
                    let all = icons(for: ws)
                    let shown = Array(all.prefix(limit))
                    if !shown.isEmpty {
                        let extra = all.count - shown.count
                        content = .flat(shown.map { $0.0 }, extra: extra)
                        w += 4 + CGFloat(shown.count) * 15 + CGFloat(shown.count - 1) * 2
                        if extra > 0 { w += ("+\(extra)" as NSString).size(withAttributes: [.font: small]).width + 3 }
                    }
                }
                w += pad
                l.cells.append(BarCell(rect: NSRect(x: x, y: 0, width: w, height: h), workspace: ws.name,
                                       showing: ws.showing, focused: ws.focused, content: content))
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

    /// The most detailed step of the fallback chain that fits the budget (the last one if none does).
    private func computeLayout() -> BarLayout {
        let steps = chain()
        var chosen = makeLayout(step: steps[0], level: 0)
        for (i, step) in steps.enumerated().dropFirst() where chosen.width > budget {
            chosen = makeLayout(step: step, level: i)
        }
        return chosen
    }

    private func relayout() {
        guard let view, let button = item?.button else { return }
        let chosen = computeLayout()
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

    // MARK: - Offscreen preview (mac-i3 bar-preview)

    /// Renders the bar for a summary into an image without a status item, using the real layout and drawing code.
    static func render(_ summary: BarSummary, info: [WindowID: BarWindowInfo], dark: Bool, layout: String = "tree") -> (rep: NSBitmapImageRep, detail: String, width: CGFloat)? {
        let c = WorkspaceBarController()
        c.summary = summary
        c.info = info
        c.layoutMode = layout
        let lay = c.computeLayout()
        let v = BarView()
        v.controller = c
        v.layoutData = lay
        v.backdrop = NSColor(white: dark ? 0.16 : 0.90, alpha: 1)
        v.frame = NSRect(x: 0, y: 0, width: lay.width, height: 30)
        v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let scale = 3
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(lay.width) * scale, pixelsHigh: 30 * scale,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = v.bounds.size
        v.cacheDisplay(in: v.bounds, to: rep)
        return (rep, lay.detail, lay.width)
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
        var d: [String: Any] = ["enabled": item != nil, "level": layout.level, "detail": layout.detail, "mode": summary.mode]
        d["outputs"] = summary.outputs.map { o -> [String: Any] in
            ["number": o.number, "name": o.name, "workspaces": o.workspaces.map {
                ["name": $0.name, "showing": $0.showing, "focused": $0.focused, "windows": $0.windows.count,
                 "notation": $0.notation { [info] id in info[id]?.appName ?? "?" }] as [String: Any] }]
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
    /// Only for offscreen previews: the menu bar colour to draw on.
    var backdrop: NSColor?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func cellRect(_ c: BarCell) -> NSRect {
        NSRect(x: c.rect.minX, y: (bounds.height - c.rect.height) / 2, width: c.rect.width, height: c.rect.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let backdrop { backdrop.setFill(); bounds.fill() }
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
            let dim = text.withAlphaComponent(0.6)
            let active = (c.showing || c.focused) ? 1.0 : 0.7
            switch c.content {
            case .none:
                break
            case .flat(let icons, let extra):
                for img in icons {
                    img.draw(in: NSRect(x: x, y: r.midY - 7.5, width: 15, height: 15), from: .zero, operation: .sourceOver,
                             fraction: active, respectFlipped: true, hints: nil)
                    x += 17
                }
                if extra > 0 {
                    let t = "+\(extra)" as NSString
                    let s = t.size(withAttributes: [.font: small])
                    t.draw(at: NSPoint(x: x + 1, y: r.midY - s.height / 2), withAttributes: [.font: small, .foregroundColor: text])
                }
            case .tree(let tokens):
                x += 1
                for (i, t) in tokens.enumerated() {
                    switch t {
                    case .letter(let l):
                        let sz = (l as NSString).size(withAttributes: [.font: WorkspaceBarController.letterFont])
                        (l as NSString).draw(at: NSPoint(x: x, y: r.midY - sz.height / 2), withAttributes: [.font: WorkspaceBarController.letterFont, .foregroundColor: text])
                    case .open, .close:
                        let g = (t.isClose ? "]" : "[") as NSString
                        let sz = g.size(withAttributes: [.font: WorkspaceBarController.bracketFont])
                        g.draw(at: NSPoint(x: x, y: r.midY - sz.height / 2), withAttributes: [.font: WorkspaceBarController.bracketFont, .foregroundColor: dim])
                    case .icon(let img, let focused):
                        let box = NSRect(x: x, y: r.midY - 7.5, width: 15, height: 15)
                        if let img {
                            img.draw(in: box, from: .zero, operation: .sourceOver, fraction: active, respectFlipped: true, hints: nil)
                        } else {
                            text.setFill()
                            NSBezierPath(ovalIn: box.insetBy(dx: 5.5, dy: 5.5)).fill()
                        }
                        if focused {                       // the window that has keyboard focus
                            text.setFill()
                            NSRect(x: box.minX, y: box.maxY + 1, width: box.width, height: 2).fill()
                        }
                    }
                    x += WorkspaceBarController.baseWidth(t) + WorkspaceBarController.gap(after: i, in: tokens)
                }
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

private extension BarToken {
    var isClose: Bool { if case .close = self { return true } else { return false } }
    var isIcon: Bool { if case .icon = self { return true } else { return false } }
    var isLetter: Bool { if case .letter = self { return true } else { return false } }
}
