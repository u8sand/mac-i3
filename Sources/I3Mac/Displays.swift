// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import AppKit
import I3Core

/// Display geometry helpers. AX coordinates have a top-left origin anchored at the primary screen.
public enum Displays {
    public static func publicOutputs() -> [String] {
        outputs().map { "\($0.name): \(Int($0.rect.w))x\(Int($0.rect.h)) at (\(Int($0.rect.x)), \(Int($0.rect.y)))" }
    }

    /// Human-readable listing for `mac-i3 outputs`: id name, product name, usable area, primary flag.
    /// Numbered like the config's `output N`: 1 is the primary display, then the others left to right.
    public static func listing() -> [(number: Int, name: String, label: String, rect: Rect, primary: Bool)] {
        let primary = primaryName()
        let labels = labels()
        let all = outputs().map { (name: $0.name, label: labels[$0.name] ?? "", rect: $0.rect, primary: $0.name == primary) }
        let ordered = all.filter { $0.primary } + all.filter { !$0.primary }
        return ordered.enumerated().map { (number: $0.offset + 1, name: $0.element.name, label: $0.element.label, rect: $0.element.rect, primary: $0.element.primary) }
    }

    /// Product names by output name ("Built-in Retina Display", "DELL U2720Q", ...), for matching config specs.
    static func labels() -> [String: String] {
        var out: [String: String] = [:]
        for s in NSScreen.screens { out["display-\(displayID(s))"] = s.localizedName }
        return out
    }

    /// The primary display (the one that has the menu bar).
    static func primaryName() -> String? { NSScreen.screens.first.map { "display-\(displayID($0))" } }

    static func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Convert an AppKit (bottom-left origin) rect to AX (top-left origin) coordinates.
    static func axRect(_ r: NSRect) -> Rect {
        let primaryH = NSScreen.screens.first?.frame.height ?? r.maxY
        return Rect(r.minX, primaryH - r.maxY, r.width, r.height)
    }

    /// Usable area of each display (menu bar and Dock excluded), left to right.
    static func outputs() -> [(name: String, rect: Rect)] {
        NSScreen.screens
            .map { (name: "display-\(displayID($0))", rect: axRect($0.visibleFrame)) }
            .sorted { $0.rect.x < $1.rect.x || ($0.rect.x == $1.rect.x && $0.rect.y < $1.rect.y) }
    }

    /// Full frames (for off-screen detection).
    static func fullFrames() -> [Rect] { NSScreen.screens.map { axRect($0.frame) } }

    /// Width the primary menu bar has for our status item: the stretch right of the notch (or, without one,
    /// right of the frontmost app's menus), minus every other status item in it. A status item wider than
    /// this is not squeezed or scrolled by macOS — it is silently not shown at all. `ownWindow`/`ownFrame`
    /// identify our own item, which is left out of the sum. Nil when it cannot be measured.
    static func menuBarRoom(ownWindow: Int?, ownFrame: Rect?) -> Double? {
        guard let screen = NSScreen.screens.first else { return nil }
        let width = Double(screen.frame.width)
        let left: Double
        if let right = screen.auxiliaryTopRightArea {
            left = Double(right.minX)
        } else if let menus = frontmostMenusRight() {
            left = menus
        } else {
            return nil
        }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var used = 0.0
        for w in windows where (w[kCGWindowLayer as String] as? Int) == statusLevel {
            guard let d = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: d),
                  b.minY <= 1, b.minX >= left - 1, b.maxX <= width + 2 else { continue }
            if let n = w[kCGWindowNumber as String] as? Int, n == ownWindow { continue }
            // Ours is whatever overlaps our own frame. Not an exact match: right after the bar resizes, the window
            // server still reports its old bounds for a moment, and counting ourselves as another item then halved
            // the room and briefly stripped every icon each time a window opened or closed.
            if let own = ownFrame, own.w > 0, b.minX < own.maxX - 1, b.maxX > own.x + 1 { continue }
            used += b.width
        }
        return max(0, width - left - used)
    }

    /// Right edge of the frontmost app's menus (the bar's left limit on a display without a notch).
    static func frontmostMenusRight() -> Double? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.2)
        guard let bar = AX.attr(ax, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let items = AX.attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement],
              let last = items.last, let f = AX.frame(last) else { return nil }
        return f.maxX
    }
}
