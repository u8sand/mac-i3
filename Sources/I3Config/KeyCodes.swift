// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import Foundation

/// Physical (layout-independent) macOS virtual key codes for i3 key names.
public enum KeyCodes {
    static let table: [String: UInt16] = {
        var t: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "9": 25, "7": 26,
            "minus": 27, "8": 28, "0": 29, "bracketright": 30, "o": 31, "u": 32, "bracketleft": 33,
            "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "apostrophe": 39, "quote": 39,
            "k": 40, "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "n": 45, "m": 46,
            "period": 47, "tab": 48, "space": 49, "grave": 50, "backspace": 51, "escape": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "home": 115, "end": 119, "prior": 116, "next": 121, "pageup": 116, "pagedown": 121,
            "delete": 117,
        ]
        let f: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, c) in f.enumerated() { t["f\(i + 1)"] = c }
        return t
    }()

    public static func code(for name: String) -> UInt16? { table[name.lowercased()] }

    /// Reverse lookup used for diagnostics and key injection (first name wins).
    public static func name(for code: UInt16) -> String? {
        table.filter { $0.value == code }.keys.sorted { $0.count < $1.count || ($0.count == $1.count && $0 < $1) }.first
    }
}
