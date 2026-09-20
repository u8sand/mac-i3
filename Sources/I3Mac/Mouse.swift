import AppKit
import CoreGraphics
import I3Core

/// One left-button press-drag-release, tracked from the mouse-down snapshot of every tiled window.
struct Gesture {
    var start: (x: Double, y: Double)
    /// Where each tiled, visible window was when the button went down.
    var baseline: [WindowID: Rect]
    /// The window pressed in its interior (title bar / content): the drag moves it.
    var interior: WindowID?
    /// Windows pressed on their border: the drag resizes one of them.
    var borders: [WindowID]
    var dragged = false
    var lastProbe = Date.distantPast
}

/// Has the window's origin moved far enough to count as dragged (size is deliberately ignored)?
func displaced(_ a: Rect, _ b: Rect) -> Bool { hypot(b.x - a.x, b.y - a.y) > 12 }

extension WindowManager {
    /// Cursor position in AX coordinates (top-left origin).
    static func cursor() -> (x: Double, y: Double) {
        let p = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        return (Double(p.x), Double(h) - Double(p.y))
    }

    func installMouseMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            guard let self, self.config.mouseGestures else { return }
            switch e.type {
            case .leftMouseDown: self.mouseDown()
            case .leftMouseDragged: self.mouseDragged()
            case .leftMouseUp: self.mouseUp()
            default: break
            }
        }
    }

    // MARK: - Events

    func mouseDown() {
        lastMouseActivity = Date()
        let c = WindowManager.cursor()
        var base: [WindowID: Rect] = [:]
        var interior: WindowID?
        var borders: [WindowID] = []
        for (id, want) in applied where !parked.contains(id) {
            guard let con = tree.find(id), !con.isFloating, let w = wins[id], var f = AX.frame(w.element) else { continue }
            // This handler can run late (the main thread may have been busy talking to apps); if the
            // window already left its slot, trust where the layout put it.
            if displaced(want, f) { f = want }
            base[id] = f
            switch Grab.at(x: c.x, y: c.y, in: f) {
            case .interior: interior = id
            case .border: borders.append(id)
            case .outside: break
            }
        }
        gesture = Gesture(start: c, baseline: base, interior: interior, borders: borders)
        // Adopt the click as the focused window right away instead of waiting for the next poll.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in self?.reconcile() }
    }

    func mouseDragged() {
        lastMouseActivity = Date()
        guard var g = gesture else { return }
        let c = WindowManager.cursor()
        if !g.dragged && hypot(c.x - g.start.x, c.y - g.start.y) > 4 { g.dragged = true }
        var preview: Rect?
        if g.dragged, Date().timeIntervalSince(g.lastProbe) > 0.03, let id = g.interior,
           let base = g.baseline[id], let w = wins[id], let now = AX.frame(w.element) {
            g.lastProbe = Date()
            if displaced(base, now) { preview = dropPreview(dragging: id, at: c) }
            if preview == nil { overlay?.hidePreview() } else { overlay?.showPreview(preview!) }
        }
        gesture = g
    }

    func mouseUp() {
        lastMouseActivity = Date()
        overlay?.hidePreview()
        guard let g = gesture else { return }
        gesture = nil
        guard g.dragged else { return }
        let end = WindowManager.cursor()
        // Give the app a moment to finish its last frame update before reading it back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.finish(g, end: end) }
    }

    // MARK: - Interpreting a finished drag

    func finish(_ g: Gesture, end: (x: Double, y: Double)) {
        lastMouseActivity = Date()
        var touched: [WindowID] = []
        if let id = g.interior {
            // Pressed inside a window: a move. The size afterwards is ignored on purpose.
            if let before = g.baseline[id], let w = wins[id], let after = AX.frame(w.element), displaced(before, after) {
                log("mouse: move \(id) to \(Int(end.x)),\(Int(end.y))")
                drop(id, at: end)
                touched.append(id)
            }
        } else {
            // Pressed on a border: a resize of whichever neighbour actually changed size.
            for id in g.borders {
                guard let before = g.baseline[id], let w = wins[id], let after = AX.frame(w.element) else { continue }
                let d = EdgeDeltas(from: before, to: after)
                guard abs(after.w - before.w) > 8 || abs(after.h - before.h) > 8 else { continue }
                log("mouse: resize \(id) l\(Int(d.left)) r\(Int(d.right)) t\(Int(d.top)) b\(Int(d.bottom))")
                tree.resizeByEdges(id, left: d.left, right: d.right, top: d.top, bottom: d.bottom)
                touched.append(id)
            }
        }
        // Whatever happened, snap the displaced windows to where the tree says they belong.
        for id in touched { applied[id] = nil; retries[id] = 0 }
        if let id = g.interior, !touched.contains(id) { applied[id] = nil; retries[id] = 0 }
        applyLayout()
    }

    /// Where a window dropped at `p` would go: the window under the cursor and the zone within it, or an
    /// empty output. Returns nil when nothing would change.
    private func dropTarget(dragging id: WindowID, at p: (x: Double, y: Double)) -> (rect: Rect, action: () -> Void)? {
        if let hit = tree.windowAt(x: p.x, y: p.y, excluding: id) {
            let zone = DropZone.at(x: p.x, y: p.y, in: hit.rect)
            return (zone.preview(in: hit.rect), { [tree] in tree.dropWindow(id, onto: hit.id, zone: zone) })
        }
        if let out = tree.outputAt(x: p.x, y: p.y), out !== tree.find(id)?.output {
            return (out.rect, { [tree] in tree.dropWindow(id, onOutput: out.name) })
        }
        return nil
    }

    func drop(_ id: WindowID, at p: (x: Double, y: Double)) { dropTarget(dragging: id, at: p)?.action() }

    func dropPreview(dragging id: WindowID, at p: (x: Double, y: Double)) -> Rect? { dropTarget(dragging: id, at: p)?.rect }
}

