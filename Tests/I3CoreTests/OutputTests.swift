import Testing
@testable import I3Core

/// Two displays like the real setup: a primary "Built-in Retina Display" on the left, "ARZOPA" on the right.
func twoDisplays() -> Tree {
    let t = Tree(outputs: [("display-1", Rect(0, 0, 1000, 800)), ("display-2", Rect(1000, 0, 1000, 800))])
    t.setOutputLabels(["display-1": "Built-in Retina Display", "display-2": "ARZOPA"], primary: "display-1")
    return t
}

func names(_ o: Con) -> [String] { o.children.map { $0.name } }

@Suite struct WorkspaceOutputAssignment {
    @Test func assignedWorkspaceMovesToItsOutputAndKeepsShowing() {
        let t = twoDisplays()
        t.addWindow(1)                                        // on workspace 1, left display
        t.setWorkspaceOutputs(["1": ["ARZOPA"]])
        #expect(names(t.outputs[1]).contains("1"))
        #expect(t.currentWorkspace(of: t.outputs[1]).name == "1")
        #expect(!names(t.outputs[0]).contains("1"))
        #expect(!t.outputs[0].children.isEmpty)               // the left display got a workspace of its own
        let f = t.computeLayout().frames
        #expect(f[1] == Rect(1000, 0, 1000, 800))
    }

    @Test func showingWorkspacesCanSwapDisplays() {
        let t = twoDisplays()
        t.addWindow(1); t.run("focus right"); t.addWindow(2)  // ws1 (left) and ws2 (right), both showing
        t.setWorkspaceOutputs(["1": ["ARZOPA"], "2": ["Built-in Retina Display"]])
        #expect(t.currentWorkspace(of: t.outputs[0]).name == "2")
        #expect(t.currentWorkspace(of: t.outputs[1]).name == "1")
        let f = t.computeLayout()
        #expect(f.frames[1] == Rect(1000, 0, 1000, 800) && f.frames[2] == Rect(0, 0, 1000, 800))
        #expect(f.hidden.isEmpty)
    }

    @Test func creatingAnAssignedWorkspaceOpensItOnItsOutput() {
        let t = twoDisplays()
        t.setWorkspaceOutputs(["5": ["ARZOPA"]])
        t.run("workspace 5")
        #expect(t.activeOutput.name == "display-2")
        #expect(t.activeWorkspace.name == "5")
        t.addWindow(9)
        #expect(t.computeLayout().frames[9] == Rect(1000, 0, 1000, 800))
    }

    @Test func movingAContainerToAnAssignedWorkspaceCreatesItThere() {
        let t = twoDisplays()
        t.setWorkspaceOutputs(["7": ["ARZOPA"]])
        t.addWindow(1)
        t.run("move container to workspace 7")
        #expect(t.workspace(named: "7")?.output?.name == "display-2")
    }

    @Test func numbersAssignedElsewhereAreNotUsedForNewOutputs() {
        let t = Tree(outputs: [("display-1", Rect(0, 0, 1000, 800))])
        t.setOutputLabels(["display-1": "Built-in"], primary: "display-1")
        t.setWorkspaceOutputs(["2": ["ARZOPA"]])
        t.updateOutputs([("display-1", Rect(0, 0, 1000, 800)), ("display-2", Rect(1000, 0, 1000, 800))],
                        labels: ["display-1": "Built-in", "display-2": "ARZOPA"], primary: "display-1")
        #expect(t.currentWorkspace(of: t.outputs[1]).name != "1")
    }

    @Test func unknownOutputFallsBackToPrimary() {
        let t = twoDisplays()
        t.run("focus output ARZOPA")                          // work on the right display...
        t.setWorkspaceOutputs(["3": ["Nonexistent"]])
        t.run("workspace 3")                                  // ...but ws 3 belongs on the primary one
        #expect(t.activeOutput.name == "display-1" && t.activeWorkspace.name == "3")
    }

    @Test func fallbackListUsesTheFirstConnectedOutput() {
        let t = twoDisplays()
        t.setWorkspaceOutputs(["3": ["HDMI-1", "arzopa", "Built-in Retina Display"]])
        t.run("workspace 3")
        #expect(t.activeOutput.name == "display-2")
    }

