// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import Foundation

/// A node of a workspace's container tree, as the bar draws it: a window, or a container with its layout
/// letter (`h` horizontal split, `v` vertical split, `t` tabbed, `s` stacked, `f` the floating group).
public indirect enum BarNode: Equatable {
    case window(WindowID, focused: Bool)
    case container(Character, [BarNode])

    /// Number of windows in this subtree.
    public var windowCount: Int {
        switch self {
        case .window: return 1
        case .container(_, let kids): return kids.reduce(0) { $0 + $1.windowCount }
        }
    }

    /// i3-style text: a container is its layout letter followed by its children in square brackets, a window
    /// is its name, and siblings are separated by spaces: `h[chrome term]`, `t[chrome v[chrome chrome]]`.
    public func notation(_ name: (WindowID) -> String) -> String {
        switch self {
        case .window(let id, _): return name(id)
        case .container(let letter, let kids): return "\(letter)[" + kids.map { $0.notation(name) }.joined(separator: " ") + "]"
        }
    }
}

/// One workspace as the workspace bar shows it.
public struct BarWorkspace: Equatable {
    public var name: String
    /// The workspace currently showing on its display.
    public var showing: Bool
    /// The workspace that holds keyboard focus.
    public var focused: Bool
    /// Its windows (tiled, then floating), in tree order.
    public var windows: [WindowID]
    /// Layout letter of the workspace's own container (`h` unless it was changed).
    public var layout: Character = "h"
    /// The workspace container's children, in order.
    public var nodes: [BarNode] = []
    /// Floating windows.
    public var floating: [WindowID] = []

    /// The whole workspace as i3-style text. The workspace's own container is written like any other, except
    /// that a plain horizontal one (the default) is left implicit, so a workspace holding two containers reads
    /// `h[chrome term] t[chrome v[chrome chrome]]`. Floating windows follow as `f[...]`.
    public func notation(_ name: (WindowID) -> String) -> String {
        var parts = layout == "h" ? nodes.map { $0.notation(name) } : [BarNode.container(layout, nodes).notation(name)]
        if !floating.isEmpty { parts.append(BarNode.container("f", floating.map { .window($0, focused: false) }).notation(name)) }
        return parts.joined(separator: " ")
    }
}

/// The workspaces of one display.
public struct BarOutput: Equatable {
    /// User-facing number (`output N` in the config): 1 is the primary display.
    public var number: Int
    public var name: String
    public var workspaces: [BarWorkspace]
}

/// Everything the workspace bar draws. Equatable, so the host redraws only when something changed.
public struct BarSummary: Equatable {
    public var outputs: [BarOutput]
    /// The current binding mode ("default" unless e.g. resize mode is active).
    public var mode: String

    public init(outputs: [BarOutput] = [], mode: String = "default") {
        self.outputs = outputs
        self.mode = mode
    }
}

extension Tree {
    /// Displays in `output N` order (primary first), each with its existing workspaces sorted numerically.
    /// A workspace exists for the bar if it has windows, is showing, or holds focus (like i3bar).
    public func barSummary(mode: String = "default") -> BarSummary {
        let focusedWorkspace = focused.workspace
        let outputs = numberedOutputs.enumerated().map { index, out -> BarOutput in
            let showing = currentWorkspace(of: out)
            let list = out.children.compactMap { ws -> BarWorkspace? in
                let windows = ws.windows().compactMap { $0.windowID }
                let isShowing = ws === showing
                let isFocused = ws === focusedWorkspace
                guard isShowing || isFocused || !windows.isEmpty else { return nil }
                return BarWorkspace(name: ws.name, showing: isShowing, focused: isFocused, windows: windows,
                                    layout: layoutLetter(ws.layout), nodes: ws.children.compactMap(barNode),
                                    floating: ws.floating.compactMap { $0.windowID })
            }
            return BarOutput(number: index + 1, name: out.name, workspaces: list)
        }
        return BarSummary(outputs: outputs, mode: mode)
    }

    private func layoutLetter(_ l: Layout) -> Character {
        switch l {
        case .splitH: return "h"
        case .splitV: return "v"
        case .tabbed: return "t"
        case .stacked: return "s"
        }
    }

    private func barNode(_ c: Con) -> BarNode? {
        if c.isWindow { return c.windowID.map { .window($0, focused: c === focused) } }
        return .container(layoutLetter(c.layout), c.children.compactMap(barNode))
    }
}
