import Foundation

public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = Modifiers(rawValue: 1)
    public static let control = Modifiers(rawValue: 2)
    public static let option = Modifiers(rawValue: 4)   // i3 Mod1 / Alt
    public static let command = Modifiers(rawValue: 8)  // i3 Mod4 / Super
}

public struct KeyBinding: Equatable {
    public var modifiers: Modifiers
    public var keyCode: UInt16
    public var command: String
    /// Human-readable form of the chord, e.g. "Mod1+Shift+q".
    public var chord: String
    public var release = false
    public init(modifiers: Modifiers, keyCode: UInt16, command: String, chord: String, release: Bool = false) {
        self.modifiers = modifiers; self.keyCode = keyCode; self.command = command; self.chord = chord; self.release = release
    }
    /// Key used for dictionary lookup in the event tap.
    public var lookupKey: UInt32 { UInt32(modifiers.rawValue) << 16 | UInt32(keyCode) }
}

public struct WindowRule {
    public var criteria: String
    public var command: String
}

public struct Config {
    /// Bindings per binding mode; the initial mode is "default".
    public var modes: [String: [KeyBinding]] = ["default": []]
    public var innerGap = 0.0
    public var outerGap = 0.0
    public var focusWrapping = true
    /// Drag to resize / move tiled windows (`mouse_gestures no` turns it off).
    public var mouseGestures = true
    /// `workspace <name> output <spec>...`: preferred outputs per workspace, most preferred first.
    public var workspaceOutputs: [String: [String]] = [:]
    /// Dropping a dragged window on the middle of another swaps them (default: joins that window's group).
    public var mouseDropCenterSwaps = false
    public var startup: [String] = []
    public var forWindow: [WindowRule] = []
    public var assign: [WindowRule] = []
    public init() {}
}
