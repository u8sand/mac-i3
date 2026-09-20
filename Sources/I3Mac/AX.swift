import AppKit
import ApplicationServices
import I3Core

// Private but long-stable API used by every macOS tiling WM to map AXUIElement -> CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin helpers over the Accessibility C API.
enum AX {
    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }

    static func bool(_ el: AXUIElement, _ name: String) -> Bool? {
        guard let v = attr(el, name) else { return nil }
        return (v as? NSNumber)?.boolValue
    }

    static func point(_ el: AXUIElement, _ name: String) -> CGPoint? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ el: AXUIElement, _ name: String) -> CGSize? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(el, name as CFString, value) == .success
    }

    static func setPosition(_ el: AXUIElement, x: Double, y: Double) {
        var p = CGPoint(x: x, y: y)
        if let v = AXValueCreate(.cgPoint, &p) { set(el, kAXPositionAttribute, v) }
    }

    static func setSize(_ el: AXUIElement, w: Double, h: Double) {
        var s = CGSize(width: w, height: h)
        if let v = AXValueCreate(.cgSize, &s) { set(el, kAXSizeAttribute, v) }
    }

    static func windowID(_ el: AXUIElement) -> WindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(el, &id) == .success && id != 0 ? id : nil
    }

    static func frame(_ el: AXUIElement) -> Rect? {
        guard let p = point(el, kAXPositionAttribute), let s = size(el, kAXSizeAttribute) else { return nil }
        return Rect(p.x, p.y, s.width, s.height)
    }

    /// Move a window to a target frame.
    ///
    /// macOS silently drops size changes that would leave a window straddling two displays (it still
    /// reports success), e.g. shrinking a full-display window after moving it sideways. So the window is
    /// first parked at the origin of the target display, where any size up to the display size is legal,
    /// then resized, then moved to its final position. The result is read back and repeated if it did
    /// not stick.
    static func setFrame(_ el: AXUIElement, _ r: Rect) {
        let anchor = Displays.outputs().first { $0.rect.contains(x: r.midX, y: r.midY) }?.rect
        for attempt in 0..<3 {
            if let a = anchor { setPosition(el, x: a.x, y: a.y) }
            setSize(el, w: r.w, h: r.h)
            setPosition(el, x: r.x, y: r.y)
            guard attempt < 2, let f = frame(el), abs(f.w - r.w) > 24 || abs(f.h - r.h) > 24 else { return }
        }
    }

    /// False only when the element is definitively gone. Timeouts and "app busy" errors (which happen
    /// while an app is in the middle of a window drag) do not mean the window closed.
    static func exists(_ el: AXUIElement) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) != .invalidUIElement
    }

    static func isSettable(_ el: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, name as CFString, &settable) == .success && settable.boolValue
    }
}
