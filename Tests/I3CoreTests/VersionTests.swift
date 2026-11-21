// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import Testing
@testable import I3Core

@Suite struct Versions {
    @Test func parsesTagsAndComparesNumerically() {
        #expect(Version("v0.3.3")?.parts == [0, 3, 3])
        #expect(Version("0.3.10")! > Version("0.3.9")!)
        #expect(Version("1.0")! == Version("1.0.0")!)
        #expect(Version("v0.4.0-beta.1")! > Version("0.3.3")!)
        #expect(Version("nightly") == nil)
    }
}
