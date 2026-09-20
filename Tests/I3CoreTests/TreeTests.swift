import Testing
@testable import I3Core

/// One 1000x800 output, windows added like the OS reporting them one by one.
func makeTree(_ ids: [WindowID] = []) -> Tree {
    let t = Tree(outputs: [("main", Rect(0, 0, 1000, 800))])
    for id in ids { t.addWindow(id, title: "w\(id)") }
    return t
}

func frames(_ t: Tree) -> [WindowID: Rect] { t.computeLayout().frames }

@Suite struct OpeningWindows {
    @Test func windowsOpenNextToFocusedInWorkspaceOrientation() {
        let t = makeTree([1, 2, 3])
        #expect(t.activeShape == "H[1 2 3*]")
        let f = frames(t)
        #expect(f[1]!.w == 333 && f[2]!.w == 334 || f[1]!.w == 333)
        #expect(f[1]!.x == 0 && f[2]!.x == f[1]!.maxX && f[3]!.maxX == 1000)
    }

    @Test func newWindowGoesAfterFocusedNotAtEnd() {
        let t = makeTree([1, 2, 3])
        t.run("focus left"); t.run("focus left")
        t.addWindow(4)
        #expect(t.activeShape == "H[1 4* 2 3]")
    }

    @Test func splitVThenOpenStacksBelow() {
        let t = makeTree([1, 2])
        t.run("split v")
        t.addWindow(3)
        #expect(t.activeShape == "H[1 V[2 3*]]")
        let f = frames(t)
        #expect(f[1] == Rect(0, 0, 500, 800))
        #expect(f[2] == Rect(500, 0, 500, 400))
        #expect(f[3] == Rect(500, 400, 500, 400))
    }

    @Test func splitOnLoneWindowJustFlipsWorkspaceOrientation() {
        let t = makeTree([1])
        t.run("split v")
        t.addWindow(2)
        #expect(t.activeShape == "V[1 2*]")
    }

    @Test func nestedSplits() {
        let t = makeTree([1, 2])
        t.run("split v"); t.addWindow(3)
        t.run("split h"); t.addWindow(4)
        #expect(t.activeShape == "H[1 V[2 H[3 4*]]]")
        let f = frames(t)
        #expect(f[3] == Rect(500, 400, 250, 400))
        #expect(f[4] == Rect(750, 400, 250, 400))
    }

    @Test func closingCollapsesEmptyContainersButKeepsSingleChildOnes() {
        let t = makeTree([1, 2])
        t.run("split v"); t.addWindow(3)
        t.removeWindow(2)
        #expect(t.activeShape == "H[1 V[3*]]")
        t.removeWindow(3)
        #expect(t.activeShape == "H[1*]")
    }

    @Test func focusFallsBackToMostRecentlyFocused() {
        let t = makeTree([1, 2, 3])
        t.run("focus left")            // 2
        t.run("focus right")           // 3
        t.removeWindow(3)
        #expect(t.focusedWindowID == 2)
    }
}

@Suite struct Focusing {
    @Test func directionalFocusAcrossNesting() {
        let t = makeTree([1, 2])
        t.run("split v"); t.addWindow(3)                       // H[1 V[2 3*]]
        t.run("focus up");    #expect(t.focusedWindowID == 2)
        t.run("focus left");  #expect(t.focusedWindowID == 1)
        t.run("focus right"); #expect(t.focusedWindowID == 2)  // last focused in V
        t.run("focus down");  #expect(t.focusedWindowID == 3)
    }

    @Test func focusWrapsAtOutermostEdge() {
        let t = makeTree([1, 2, 3])
        t.run("focus right")
        #expect(t.focusedWindowID == 1)
        t.run("focus left")
        #expect(t.focusedWindowID == 3)
    }

    @Test func focusUpDownDoesNothingWhenNoVerticalAncestor() {
        let t = makeTree([1, 2])
        t.run("focus down")
        #expect(t.focusedWindowID == 2)
    }

