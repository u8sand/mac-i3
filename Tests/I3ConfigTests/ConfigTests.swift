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

    @Test func middleDropJoinsGroupUnlessConfiguredToSwap() {
        #expect(!ConfigParser.parse("").config.mouseDropCenterSwaps)
        #expect(!ConfigParser.parse("mouse_drop_center group").config.mouseDropCenterSwaps)
        #expect(ConfigParser.parse("mouse_drop_center swap").config.mouseDropCenterSwaps)
    }
}

@Suite struct WorkspaceOutputConfig {
    @Test func parsesAssignmentsWithVariablesAndQuotes() {
        let r = ConfigParser.parse("""
        set $disp1 "Built-in Retina Display"
        set $disp2 ARZOPA
        workspace 1 output $disp1
        workspace 2 output $disp2
        workspace 3 output HDMI-1 $disp2
        workspace number 4 output primary
        workspace "5: web" output "Built-in Retina Display"
        """)
        #expect(r.errors.isEmpty)
        #expect(r.config.workspaceOutputs["1"] == ["Built-in Retina Display"])
        #expect(r.config.workspaceOutputs["2"] == ["ARZOPA"])
        #expect(r.config.workspaceOutputs["3"] == ["HDMI-1", "ARZOPA"])
        #expect(r.config.workspaceOutputs["4"] == ["primary"])
        #expect(r.config.workspaceOutputs["5: web"] == ["Built-in Retina Display"])
    }

    @Test func numberedOutputsParse() {
        let r = ConfigParser.parse("workspace 1 output 1\nworkspace 2 output 2\nworkspace 3 output 3 1")
        #expect(r.errors.isEmpty)
        #expect(r.config.workspaceOutputs == ["1": ["1"], "2": ["2"], "3": ["3", "1"]])
    }

    @Test func malformedAssignmentsAreReported() {
        #expect(ConfigParser.parse("workspace 1").errors.count == 1)
        #expect(ConfigParser.parse("workspace output HDMI-1").errors.count == 1)
        #expect(ConfigParser.parse("workspace 1 output").errors.count == 1)
    }
}


@Suite struct MouseWarpingOption {
    @Test func parsesModesAndDefaultsToWindow() {
        #expect(ConfigParser.parse("").config.mouseWarping == "window")
        for m in ["none", "output", "window", "center"] { #expect(ConfigParser.parse("mouse_warping \(m)").config.mouseWarping == m) }
        #expect(ConfigParser.parse("mouse_warping sideways").errors.count == 1)
    }
}