/// Posts synthetic mouse events (used by `mac-i3 mouse` and the integration tests).
public enum MouseInjector {
    /// Owner name of the topmost on-screen window under a point (front-to-back order from the window server).
    public static func topWindowOwner(x: Double, y: Double) -> String? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        // Click-through highlight overlays (JankyBorders) sit above windows without receiving clicks.
        let clickThrough: Set<String> = ["borders"]
        for w in info {
            if clickThrough.contains(w[kCGWindowOwnerName as String] as? String ?? "") { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: Double],
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  x >= b["X"] ?? 0, x < (b["X"] ?? 0) + (b["Width"] ?? 0), y >= b["Y"] ?? 0, y < (b["Y"] ?? 0) + (b["Height"] ?? 0)
            else { continue }
            return w[kCGWindowOwnerName as String] as? String
        }
        return nil
    }

    /// With `MAC_I3_MOUSE_GUARD=<app>` set, a press is refused unless that app's window is topmost under
    /// the cursor, so a scripted test can never grab one of your real windows. Returns the offender.
    public static func guardViolation(x: Double, y: Double) -> String? {
        guard let allowed = ProcessInfo.processInfo.environment["MAC_I3_MOUSE_GUARD"], !allowed.isEmpty else { return nil }
        let owner = topWindowOwner(x: x, y: y)
        return owner == allowed ? nil : (owner ?? "nothing")
    }

    private static func post(_ type: CGEventType, _ x: Double, _ y: Double) {
        // A private source, so held keyboard modifiers (real or stuck) never leak into a scripted click.
        guard let e = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: type,
                              mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) else { return }
        e.flags = []
        if type == .leftMouseDown || type == .leftMouseUp { e.setIntegerValueField(.mouseEventClickState, value: 1) }
        e.post(tap: .cghidEventTap)
    }

    public static func move(_ x: Double, _ y: Double) { post(.mouseMoved, x, y); usleep(40_000) }
    public static func down(_ x: Double, _ y: Double) { move(x, y); post(.leftMouseDown, x, y); usleep(80_000) }
    public static func dragTo(_ x: Double, _ y: Double) { post(.leftMouseDragged, x, y); usleep(12_000) }
    public static func up(_ x: Double, _ y: Double) { usleep(60_000); post(.leftMouseUp, x, y); usleep(40_000) }
    public static func click(_ x: Double, _ y: Double) { down(x, y); up(x, y) }

    public static func drag(from a: (Double, Double), to b: (Double, Double), steps: Int = 24) {
        down(a.0, a.1)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            dragTo(a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
        }
        up(b.0, b.1)
    }
}