    @Test func focusParentAndChild() {
        let t = makeTree([1, 2])
        t.run("split v"); t.addWindow(3)
        t.run("focus parent")
        #expect(!t.focused.isWindow)
        #expect(t.activeShape == "H[1 V[2 3]*]")
        t.run("focus left")
        #expect(t.focusedWindowID == 1)
        t.run("focus right")
        #expect(t.focusedWindowID == 3)
        t.run("focus parent"); t.run("focus child")
        #expect(t.focusedWindowID == 3)
    }

    @Test func newWindowOpensNextToFocusedContainer() {
        let t = makeTree([1, 2])
        t.run("split v"); t.addWindow(3)
        t.run("focus parent")
        t.addWindow(4)
        #expect(t.activeShape == "H[1 V[2 3] 4*]")
    }

    @Test func focusParentSplitThenOpenPutsWindowBesideGroup() {
        let t = makeTree([1, 2])
        t.run("split v"); t.addWindow(3)               // H[1 V[2 3*]]
        t.run("focus parent"); t.run("split h")         // wrap the group
        t.addWindow(4)
        #expect(t.activeShape == "H[1 H[V[2 3] 4*]]")
    }

    @Test func focusInTabbedCyclesTabs() {
        let t = makeTree([1, 2, 3])
        t.run("layout tabbed")
        #expect(t.activeShape == "T[1 2 3*]")
        t.run("focus left");  #expect(t.focusedWindowID == 2)
        t.run("focus left");  #expect(t.focusedWindowID == 1)
    }
}

@Suite struct Moving {
    @Test func moveSwapsWithSibling() {
        let t = makeTree([1, 2, 3])
        t.run("move left");  #expect(t.activeShape == "H[1 3* 2]")
        t.run("move left");  #expect(t.activeShape == "H[3* 1 2]")
        t.run("move left");  #expect(t.activeShape == "H[3* 1 2]")   // edge: nothing
        t.run("move right"); #expect(t.activeShape == "H[1 3* 2]")
    }

    @Test func moveAcrossOrientationFlipsWorkspace() {
        let t = makeTree([1, 2])
        t.run("move down")
        #expect(t.activeShape == "V[H[1] 2*]")
        let f = frames(t)
        #expect(f[1] == Rect(0, 0, 1000, 400))
        #expect(f[2] == Rect(0, 400, 1000, 400))
        t.run("move up")
        #expect(t.activeShape == "V[H[1 2*]]")
        let g = frames(t)
        #expect(g[1] == Rect(0, 0, 500, 800))
        #expect(g[2] == Rect(500, 0, 500, 800))
    }

    @Test func moveOutOfPerpendicularContainer() {
        let t = makeTree([1, 2])
        t.run("split v"); t.addWindow(3)               // H[1 V[2 3*]]
        t.run("move right")
        #expect(t.activeShape == "H[1 V[2] 3*]")
        t.run("move left")                              // swap with V[2]? goes into it
        #expect(t.focusedWindowID == 3)
    }

    @Test func moveIntoNeighbouringContainer() {
        let t = makeTree([1, 2])
        t.run("split v"); t.addWindow(3)               // H[1 V[2 3*]]
        t.run("focus left")
        t.run("move right")
        #expect(t.activeShape == "H[V[2 1* 3]]")
    }

    @Test func moveInsideTabbedReordersTabs() {
        let t = makeTree([1, 2, 3])
        t.run("layout tabbed")
        t.run("move left")
        #expect(t.activeShape == "T[1 3* 2]")
    }

    @Test func moveSingleWindowIsNoop() {
        let t = makeTree([1])
        t.run("move left"); t.run("move up")
        #expect(t.activeShape == "H[1*]")
    }
}

@Suite struct Layouts {
    @Test func tabbedShowsOnlyActiveBelowBar() {
        let t = makeTree([1, 2, 3])
        t.run("layout tabbed")
        let r = t.computeLayout()
        #expect(r.frames.count == 1)
        #expect(r.frames[3] == Rect(0, 22, 1000, 778))
        #expect(r.hidden == [1, 2])
        #expect(r.bars.count == 1 && r.bars[0].tabs.count == 3 && !r.bars[0].vertical)
    }