    @Test func primaryKeyword() {
        let t = twoDisplays()
        t.setOutputLabels([:], primary: "display-2")
        t.setWorkspaceOutputs(["1": ["primary"]])
        #expect(t.workspace(named: "1")?.output?.name == "display-2")
    }

    @Test func specsMatchNameLabelOrUniqueSubstring() {
        let t = twoDisplays()
        #expect(t.resolveOutput("display-2")?.name == "display-2")
        #expect(t.resolveOutput("ARZOPA")?.name == "display-2")
        #expect(t.resolveOutput("\"built-in retina display\"")?.name == "display-1")
        #expect(t.resolveOutput("built-in")?.name == "display-1")
        #expect(t.resolveOutput("nothing") == nil)
        #expect(t.resolveOutput("") == nil)
    }

    @Test func ambiguousSubstringMatchesNothing() {
        let t = Tree(outputs: [("d1", Rect(0, 0, 1000, 800)), ("d2", Rect(1000, 0, 1000, 800))])
        t.setOutputLabels(["d1": "DELL U2720Q left", "d2": "DELL U2720Q right"], primary: "d1")
        #expect(t.resolveOutput("dell") == nil)
        #expect(t.resolveOutput("right")?.name == "d2")
        #expect(t.resolveOutput("DELL U2720Q left")?.name == "d1")
    }
}

@Suite struct OutputCommands {
    @Test func moveWorkspaceToOutputByNameKeepsFocus() {
        let t = twoDisplays()
        t.addWindow(1)
        var errs: [String] = []
        t.run("move workspace to output ARZOPA", errors: &errs)
        #expect(errs.isEmpty)
        #expect(t.activeOutput.name == "display-2" && t.focusedWindowID == 1)
        #expect(t.computeLayout().frames[1] == Rect(1000, 0, 1000, 800))
    }

    @Test func moveWorkspaceToOutputByDirectionStillWorks() {
        let t = twoDisplays()
        t.addWindow(1)
        t.run("move workspace to output right")
        #expect(t.activeOutput.name == "display-2")
    }

    @Test func movedWorkspaceGetsAUniqueNameOnTheOutputItLeft() {
        let t = twoDisplays()
        t.run("move workspace to output right")               // the empty ws 1 leaves the left display
        let all = t.outputs.flatMap { $0.children.map { $0.name } }
        #expect(Set(all).count == all.count)
    }

    @Test func unknownOutputIsAnError() {
        let t = twoDisplays()
        var errs: [String] = []
        t.run("move workspace to output nosuch", errors: &errs)
        t.run("focus output nosuch", errors: &errs)
        #expect(errs.count == 2)
        #expect(t.workspace(named: "output") == nil)          // must not be mistaken for a workspace name
    }

    @Test func focusOutputByName() {
        let t = twoDisplays()
        t.addWindow(1)
        t.run("focus output ARZOPA")
        #expect(t.activeOutput.name == "display-2")
        t.run("focus output built-in")
        #expect(t.activeOutput.name == "display-1" && t.focusedWindowID == 1)
    }
}

@Suite struct DisplayChanges {
    @Test func assignedWorkspaceReturnsWhenItsDisplayReappears() {
        let t = twoDisplays()
        t.addWindow(1)
        t.setWorkspaceOutputs(["1": ["ARZOPA"]])
        let left = ("display-1", Rect(0, 0, 1000, 800)), right = ("display-2", Rect(1000, 0, 1000, 800))
        let labels = ["display-1": "Built-in Retina Display", "display-2": "ARZOPA"]
        t.updateOutputs([left], labels: labels, primary: "display-1")      // unplug ARZOPA
        #expect(t.outputs.count == 1 && t.allWindowIDs == [1])              // folded into the remaining display
        t.updateOutputs([left, right], labels: labels, primary: "display-1")  // plug it back in
        #expect(t.workspace(named: "1")?.output?.name == "display-2")
        #expect(t.computeLayout().frames[1] == Rect(1000, 0, 1000, 800))   // and it is showing again
    }
}


