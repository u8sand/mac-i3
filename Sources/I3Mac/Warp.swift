import AppKit
import CoreGraphics
import I3Core

/// What was focused (and where) before a command ran, to tell afterwards whether focus moved.
struct FocusSnapshot {
    var window: WindowID?
    var frame: Rect?
    var output: String
}

extension WindowManager {
    func focusSnapshot() -> FocusSnapshot {
        let leaf = tree.descendFocused(tree.focused)
        let id = leaf.isWindow ? leaf.windowID : nil
        return FocusSnapshot(window: id, frame: id.flatMap { applied[$0] }, output: tree.activeOutput.name)
    }

    var warpMode: WarpMode { WarpMode(rawValue: config.mouseWarping) ?? .window }

    /// Move the cursor if the focus command that just ran calls for it. Never while a button is held
    /// (a drag in progress), and only for commands (keys / IPC), never for clicks or apps opening windows.
    func warpAfterCommand(before: FocusSnapshot, layout res: LayoutResult) {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let after = focusSnapshot()
        let target = after.window.flatMap { res.frames[$0] } ?? tree.activeOutput.rect
        let moved = { (a: Rect?, b: Rect?) -> Bool in
            guard let a, let b else { return (a == nil) != (b == nil) }
            return abs(a.x - b.x) > 1 || abs(a.y - b.y) > 1 || abs(a.w - b.w) > 1 || abs(a.h - b.h) > 1
        }
        let cursor = MouseInjector.position()
        if let p = warpDestination(mode: warpMode, focusChanged: before.window != after.window,
                                   frameChanged: moved(before.frame, after.window.flatMap { res.frames[$0] }),
                                   outputChanged: before.output != after.output, cursor: cursor, target: target) {
            warpCursor(to: p)
        }
    }

    /// A close command was issued for `warpAway`; once that window is really gone, the cursor follows focus to
    /// whatever window has it now. Checked after every layout pass, independent of how the new focus was
    /// reached (the OS usually reports the neighbour as focused itself, which the focus sync adopts first).
    func warpAfterWindowClosed(layout res: LayoutResult) {
        guard let gone = warpAway, Date() < warpUntil else { warpAway = nil; return }
        guard tree.find(gone) == nil else { return }             // not closed yet (or the app refused)
        warpAway = nil
        guard NSEvent.pressedMouseButtons == 0, let id = res.focusedWindow, let f = res.frames[id] else { return }
        if let p = warpDestination(mode: warpMode, focusChanged: true, frameChanged: false, outputChanged: false,
                                   cursor: MouseInjector.position(), target: f) {
            warpCursor(to: p)
        }
    }

    func warpCursor(to p: (x: Double, y: Double)) {
        log("mouse: warp to \(Int(p.x)),\(Int(p.y))")
        // Warping suppresses real mouse movement for a moment by default; turn that off so the user can move on at once.
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: p.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
