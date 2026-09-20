// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import Foundation

extension Tree {
    /// Split an i3 command string on `;` and `,` (outside quotes) into individual commands.
    public static func splitCommands(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote = false
        for ch in line {
            if ch == "\"" { quote.toggle(); cur.append(ch); continue }
            if !quote && (ch == ";" || ch == ",") {
                let t = cur.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                cur = ""
                continue
            }
            cur.append(ch)
        }
        let t = cur.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        return out
    }

    static func tokenize(_ s: String) -> [String] {
        var toks: [String] = []
        var cur = ""
        var quote = false
        var started = false
        for ch in s {
            if ch == "\"" { quote.toggle(); started = true; continue }
            if ch == " " && !quote {
                if started { toks.append(cur); cur = ""; started = false }
                continue
            }
            cur.append(ch); started = true
        }
        if started { toks.append(cur) }
        return toks
    }

    /// Execute one or more i3 commands. Returns side effects for the host to perform.
    /// Unknown commands are reported through `errors`.
    @discardableResult
    public func run(_ line: String, errors: inout [String]) -> [Action] {
        var actions: [Action] = []
        for cmd in Tree.splitCommands(line) {
            if let a = runOne(cmd, &errors) { actions.append(contentsOf: a) }
            sanitizeFocus()
        }
        return actions
    }

    @discardableResult
    public func run(_ line: String) -> [Action] {
        var errs: [String] = []
        return run(line, errors: &errs)
    }

    static func direction(_ s: String) -> Direction? { Direction(rawValue: s) }

