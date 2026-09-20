import Foundation

/// Parses the subset of i3's config syntax that is meaningful on macOS.
public enum ConfigParser {
    public struct Result {
        public var config: Config
        public var errors: [String]
    }

    static func modifier(_ name: String) -> Modifiers? {
        switch name.lowercased() {
        case "shift": return .shift
        case "control", "ctrl": return .control
        case "mod1", "alt", "option": return .option
        case "mod4", "super", "win", "cmd", "command": return .command
        default: return nil
        }
    }

    public static func parseChord(_ s: String) -> (Modifiers, UInt16)? {
        let parts = s.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        guard let keyName = parts.last, let code = KeyCodes.code(for: keyName) else { return nil }
        var mods = Modifiers()
        for m in parts.dropLast() {
            guard let flag = modifier(m) else { return nil }
            mods.insert(flag)
        }
        return (mods, code)
    }

    public static func parse(_ text: String) -> Result {
        var cfg = Config()
        var errors: [String] = []
        var vars: [(String, String)] = []
        var mode = "default"
        var inMode = false

        func expand(_ s: String) -> String {
            var out = s
            for (k, v) in vars.sorted(by: { $0.0.count > $1.0.count }) { out = out.replacingOccurrences(of: k, with: v) }
            return out
        }

        for (n, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let lineNo = n + 1

            if line == "}" { mode = "default"; inMode = false; continue }
            if line.hasPrefix("set ") {
                let rest = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[0].hasPrefix("$") { vars.append((parts[0], expand(parts[1]))) }
                else { errors.append("line \(lineNo): bad set") }
                continue
            }
            let l = expand(line)
            if l.hasPrefix("mode ") {
                var name = l.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if name.hasSuffix("{") { name = String(name.dropLast()).trimmingCharacters(in: .whitespaces) }
                mode = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                inMode = true
                if cfg.modes[mode] == nil { cfg.modes[mode] = [] }
                continue
            }
            let tokens = l.split(separator: " ", maxSplits: 1).map(String.init)
            let head = tokens[0]
            let rest = tokens.count > 1 ? tokens[1].trimmingCharacters(in: .whitespaces) : ""
            switch head {
            case "bindsym":
                var r = rest
                var release = false
                while r.hasPrefix("--") {
                    let sp = r.split(separator: " ", maxSplits: 1).map(String.init)
                    if sp[0] == "--release" { release = true }
                    r = sp.count > 1 ? sp[1].trimmingCharacters(in: .whitespaces) : ""
                }
                let sp = r.split(separator: " ", maxSplits: 1).map(String.init)
                guard sp.count == 2, let (mods, code) = parseChord(sp[0]) else {
                    errors.append("line \(lineNo): cannot parse binding '\(rest)'"); continue
                }
                cfg.modes[mode, default: []].append(
                    KeyBinding(modifiers: mods, keyCode: code, command: sp[1], chord: sp[0], release: release))
            case "gaps":
                let p = rest.split(separator: " ").map(String.init)
                if p.count == 2, let v = Double(p[1]) {
                    if p[0] == "inner" { cfg.innerGap = v } else if p[0] == "outer" { cfg.outerGap = v }
                }
            case "focus_wrapping":
                cfg.focusWrapping = !(rest == "no")
            case "exec", "exec_always":
                cfg.startup.append(rest)
            case "for_window":
                if let close = rest.firstIndex(of: "]") {
                    cfg.forWindow.append(WindowRule(criteria: String(rest[...close]),
                                                     command: rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)))
                }
            case "assign":
                if let close = rest.firstIndex(of: "]") {
                    cfg.assign.append(WindowRule(criteria: String(rest[...close]),
                                                  command: rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)))
                }
            default:
                // font, floating_modifier, bar {...}, colours... have no meaning here.
                _ = inMode
            }
        }
        return Result(config: cfg, errors: errors)
    }
}
