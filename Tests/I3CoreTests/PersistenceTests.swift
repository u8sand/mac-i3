// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import Foundation
import Testing
@testable import I3Core

/// Builds a tree, snapshots it, discards it, and restores a fresh tree from just the snapshot + a live
/// window list — the same round trip a real `restart` performs.
func roundTrip(_ ids: [WindowID], appName: @escaping (WindowID) -> String? = { _ in "TestApp" },
              build: (Tree) -> Void = { _ in }) -> (saved: Tree, snap: TreeSnapshot, restored: Tree, live: [LiveWindow]) {
    let saved = makeTree(ids)
    build(saved)
    let snap = saved.snapshot(appName: appName)
    let live = ids.map { LiveWindow(id: $0, appName: appName($0) ?? "", title: saved.find($0)?.title ?? "") }
    let restored = Tree(outputs: [("main", Rect(0, 0, 1000, 800))])
    restored.restore(from: snap, live: live)
    return (saved, snap, restored, live)
}

@Suite struct SnapshotRoundTrip {
    @Test func plainWorkspaceRestoresExactly() {
        let (saved, _, restored, _) = roundTrip([1, 2, 3])
        #expect(restored.activeShape == saved.activeShape)
    }

    @Test func nestedSplitsRestoreExactly() {
        let (saved, _, restored, _) = roundTrip([1, 2, 3, 4]) { t in
            t.run("split v"); t.addWindow(3)
            t.run("split h"); t.addWindow(4)
        }
        #expect(saved.activeShape.contains("["))  // sanity: it's actually nested, not just a flat row
        #expect(restored.activeShape == saved.activeShape)
    }

    @Test func tabbedAndStackedLayoutsRestore() {
        let (saved, _, restored, _) = roundTrip([1, 2, 3]) { t in t.run("layout tabbed") }
        #expect(saved.activeShape == "T[1 2 3*]")
        #expect(restored.activeShape == saved.activeShape)
        let (saved2, _, restored2, _) = roundTrip([1, 2, 3]) { t in t.run("layout stacking") }
        #expect(restored2.activeShape == saved2.activeShape)
    }

    @Test func splitPercentagesSurvive() {
        let (saved, _, restored, _) = roundTrip([1, 2]) { t in
            t.innerGap = 0
            t.run("resize grow width 20 px or 20 ppt")
        }
        let before = saved.computeLayout().frames
        let after = restored.computeLayout().frames
        #expect(before[1]!.w == after[1]!.w && before[2]!.w == after[2]!.w)
    }

    @Test func floatingWindowsRestoreWithTheirFrame() {
        let (saved, _, restored, _) = roundTrip([1, 2]) { t in t.run("floating toggle") }
        #expect(saved.activeShape.contains("~2"))
        #expect(restored.activeShape == saved.activeShape)
        #expect(restored.computeLayout().frames[2] == saved.computeLayout().frames[2])
    }

    @Test func fullscreenStateRestores() {
        let (saved, _, restored, _) = roundTrip([1, 2]) { t in t.run("fullscreen") }
        #expect(restored.computeLayout().fullscreen == saved.computeLayout().fullscreen)
    }

    @Test func focusRestoresByWindowID() {
        let (saved, _, restored, _) = roundTrip([1, 2, 3]) { t in t.run("focus left") }
        #expect(saved.focusedWindowID == 2)
        #expect(restored.focusedWindowID == 2)
    }

    @Test func multipleWorkspacesAndOutputsRestore() {
        let saved = Tree(outputs: [("o1", Rect(0, 0, 1000, 800)), ("o2", Rect(1000, 0, 1000, 800))])
        saved.setOutputLabels(["o1": "Built-in", "o2": "Other"], primary: "o1")
        saved.addWindow(1)
        saved.run("focus right"); saved.addWindow(2)
        saved.run("workspace 5"); saved.addWindow(3)

        let snap = saved.snapshot()
        let live = [1, 2, 3].map { LiveWindow(id: $0, appName: "", title: saved.find($0)?.title ?? "") }
        let restored = Tree(outputs: [("o1", Rect(0, 0, 1000, 800)), ("o2", Rect(1000, 0, 1000, 800))])
        restored.setOutputLabels(["o1": "Built-in", "o2": "Other"], primary: "o1")
        restored.restore(from: snap, live: live)

        #expect(restored.shape(workspace: "1") == saved.shape(workspace: "1"))
        #expect(restored.shape(workspace: "2") == saved.shape(workspace: "2"))
        #expect(restored.shape(workspace: "5") == saved.shape(workspace: "5"))
        #expect(restored.workspace(named: "5")?.output?.name == "o2")
    }
}