    private func runOne(_ cmd: String, _ errors: inout [String]) -> [Action]? {
        // `exec` keeps its argument verbatim.
        if cmd.hasPrefix("exec ") || cmd == "exec" {
            var rest = String(cmd.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            while rest.hasPrefix("--no-startup-id") { rest = String(rest.dropFirst(15)).trimmingCharacters(in: .whitespaces) }
            return rest.isEmpty ? nil : [.exec(rest)]
        }
        let t = Tree.tokenize(cmd)
        guard let head = t.first else { return nil }
        let args = Array(t.dropFirst())
        switch head {
        case "focus":
            guard let a = args.first else { break }
            if let d = Tree.direction(a) { focusDirection(d); return nil }
            switch a {
            case "parent": focusParent(); return nil
            case "child": focusChild(); return nil
            case "mode_toggle": focusModeToggle(); return nil
            case "floating", "tiling": focusModeToggle(); return nil
            case "output":
                if args.count > 1, let d = Tree.direction(args[1]) { focusOutput(d); return nil }
                if args.count > 1 {
                    let spec = args.dropFirst().joined(separator: " ")
                    if let out = resolveOutput(spec) { focusSwitchingWorkspace(descendFocused(currentWorkspace(of: out))); return nil }
                    errors.append("no output matched: \(spec)"); return nil
                }
            default: break
            }
        case "move":
            if let a = args.first, let d = Tree.direction(a) {
                var px = 10.0
                if args.count > 1, let v = Double(args[1]) { px = v }
                move(d, px: px)
                return nil
            }
            // move [container|window] to workspace <name|next|prev|number N>
            if let i = args.firstIndex(of: "workspace"), args.contains("to") || args.first == "workspace" {
                let rest = Array(args[(i + 1)...])
                if rest.first == "to", rest.count >= 3, rest[1] == "output" {
                    let spec = rest.dropFirst(2).joined(separator: " ")
                    if let d = Tree.direction(spec) { moveWorkspaceToOutput(d); return nil }
                    if let out = resolveOutput(spec) { moveActiveWorkspace(to: out); return nil }
                    errors.append("no output matched: \(spec)"); return nil
                }
                if let name = resolveWorkspaceName(rest) { moveContainerToWorkspace(name); return nil }
            }
            if let i = args.firstIndex(of: "output"), i + 1 < args.count, let d = Tree.direction(args[i + 1]) {
                moveContainerToOutput(d); return nil
            }
        case "workspace":
            if args.first == "back_and_forth" {
                if let prev = previousWorkspaceName { switchWorkspace(prev) }
                return nil
            }
            if let name = resolveWorkspaceName(args) { switchWorkspace(name); return nil }
        case "split":
            switch args.first {
            case "h", "horizontal": split(.horizontal); return nil
            case "v", "vertical": split(.vertical); return nil
            case "t", "toggle": split(activeOrientationFlipped()); return nil
            default: break
            }
        case "splith": split(.horizontal); return nil
        case "splitv": split(.vertical); return nil
        case "layout":
            switch args.first {
            case "splith": setLayout(.set(.splitH)); return nil
            case "splitv": setLayout(.set(.splitV)); return nil
            case "stacking", "stacked": setLayout(.set(.stacked)); return nil
            case "tabbed": setLayout(.set(.tabbed)); return nil
            case "toggle":
                setLayout(args.dropFirst().first == "all" ? .toggleAll : .toggleSplit); return nil
            default: break
            }
        case "fullscreen":
            toggleFullscreen(); return nil
        case "floating":
            if args.first == "toggle" || args.first == "enable" || args.first == "disable" {
                let want = args.first == "enable" ? true : args.first == "disable" ? false : !focused.isFloating
                if want != focused.isFloating { toggleFloating() }
                return nil
            }
        case "kill":
            return focused.windows().compactMap { $0.windowID }.map { .kill($0) }
        case "resize":
            if args.count >= 2 {
                let grow = args[0] == "grow"
                let amountTok = args.count > 2 ? args[2] : "10"
                let amount = Double(amountTok) ?? 10
                let unit: ResizeUnit = args.contains("px") && !args.contains("ppt") ? .px : (focused.isFloating ? .px : .ppt)
                switch args[1] {
                case "width", "left", "right": resize(grow: grow, horizontal: true, amount: amount, unit: unit); return nil
                case "height", "up", "down": resize(grow: grow, horizontal: false, amount: amount, unit: unit); return nil
                default: break
                }
            }
        case "mode":
            if let m = args.first { return [.mode(m)] }
        case "reload": return [.reload]
        case "restart": return [.restart]
        case "exit": return [.exit]
        case "nop": return nil
        default: break
        }
        errors.append("unknown command: \(cmd)")
        return nil
    }

    private func activeOrientationFlipped() -> Orientation {
        let p = focused.kind == .workspace ? focused : (focused.parent ?? focused)
        return p.layout.orientation == .horizontal ? .vertical : .horizontal
    }

    /// `workspace 3`, `workspace number 3`, `workspace next|prev|back_and_forth`
    func resolveWorkspaceName(_ args: [String]) -> String? {
        var a = args
        if a.first == "number" || a.first == "to" { a.removeFirst() }
        guard let first = a.first else { return nil }
        switch first {
        case "next", "prev", "next_on_output", "prev_on_output":
            let list = activeOutput.children
            guard let i = list.firstIndex(where: { $0 === activeWorkspace }) else { return nil }
            let n = list.count
            return list[(i + (first.hasPrefix("next") ? 1 : n - 1)) % n].name
        case "back_and_forth":
            return previousWorkspaceName
        default:
            return first
        }
    }

    // MARK: - multi-monitor

    public func moveContainerToOutput(_ dir: Direction) {
        let con = focused
        guard con.isWindow || con.kind == .split, let out = adjacentOutput(of: activeOutput, dir) else { return }
        let from = activeWorkspace
        let ws = currentWorkspace(of: out)
        let oldParent = con.parent!
        con.detach()
        cleanup(oldParent)
        con.percent = 0
        if con.isFloating { ws.attach(con) } else {
            let ref = descendTiling(ws)
            if ref.isWindow { ref.parent!.attach(con, at: ref.indexInParent! + 1); ref.parent!.fixPercent() }
            else { ref.attach(con); ref.fixPercent() }
        }
        focus(descendFocused(from))
    }

    public func moveWorkspaceToOutput(_ dir: Direction) {
        guard let out = adjacentOutput(of: activeOutput, dir) else { return }
        moveActiveWorkspace(to: out)
    }
}