    @Test func stackedReservesOneRowPerWindow() {
        let t = makeTree([1, 2, 3])
        t.run("layout stacking")
        let r = t.computeLayout()
        #expect(r.frames[3] == Rect(0, 66, 1000, 734))
        #expect(r.bars[0].vertical)
    }

    @Test func toggleSplitFlipsAndRestoresFromTabs() {
        let t = makeTree([1, 2])
        t.run("layout toggle split"); #expect(t.activeShape == "V[1 2*]")
        t.run("layout toggle split"); #expect(t.activeShape == "H[1 2*]")
        t.run("layout tabbed");       #expect(t.activeShape == "T[1 2*]")
        t.run("layout toggle split"); #expect(t.activeShape == "H[1 2*]")
    }

    @Test func layoutAppliesToParentOfFocused() {
        let t = makeTree([1, 2])
        t.run("split v"); t.addWindow(3)               // H[1 V[2 3*]]
        t.run("layout tabbed")
        #expect(t.activeShape == "H[1 T[2 3*]]")
        t.run("focus parent"); t.run("layout stacking")   // parent of focused (= the workspace)
        #expect(t.activeShape == "S[1 T[2 3]*]")
    }

    @Test func fullscreenCoversOutput() {
        let t = makeTree([1, 2])
        t.run("fullscreen")
        let r = t.computeLayout()
        #expect(r.frames[2] == Rect(0, 0, 1000, 800))
        #expect(r.fullscreen == 2)
        t.run("fullscreen")
        #expect(t.computeLayout().fullscreen == nil)
    }

    @Test func gapsShrinkInnerEdges() {
        let t = makeTree([1, 2])
        t.innerGap = 10
        let f = frames(t)
        #expect(f[1] == Rect(0, 0, 495, 800))
        #expect(f[2] == Rect(505, 0, 495, 800))
    }
}

@Suite struct Resizing {
    @Test func growShrinkWidthMovesBoundary() {
        let t = makeTree([1, 2])
        t.run("resize grow width 10 px or 10 ppt")
        var f = frames(t)
        #expect(f[1]!.w == 400 && f[2]!.w == 600)
        t.run("resize shrink width 10 px or 10 ppt")
        f = frames(t)
        #expect(f[1]!.w == 500)
    }

    @Test func resizeHeightIgnoresHorizontalOnlyLayout() {
        let t = makeTree([1, 2])
        t.run("resize grow height 10 px or 10 ppt")
        let f = frames(t)
        #expect(f[1]!.w == 500)
    }

    @Test func resizeRefusesToCollapseNeighbour() {
        let t = makeTree([1, 2])
        for _ in 0..<20 { t.run("resize grow width 10 px or 10 ppt") }
        let f = frames(t)
        #expect(f[1]!.w >= 50)
    }
}

@Suite struct Workspaces {
    @Test func switchHideAndRestore() {
        let t = makeTree([1, 2])
        t.run("workspace 2")
        t.addWindow(3)
        #expect(t.shape(workspace: "2") == "H[3*]")
        var r = t.computeLayout()
        #expect(r.hidden == [1, 2] && r.frames.keys.sorted() == [3])
        t.run("workspace 1")
        r = t.computeLayout()
        #expect(r.hidden == [3] && r.frames.keys.sorted() == [1, 2])
        #expect(t.focusedWindowID == 2)
    }

    @Test func moveContainerToWorkspaceKeepsFocusBehind() {
        let t = makeTree([1, 2, 3])
        t.run("move container to workspace 4")
        #expect(t.shape(workspace: "1") == "H[1 2*]")
        #expect(t.shape(workspace: "4") == "H[3]")
        #expect(t.computeLayout().hidden == [3])
        t.run("workspace 4")
        #expect(t.focusedWindowID == 3)
    }