@Suite struct SnapshotDegradesGracefully {
    @Test func aWindowThatIsGoneIsSilentlyDropped() {
        let (saved, snap, _, live) = roundTrip([1, 2, 3, 4]) { t in
            t.run("split v"); t.addWindow(3); t.run("split h"); t.addWindow(4)
        }
        _ = saved
        let liveMinusOne = live.filter { $0.id != 4 }   // 4 "closed" while mac-i3 was away
        let restored = Tree(outputs: [("main", Rect(0, 0, 1000, 800))])
        let (n, dropped) = restored.restore(from: snap, live: liveMinusOne)
        #expect(n == 3 && dropped == 0)   // "dropped" counts live windows left unmatched, not saved ones missing
        #expect(!restored.activeShape.contains("4"))
        #expect(restored.find(4) == nil)
    }

    @Test func aContainerWhoseOnlyWindowIsGoneVanishesEntirely() {
        let (_, snap, _, live) = roundTrip([1, 2]) { t in t.run("split v") }   // H[1 V[2*]]
        let liveMinusTwo = live.filter { $0.id != 1 }
        let restored = Tree(outputs: [("main", Rect(0, 0, 1000, 800))])
        restored.restore(from: snap, live: liveMinusTwo)
        // window 1 is gone; its lone-child split container must not survive as an empty husk
        #expect(restored.find(1) == nil)
        #expect(restored.find(2) != nil)
        #expect(violations(restored).isEmpty, "\(violations(restored)): \(restored.activeShape)")
    }

    @Test func extraLiveWindowsNotInTheSnapshotAreLeftForTheCaller() {
        let (_, snap, _, live) = roundTrip([1, 2])
        var liveWithExtra = live
        liveWithExtra.append(LiveWindow(id: 99, appName: "New", title: "brand new"))
        let restored = Tree(outputs: [("main", Rect(0, 0, 1000, 800))])
        let (n, dropped) = restored.restore(from: snap, live: liveWithExtra)
        #expect(n == 2 && dropped == 1)
        #expect(restored.find(99) == nil)   // left for the caller to add normally, restore() does not add it
    }

    @Test func emptySnapshotLeavesEverythingForTheCaller() {
        let restored = Tree(outputs: [("main", Rect(0, 0, 1000, 800))])
        let live = [LiveWindow(id: 1, appName: "A", title: "one")]
        let (n, dropped) = restored.restore(from: TreeSnapshot(), live: live)
        #expect(n == 0 && dropped == 1)
    }

    @Test func restoringIntoAnAlreadyPopulatedTreeStillHoldsInvariants() {
        // Not the intended usage (restore is meant to run once on an empty tree), but must not corrupt anything.
        let (_, snap, _, live) = roundTrip([1, 2, 3])
        let restored = makeTree([10, 11])
        restored.restore(from: snap, live: live)
        #expect(violations(restored).isEmpty)
    }
}

@Suite struct SnapshotFallbackMatching {
    @Test func fallsBackToAppAndTitleWhenTheWindowIDChanged() {
        let saved = makeTree([1, 2])
        saved.setTitle(1, "Terminal — zsh")
        let names: [WindowID: String] = [1: "Terminal", 2: "Terminal"]
        let snap = saved.snapshot(appName: { names[$0] })
        // mac-i3 was quit and Terminal relaunched: same app+title, a new window ID (500, not 1)
        let live = [LiveWindow(id: 500, appName: "Terminal", title: "Terminal — zsh"),
                    LiveWindow(id: 2, appName: "Terminal", title: saved.find(2)!.title)]
        let restored = Tree(outputs: [("main", Rect(0, 0, 1000, 800))])
        let (n, _) = restored.restore(from: snap, live: live)
        #expect(n == 2)
        #expect(restored.find(500) != nil)
        #expect(restored.activeShape == saved.activeShape.replacingOccurrences(of: "1", with: "500"))
    }

    @Test func ambiguousFallbackMatchesTakeWhicheverIsAvailableRatherThanDuplicating() {
        let saved = makeTree([1, 2])
        saved.setTitle(1, "Untitled"); saved.setTitle(2, "Untitled")
        let snap = saved.snapshot(appName: { _ in "Notes" })
        let live = [LiveWindow(id: 1, appName: "Notes", title: "Untitled"), LiveWindow(id: 2, appName: "Notes", title: "Untitled")]
        let restored = Tree(outputs: [("main", Rect(0, 0, 1000, 800))])
        let (n, dropped) = restored.restore(from: snap, live: live)
        #expect(n == 2 && dropped == 0)
        #expect(Set(restored.allWindowIDs) == [1, 2])   // each live window used exactly once, none duplicated
    }
}

@Suite struct SnapshotCodable {
    @Test func encodesAndDecodesLosslessly() throws {
        let saved = makeTree([1, 2, 3])
        saved.run("split v"); saved.addWindow(4)
        saved.run("layout tabbed")
        let snap = saved.snapshot(appName: { _ in "App" })
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(TreeSnapshot.self, from: data)
        #expect(decoded == snap)
    }
}

