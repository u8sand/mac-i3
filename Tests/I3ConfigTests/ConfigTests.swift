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
