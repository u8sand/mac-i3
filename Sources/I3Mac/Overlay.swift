import AppKit
import I3Core

/// Draws i3-style title bars for tabbed/stacked containers in borderless, non-activating panels that
/// sit in the strip the layout reserved above the windows. Clicking a tab focuses that window.
final class OverlayController {
    var onTabClick: ((WindowID) -> Void)?
    private var panels: [BarPanel] = []

    func update(bars: [Bar], tree: Tree) {
        while panels.count < bars.count { panels.append(BarPanel { [weak self] id in self?.onTabClick?(id) }) }
        for (i, bar) in bars.enumerated() { panels[i].show(bar) }
        for p in panels.dropFirst(bars.count) { p.orderOut(nil) }
    }

    func hideAll() { panels.forEach { $0.orderOut(nil) } }
}

private final class BarPanel: NSPanel {
    let barView: BarView

    init(onClick: @escaping (WindowID) -> Void) {
        barView = BarView(onClick: onClick)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = true
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = barView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ bar: Bar) {
        barView.bar = bar
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let r = bar.rect
        let frame = NSRect(x: r.x, y: primaryH - r.maxY, width: r.w, height: r.h)
        if self.frame != frame { setFrame(frame, display: false) }
        barView.needsDisplay = true
        orderFrontRegardless()
    }
}

private final class BarView: NSView {
    var bar: Bar?
    let onClick: (WindowID) -> Void

    init(onClick: @escaping (WindowID) -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // i3's default colour scheme (client.focused / focused_inactive / unfocused).
    private func colors(for t: BarTab) -> (bg: NSColor, border: NSColor, text: NSColor) {
        func c(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        if t.focused { return (c(0x285577), c(0x4c7899), c(0xffffff)) }
        if t.active { return (c(0x5f676a), c(0x333333), c(0xffffff)) }
        return (c(0x222222), c(0x333333), c(0x888888))
    }

    private func slot(_ i: Int, of n: Int, vertical: Bool) -> NSRect {
        if vertical {
            let h = bounds.height / CGFloat(n)
            return NSRect(x: 0, y: CGFloat(i) * h, width: bounds.width, height: h)
        }
        let w = bounds.width / CGFloat(n)
        return NSRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1).setFill()
        bounds.fill()
        guard let bar else { return }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.alignment = .center
        let n = bar.tabs.count
        for (i, tab) in bar.tabs.enumerated() {
            let col = colors(for: tab)
            let r = slot(i, of: n, vertical: bar.vertical)
            col.bg.setFill()
            r.fill()
            col.border.setStroke()
            NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: col.text, .paragraphStyle: para,
            ]
            let text = tab.title.isEmpty ? "—" : tab.title
            let size = (text as NSString).size(withAttributes: attrs)
            let tr = NSRect(x: r.minX + 6, y: r.minY + (r.height - size.height) / 2, width: r.width - 12, height: size.height)
            (text as NSString).draw(in: tr, withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let bar else { return }
        let p = convert(event.locationInWindow, from: nil)
        for (i, tab) in bar.tabs.enumerated() where slot(i, of: bar.tabs.count, vertical: bar.vertical).contains(p) {
            if let id = tab.windowID { onClick(id) }
            return
        }
    }
}
