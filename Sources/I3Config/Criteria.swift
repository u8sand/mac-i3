// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import Foundation

/// i3 window criteria such as `[class=".*"]` or `[app="Terminal" title="^vim"]`.
///
/// Values are regular expressions matched anywhere in the property (as in i3) and are
/// case-insensitive, since macOS app names are inconsistently cased. `class`, `instance`, `app` and
/// `app_name` all refer to the application's name. An unknown key never matches; `[]` matches everything.
public struct Criteria {
    struct Term {
        let key: String
        let pattern: String
        let regex: NSRegularExpression?
    }
    let terms: [Term]

    public init(_ text: String) {
        var out: [Term] = []
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t"))
        let term = try! NSRegularExpression(pattern: #"([A-Za-z_]+)\s*=\s*(?:"([^"]*)"|(\S+))"#)
        let ns = body as NSString
        for m in term.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            let valueRange = m.range(at: 2).location != NSNotFound ? m.range(at: 2) : m.range(at: 3)
            let value = ns.substring(with: valueRange)
            out.append(Term(key: key, pattern: value, regex: try? NSRegularExpression(pattern: value, options: [.caseInsensitive])))
        }
        terms = out
    }

    public func matches(app: String, title: String) -> Bool {
        for t in terms {
            let subject: String
            switch t.key {
            case "class", "instance", "app", "app_name": subject = app
            case "title": subject = title
            default: return false
            }
            if let re = t.regex {
                if re.firstMatch(in: subject, range: NSRange(location: 0, length: (subject as NSString).length)) == nil { return false }
            } else if !subject.localizedCaseInsensitiveContains(t.pattern) {
                return false   // not a valid regex: fall back to a plain substring match
            }
        }
        return true
    }
}