/// Three displays: primary in the middle, so numbering (primary first, then left to right) is visible.
func threeDisplays() -> Tree {
    let t = Tree(outputs: [("left", Rect(0, 0, 1000, 800)), ("middle", Rect(1000, 0, 1000, 800)), ("right", Rect(2000, 0, 1000, 800))])
    t.setOutputLabels([:], primary: "middle")
    return t
}

@Suite struct NumberedOutputs {
    @Test func oneIsThePrimaryThenTheOthersLeftToRight() {
        let t = threeDisplays()
        #expect(t.resolveOutput("1")?.name == "middle")
        #expect(t.resolveOutput("2")?.name == "left")
        #expect(t.resolveOutput("3")?.name == "right")
        #expect(t.resolveOutput("4") == nil && t.resolveOutput("0") == nil)
    }

    @Test func numbersAssignWorkspaces() {
        let t = twoDisplays()
        t.setWorkspaceOutputs(["1": ["1"], "2": ["2"]])       // 1 = Built-in (primary), 2 = ARZOPA
        #expect(t.workspace(named: "1")?.output?.name == "display-1")
        #expect(t.workspace(named: "2")?.output?.name == "display-2")
    }

    @Test func aMissingOutputFallsBackToThePrimary() {
        let t = Tree(outputs: [("display-1", Rect(0, 0, 1000, 800))])
        t.setOutputLabels([:], primary: "display-1")
        t.setWorkspaceOutputs(["2": ["2"], "9": ["7", "8"]])
        t.run("workspace 2"); t.addWindow(1)
        t.run("workspace 9"); t.addWindow(2)
        #expect(t.workspace(named: "2")?.output?.name == "display-1")
        #expect(t.workspace(named: "9")?.output?.name == "display-1")
    }

    @Test func anAssignedWorkspaceMovesAndShowsWhenItsDisplayIsPluggedIn() {
        let t = Tree(outputs: [("display-1", Rect(0, 0, 1000, 800))])
        t.setOutputLabels([:], primary: "display-1")
        t.setWorkspaceOutputs(["1": ["1"], "2": ["2"]])
        t.run("workspace 2"); t.addWindow(7)                  // ws 2 has a window; only one display, so it sits on the primary
        t.run("workspace 1")
        #expect(t.computeLayout().hidden == [7])
        t.updateOutputs([("display-1", Rect(0, 0, 1000, 800)), ("display-2", Rect(1000, 0, 1000, 800))])
        #expect(t.workspace(named: "2")?.output?.name == "display-2")
        #expect(t.computeLayout().frames[7] == Rect(1000, 0, 1000, 800))   // showing on the new display
        #expect(t.computeLayout().hidden.isEmpty)
    }

    @Test func aNumberWithoutADisplayFallsBackWhenTheDisplayIsUnplugged() {
        let t = twoDisplays()
        t.setWorkspaceOutputs(["2": ["2"]])
        t.run("focus output 2"); t.addWindow(5)               // ws 2 on display 2 with a window
        t.updateOutputs([("display-1", Rect(0, 0, 1000, 800))], labels: ["display-1": "Built-in Retina Display"], primary: "display-1")
        #expect(t.workspace(named: "2")?.output?.name == "display-1")
        t.updateOutputs([("display-1", Rect(0, 0, 1000, 800)), ("display-2", Rect(1000, 0, 1000, 800))],
                        labels: ["display-1": "Built-in Retina Display", "display-2": "ARZOPA"], primary: "display-1")
        #expect(t.workspace(named: "2")?.output?.name == "display-2")
        #expect(t.computeLayout().frames[5] == Rect(1000, 0, 1000, 800))
    }

    @Test func explicitCommandsAreStrictAboutMissingOutputs() {
        let t = Tree(outputs: [("display-1", Rect(0, 0, 1000, 800))])
        var errs: [String] = []
        t.run("move workspace to output 2", errors: &errs)
        t.run("focus output 2", errors: &errs)
        #expect(errs.count == 2)
    }

    @Test func commandsAcceptNumbers() {
        let t = twoDisplays()
        t.addWindow(1)
        t.run("move workspace to output 2")
        #expect(t.activeOutput.name == "display-2" && t.focusedWindowID == 1)
        t.run("focus output 1")
        #expect(t.activeOutput.name == "display-1")
    }
}
