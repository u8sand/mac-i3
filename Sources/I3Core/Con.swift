import Foundation

public typealias WindowID = UInt32

/// Rectangle in screen coordinates with a TOP-LEFT origin (same as the Accessibility API).
public struct Rect: Equatable, Codable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
    public var maxX: Double { x + w }
    public var maxY: Double { y + h }
    public var midX: Double { x + w / 2 }
    public var midY: Double { y + h / 2 }
    public func contains(x px: Double, y py: Double) -> Bool { px >= x && px < maxX && py >= y && py < maxY }
}

public enum Orientation { case horizontal, vertical }

public enum Layout: String, Codable {
    case splitH = "splith", splitV = "splitv", stacked, tabbed
    /// i3 treats tabbed as horizontal and stacked as vertical for direction commands.
    public var orientation: Orientation {
        switch self {
        case .splitH, .tabbed: return .horizontal
        case .splitV, .stacked: return .vertical
        }
    }
    public var isTabLike: Bool { self == .tabbed || self == .stacked }
    public static func split(_ o: Orientation) -> Layout { o == .horizontal ? .splitH : .splitV }
}

public enum Direction: String {
    case left, right, up, down
    public var orientation: Orientation { (self == .left || self == .right) ? .horizontal : .vertical }
    /// Towards the end of a child list (right / down).
    public var isForward: Bool { self == .right || self == .down }
}

/// A node of the i3 tree: root → output → workspace → split → window.
public final class Con {
    public enum Kind: String { case root, output, workspace, split, window }

    public let kind: Kind
    public var name: String = ""
    public var title: String = ""
    public var windowID: WindowID?
    public var layout: Layout = .splitH
    /// Last non-tabbed/stacked layout, restored by `layout toggle split`.
    public var lastSplit: Layout = .splitH
    /// Tiling children, in layout order. For root: outputs. For output: workspaces.
    public var children: [Con] = []
    /// Floating windows (workspaces only).
    public var floating: [Con] = []
    /// `children + floating`, most recently focused first.
    public var focusOrder: [Con] = []
    public weak var parent: Con?
    /// Share of the parent's size along its orientation (0 = unset, fixed up by fixPercent).
    public var percent: Double = 0
    /// Output frame (outputs) or frame (floating windows).
    public var rect = Rect(0, 0, 0, 0)
    public var isFloating = false
    public var fullscreen = false

    public init(_ kind: Kind) { self.kind = kind }

    public var isWindow: Bool { kind == .window }
    public var isContainer: Bool { kind == .split || kind == .workspace }

    /// Attach as a child; least-recently focused unless `focusFront`.
    public func attach(_ c: Con, at index: Int? = nil, focusFront: Bool = false) {
        c.parent = self
        if c.isFloating {
            floating.append(c)
        } else {
            let i = min(max(index ?? children.count, 0), children.count)
            children.insert(c, at: i)
        }
        if focusFront { focusOrder.insert(c, at: 0) } else { focusOrder.append(c) }
    }

    public func detach() {
        guard let p = parent else { return }
        p.children.removeAll { $0 === self }
        p.floating.removeAll { $0 === self }
        p.focusOrder.removeAll { $0 === self }
        parent = nil
    }

    public var indexInParent: Int? { parent?.children.firstIndex { $0 === self } }

    /// All window leaves below (tiling + floating), in tree order.
    public func windows() -> [Con] {
        if isWindow { return [self] }
        return children.flatMap { $0.windows() } + floating
    }

    public func isDescendant(of other: Con) -> Bool {
        var c: Con? = self
        while let x = c { if x === other { return true }; c = x.parent }
        return false
    }

    /// Nearest ancestor (or self) workspace.
    public var workspace: Con? {
        var c: Con? = self
        while let x = c { if x.kind == .workspace { return x }; c = x.parent }
        return nil
    }
    public var output: Con? {
        var c: Con? = self
        while let x = c { if x.kind == .output { return x }; c = x.parent }
        return nil
    }

    /// Equalize/repair `percent` of tiling children (port of i3's con_fix_percent).
    public func fixPercent() {
        guard !children.isEmpty else { return }
        var total = 0.0
        var withPercent = 0
        for c in children where c.percent > 0 { total += c.percent; withPercent += 1 }
        if withPercent != children.count {
            for c in children where c.percent <= 0 {
                if withPercent == 0 {
                    c.percent = 1.0; total += 1.0
                } else {
                    c.percent = total / Double(withPercent); total += c.percent
                }
            }
        }
        if total > 0 { for c in children { c.percent /= total } }
    }
}
