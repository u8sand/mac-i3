// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import Foundation

/// When the mouse cursor follows keyboard focus (i3's `mouse_warping`, extended).
public enum WarpMode: String {
    case none      // never
    case output    // only when focus moves to another display (i3's default)
    case window    // when the cursor is not already over the focused window (default here)
    case center    // always, to the exact centre of the focused window
}

/// Where the cursor should go after a focus command, or nil to leave it alone.
///
/// - `target`: the focused window's frame, or the output's area when focus landed on an empty workspace.
/// - The window (or its frame) must have changed for `window`/`center` to act, so commands that do not
///   touch focus (resize, layout toggles on a window that stays put) never move the cursor.
public func warpDestination(mode: WarpMode, focusChanged: Bool, frameChanged: Bool, outputChanged: Bool,
                            cursor: (x: Double, y: Double), target: Rect) -> (x: Double, y: Double)? {
    let centre = (x: target.midX, y: target.midY)
    switch mode {
    case .none:
        return nil
    case .output:
        return outputChanged ? centre : nil
    case .window:
        guard focusChanged || frameChanged || outputChanged else { return nil }
        return target.contains(x: cursor.x, y: cursor.y) ? nil : centre
    case .center:
        return (focusChanged || frameChanged || outputChanged) ? centre : nil
    }
}
