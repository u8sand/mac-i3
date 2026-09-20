import Testing
@testable import I3Core

@Suite struct WorkspaceBarSummary {
    @Test func listsWorkspacesWithWindowsAndMarksShowingAndFocus() {
        let t = makeTree([1, 2])
        t.run("workspace 3"); t.addWindow(3)
        let s = t.barSummary()
        #expect(s.outputs.count == 1)
        let ws = s.outputs[0].workspaces
        #expect(ws.map { $0.name } == ["1", "3"])
        #expect(ws[0].windows == [1, 2] && !ws[0].showing && !ws[0].focused)
        #expect(ws[1].windows == [3] && ws[1].showing && ws[1].focused)
    }

    @Test func showingButEmptyWorkspaceIsListed() {
        let t = makeTree([1])
        t.run("workspace 4")                                   // empty, but it is the one showing
        let ws = t.barSummary().outputs[0].workspaces
        #expect(ws.map { $0.name } == ["1", "4"])
        #expect(ws[1].showing && ws[1].windows.isEmpty)
    }

    @Test func emptyHiddenWorkspacesAreLeftOut() {
        let t = makeTree([1])
        t.run("workspace 5"); t.run("workspace 1")             // 5 was empty and is no longer showing: pruned
        #expect(t.barSummary().outputs[0].workspaces.map { $0.name } == ["1"])
    }

    @Test func workspacesAreSortedNumerically() {
        let t = makeTree([1])
        for n in [10, 2, 7] { t.run("workspace \(n)"); t.addWindow(WindowID(100 + n)) }
        #expect(t.barSummary().outputs[0].workspaces.map { $0.name } == ["1", "2", "7", "10"])
    }

    @Test func floatingWindowsCount() {
        let t = makeTree([1])
        t.addWindow(2, floating: true)
        #expect(t.barSummary().outputs[0].workspaces[0].windows.sorted() == [1, 2])
    }

    @Test func groupedByDisplayPrimaryFirst() {
        let t = threeDisplays()                                // primary is the middle one
        let s = t.barSummary()
        #expect(s.outputs.map { $0.name } == ["middle", "left", "right"])
        #expect(s.outputs.map { $0.number } == [1, 2, 3])
    }

    @Test func eachDisplayHasItsOwnShowingWorkspaceAndFocusIsUnique() {
        let t = twoDisplays()
        t.addWindow(1); t.run("focus output ARZOPA"); t.addWindow(2)
        let s = t.barSummary()
        #expect(s.outputs[0].workspaces.first { $0.showing }?.name == "1")
        #expect(s.outputs[1].workspaces.first { $0.showing }?.name == "2")
        let focused = s.outputs.flatMap { $0.workspaces }.filter { $0.focused }
        #expect(focused.count == 1 && focused[0].name == "2")
    }

    @Test func assignedWorkspacesAppearUnderTheirDisplay() {
        let t = twoDisplays()
        t.setWorkspaceOutputs(["7": ["2"]])
        t.run("workspace 7"); t.addWindow(9)
        let s = t.barSummary()
        #expect(s.outputs[1].workspaces.contains { $0.name == "7" && $0.windows == [9] })
        #expect(!s.outputs[0].workspaces.contains { $0.name == "7" })
    }

    @Test func modeAndEquality() {
        let t = makeTree([1])
        #expect(t.barSummary(mode: "resize").mode == "resize")
        #expect(t.barSummary() == t.barSummary())
        let before = t.barSummary()
        t.addWindow(2)
        #expect(t.barSummary() != before)                      // a window came: the bar must redraw
    }
}
