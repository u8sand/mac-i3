import Foundation

/// One workspace as the workspace bar shows it.
public struct BarWorkspace: Equatable {
    public var name: String
    /// The workspace currently showing on its display.
    public var showing: Bool
    /// The workspace that holds keyboard focus.
    public var focused: Bool
    /// Its windows (tiled, then floating), in tree order.
    public var windows: [WindowID]
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
                return BarWorkspace(name: ws.name, showing: isShowing, focused: isFocused, windows: windows)
            }
            return BarOutput(number: index + 1, name: out.name, workspaces: list)
        }
        return BarSummary(outputs: outputs, mode: mode)
    }
}