    @Test func emptyWorkspacesDisappear() {
        let t = makeTree([1])
        t.run("workspace 5")
        #expect(t.workspace(named: "5") != nil)
        t.run("workspace 1")
        #expect(t.workspace(named: "5") == nil)
    }

    @Test func backAndForthAndNext() {
        let t = makeTree([1])
        t.run("workspace 2"); t.addWindow(2)
        t.run("workspace back_and_forth")
        #expect(t.activeWorkspace.name == "1")
        t.run("workspace next")
        #expect(t.activeWorkspace.name == "2")
    }

    @Test func osFocusEventSwitchesWorkspace() {
        let t = makeTree([1])
        t.run("workspace 2"); t.addWindow(2)
        t.run("workspace 1")
        t.focusWindow(2)
        #expect(t.activeWorkspace.name == "2")
    }
}

@Suite struct Floating {
    @Test func toggleFloatingRoundTrip() {
        let t = makeTree([1, 2])
        _ = frames(t)
        t.run("floating toggle")
        #expect(t.activeShape == "H[1 ~2*]")
        let r = t.computeLayout()
        #expect(r.floating == [2])
        #expect(r.frames[1] == Rect(0, 0, 1000, 800))
        t.run("floating toggle")
        #expect(t.activeShape == "H[1 2*]")
    }

    @Test func focusModeToggleJumpsBetweenTilingAndFloating() {
        let t = makeTree([1, 2])
        t.run("floating toggle")
        t.run("focus mode_toggle")
        #expect(t.focusedWindowID == 1)
        t.run("focus mode_toggle")
        #expect(t.focusedWindowID == 2)
    }
}

@Suite struct Commands {
    @Test func killReturnsAction() {
        let t = makeTree([1, 2])
        #expect(t.run("kill") == [.kill(2)])
    }

    @Test func chainedAndQuotedCommands() {
        let t = makeTree([1, 2])
        let a = t.run("split v; exec open -a Terminal ~; mode \"resize\"")
        #expect(a == [.exec("open -a Terminal ~"), .mode("resize")])
    }

    @Test func unknownCommandsAreReported() {
        let t = makeTree([1])
        var errs: [String] = []
        t.run("frobnicate now", errors: &errs)
        #expect(errs.count == 1)
    }
}

@Suite struct MultiMonitor {
    func twoOutputs() -> Tree {
        Tree(outputs: [("left", Rect(0, 0, 1000, 800)), ("right", Rect(1000, 0, 1000, 800))])
    }

    @Test func eachOutputStartsWithOwnWorkspace() {
        let t = twoOutputs()
        #expect(t.outputs.map { t.currentWorkspace(of: $0).name } == ["1", "2"])
    }

    @Test func focusCrossesToNeighbouringOutputAtEdge() {
        let t = twoOutputs()
        t.addWindow(1)
        t.run("focus right")
        #expect(t.activeOutput.name == "right")
        t.addWindow(2)
        t.run("focus left")
        #expect(t.focusedWindowID == 1)
        t.run("focus left")                      // nothing further: wrap in single window = stay
        #expect(t.focusedWindowID == 1)
    }

    @Test func moveAtEdgeSendsWindowToOtherOutput() {
        let t = twoOutputs()
        t.addWindow(1); t.addWindow(2)
        t.run("move right")                       // 2 is last: crosses
        #expect(t.activeOutput.name == "right")
        #expect(t.shape(workspace: "2") == "H[2*]")
        let f = frames(t)
        #expect(f[2] == Rect(1000, 0, 1000, 800))
        #expect(f[1] == Rect(0, 0, 1000, 800))
    }

    @Test func removedOutputFoldsWorkspacesIntoRemaining() {
        let t = twoOutputs()
        t.addWindow(1)
        t.run("focus right"); t.addWindow(2)
        t.updateOutputs([("left", Rect(0, 0, 1000, 800))])
        #expect(t.outputs.count == 1)
        #expect(Set(t.allWindowIDs) == [1, 2])
        #expect(frames(t).count == 1)              // only the visible workspace is laid out
    }
}
