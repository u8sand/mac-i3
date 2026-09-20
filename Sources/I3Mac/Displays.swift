import AppKit
import I3Core

/// Display geometry helpers. AX coordinates have a top-left origin anchored at the primary screen.
public enum Displays {
    public static func publicOutputs() -> [String] {
        outputs().map { "\($0.name): \(Int($0.rect.w))x\(Int($0.rect.h)) at (\(Int($0.rect.x)), \(Int($0.rect.y)))" }
    }

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
}
