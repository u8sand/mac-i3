// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import Foundation

/// A dotted release version such as `0.3.3` (a leading `v`, as in git tags, is ignored).
public struct Version: Comparable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ s: String) {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.first == "v" || t.first == "V" { t.removeFirst() }
        // Anything after the numbers (`-beta.1`, `+build`) is not compared.
        let core = t.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        self.parts = parts
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}