/// `reinsert`, unlike `restore`, runs against a tree that already has windows in it -- the mid-session
/// safety net for a window that turns up without the tree already knowing about it (a transient false
/// "gone" verdict, a display fold, anything), so it does not just get tiled into whatever workspace
/// happens to be focused right now.
@Suite struct Reinsertion {
    @Test func missingWindowReturnsToItsOwnWorkspaceNotTheFocusedOne() {
        let t = makeTree([1, 2])                 // workspace "1": H[1 2]
        t.run("workspace 2"); t.addWindow(3); t.addWindow(4)   // workspace "2": H[3 4]
        let snap = t.snapshot(appName: { _ in "App" })

        t.removeWindow(3)                         // "3" transiently looks gone
        t.run("workspace 1")                       // focus is on workspace "1" when it reappears
        #expect(t.workspace(named: "1")?.name != nil && t.find(3) == nil)

        let n = t.reinsert(from: snap, live: [LiveWindow(id: 3, appName: "App", title: "w3")])
        #expect(n == 1)
        #expect(t.find(3)?.workspace?.name == "2", "should return to workspace 2, not land on the focused workspace 1")
        #expect(t.workspace(named: "1")?.children.compactMap { $0.windowID } == [1, 2], "workspace 1 must be untouched")
    }

    @Test func siblingsAlreadyLiveAreLeftAlone() {
        let t = makeTree([1, 2, 3])               // H[1 2 3]
        let snap = t.snapshot(appName: { _ in "App" })
        t.removeWindow(2)
        #expect(t.activeShape == "H[1 3*]")

        let n = t.reinsert(from: snap, live: [LiveWindow(id: 2, appName: "App", title: "w2")])
        #expect(n == 1)
        #expect(Set(t.allWindowIDs) == [1, 2, 3])
        #expect(violations(t).isEmpty)
    }

    @Test func aWindowWithNoSavedPositionIsLeftForTheCallerToAddFresh() {
        let t = makeTree([1, 2])
        let snap = t.snapshot(appName: { _ in "App" })
        let n = t.reinsert(from: snap, live: [LiveWindow(id: 99, appName: "NewApp", title: "brand new")])
        #expect(n == 0)
        #expect(t.find(99) == nil)
        #expect(Set(t.allWindowIDs) == [1, 2], "must not fabricate an empty workspace for a window it could not match")
    }

    @Test func aWorkspaceThatWasEntirelyGoneIsRecreated() {
        let t = makeTree([1])                     // workspace "1": [1]
        t.run("workspace 2"); t.addWindow(2); t.addWindow(3)   // workspace "2": H[2 3]
        let snap = t.snapshot(appName: { _ in "App" })

        t.run("workspace 1")                       // move focus off "2" before emptying it
        t.removeWindow(2); t.removeWindow(3)        // workspace "2" had no other windows: it is pruned entirely
        #expect(t.workspace(named: "2") == nil)

        let n = t.reinsert(from: snap, live: [2, 3].map { LiveWindow(id: $0, appName: "App", title: "w\($0)") })
        #expect(n == 2)
        #expect(t.workspace(named: "2")?.children.compactMap { $0.windowID }.sorted() == [2, 3])
        #expect(violations(t).isEmpty)
    }

    @Test func aSpeculativelyCreatedWorkspaceIsUndoneWhenNothingActuallyMatches() {
        let t = makeTree([1])
        t.run("workspace 2"); t.addWindow(2)
        let snap = t.snapshot(appName: { _ in "App" })
        t.run("workspace 1")
        t.removeWindow(2)
        #expect(t.workspace(named: "2") == nil)

        // Nothing in `live` matches workspace 2's saved window -- it must not be left behind as a stray empty workspace.
        let n = t.reinsert(from: snap, live: [])
        #expect(n == 0)
        #expect(t.workspace(named: "2") == nil)
    }
}

@Suite struct SnapshotFuzz {
    @Test func randomTreesRoundTripWithoutCorruption() {
        for seed in UInt64(1)...200 {
            var rng = LCG(state: seed)
            let t = makeTree([])
            var next: WindowID = 1
            for _ in 0..<20 {
                if t.allWindowIDs.isEmpty || rng.chance(3) {
                    t.addWindow(next, title: "w\(next)", floating: rng.chance(6)); next += 1
                } else {
                    _ = t.run(rng.pick(["split h", "split v", "layout tabbed", "layout stacking", "layout toggle split",
                                        "focus left", "focus right", "move left", "move right", "fullscreen", "floating toggle"]))
                }
            }
            let snap = t.snapshot(appName: { _ in "App\(seed % 3)" })
            let live = t.allWindowIDs.map { LiveWindow(id: $0, appName: "App\(seed % 3)", title: t.find($0)?.title ?? "") }
            let restored = Tree(outputs: [("main", Rect(0, 0, 1000, 800))])
            let (n, dropped) = restored.restore(from: snap, live: live)
            #expect(n == live.count, "seed \(seed): expected all \(live.count) live windows matched, got \(n)")
            #expect(dropped == 0, "seed \(seed)")
            #expect(violations(restored).isEmpty, "seed \(seed): \(violations(restored))")
            #expect(Set(restored.allWindowIDs) == Set(t.allWindowIDs), "seed \(seed)")
        }
    }
}
