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
}
