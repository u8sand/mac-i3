import Testing
@testable import I3Config

@Suite struct ParserTests {
    @Test func defaultConfigParsesCleanly() {
        let r = ConfigParser.parse(DefaultConfig.text)
        #expect(r.errors.isEmpty)
        #expect(r.config.modes["default"]!.count > 50)
        #expect(r.config.modes["resize"]!.count == 11)
    }

    @Test func modAndKeyResolution() throws {
        let r = ConfigParser.parse(DefaultConfig.text)
        let b = try #require(r.config.modes["default"]!.first { $0.command == "kill" })
        #expect(b.modifiers == [.option, .shift])
        #expect(b.keyCode == 12)   // q
        let semi = try #require(r.config.modes["default"]!.first { $0.command == "focus right" && $0.chord.hasSuffix("semicolon") })
        #expect(semi.keyCode == 41)
    }

    @Test func variablesAndModes() {
        let r = ConfigParser.parse("""
        set $m Mod4
        set $term open -a iTerm
        bindsym $m+Return exec $term
        mode "x" {
            bindsym Escape mode "default"
        }
        bindsym --release Ctrl+a nop
        gaps inner 8
        gaps outer 4
        """)
        #expect(r.errors.isEmpty)
        let b = r.config.modes["default"]![0]
        #expect(b.modifiers == [.command] && b.command == "exec open -a iTerm")
        #expect(r.config.modes["x"]!.count == 1)
        #expect(r.config.modes["default"]![1].release)
        #expect(r.config.innerGap == 8 && r.config.outerGap == 4)
    }

    @Test func badBindingsAreReported() {
        let r = ConfigParser.parse("bindsym Mod1+nosuchkey kill\nbindsym Bogus+a kill")
        #expect(r.errors.count == 2)
    }
}

@Suite struct CriteriaTests {
    @Test func classWildcardMatchesEverything() {
        let c = Criteria(#"[class=".*"]"#)
        #expect(c.matches(app: "Terminal", title: "x") && c.matches(app: "", title: ""))
    }

    @Test func emptyCriteriaMatchesEverything() {
        #expect(Criteria("[]").matches(app: "Any", title: "thing"))
    }

    @Test func appMatchesAnywhereCaseInsensitively() {
        let c = Criteria(#"[app="term"]"#)
        #expect(c.matches(app: "Terminal", title: "") && !c.matches(app: "Safari", title: ""))
    }

    @Test func alternationAndAnchors() {
        let c = Criteria(#"[app="^(Terminal|iTerm2)$"]"#)
        #expect(c.matches(app: "iTerm2", title: "") && c.matches(app: "Terminal", title: ""))
        #expect(!c.matches(app: "Terminal Helper", title: ""))
    }

    @Test func allTermsMustMatch() {
        let c = Criteria(#"[app="Terminal" title="^vim"]"#)
        #expect(c.matches(app: "Terminal", title: "vim foo"))
        #expect(!c.matches(app: "Terminal", title: "zsh"))
        #expect(!c.matches(app: "Safari", title: "vim foo"))
    }

    @Test func titleValuesMayContainSpaces() {
        let c = Criteria(#"[title="Save As"]"#)
        #expect(c.matches(app: "x", title: "Save As…") && !c.matches(app: "x", title: "Save"))
    }

    @Test func unknownKeysNeverMatchAndBadRegexFallsBackToSubstring() {
        #expect(!Criteria(#"[window_role="x"]"#).matches(app: "a", title: "b"))
        #expect(Criteria(#"[title="foo("]"#).matches(app: "a", title: "a foo( b"))
    }
}

@Suite struct MouseOption {
    @Test func gesturesAreOnByDefaultAndCanBeDisabled() {
        #expect(ConfigParser.parse("").config.mouseGestures)
        #expect(!ConfigParser.parse("mouse_gestures no").config.mouseGestures)
        #expect(!ConfigParser.parse("mouse_gestures off").config.mouseGestures)
        #expect(ConfigParser.parse("mouse_gestures yes").config.mouseGestures)
    }
}
