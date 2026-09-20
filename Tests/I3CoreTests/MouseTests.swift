import Testing
@testable import I3Core

@Suite struct DropZones {
    let r = Rect(0, 0, 1000, 800)

    @Test func edgesSelectSides() {
        #expect(DropZone.at(x: 10, y: 400, in: r) == .left)
        #expect(DropZone.at(x: 990, y: 400, in: r) == .right)
        #expect(DropZone.at(x: 500, y: 10, in: r) == .top)
        #expect(DropZone.at(x: 500, y: 790, in: r) == .bottom)
    }

    @Test func middleIsCenterAndBandIsAQuarter() {
        #expect(DropZone.at(x: 500, y: 400, in: r) == .center)
        #expect(DropZone.at(x: 240, y: 400, in: r) == .left)
        #expect(DropZone.at(x: 260, y: 400, in: r) == .center)
    }

    @Test func cornersGoToTheNearerEdge() {
        #expect(DropZone.at(x: 10, y: 5, in: r) == .top)
        #expect(DropZone.at(x: 5, y: 300, in: r) == .left)
    }

    @Test func zonesAreRelativeToTheWindow() {
        let w = Rect(1000, 100, 400, 300)
        #expect(DropZone.at(x: 1005, y: 250, in: w) == .left)
        #expect(DropZone.at(x: 1200, y: 250, in: w) == .center)
    }

    @Test func previewCoversTheTargetHalf() {
        #expect(DropZone.left.preview(in: r) == Rect(0, 0, 500, 800))
        #expect(DropZone.right.preview(in: r) == Rect(500, 0, 500, 800))
        #expect(DropZone.top.preview(in: r) == Rect(0, 0, 1000, 400))
        #expect(DropZone.bottom.preview(in: r) == Rect(0, 400, 1000, 400))
        #expect(DropZone.center.preview(in: r) == r)
    }
}

@Suite struct HitTesting {
    @Test func findsTiledWindowUnderPoint() {
        let t = makeTree([1, 2])
        #expect(t.windowAt(x: 100, y: 100)?.id == 1)
        #expect(t.windowAt(x: 900, y: 100)?.id == 2)
        #expect(t.windowAt(x: 900, y: 100)?.rect == Rect(500, 0, 500, 800))
    }

    @Test func excludesTheDraggedWindow() {
        let t = makeTree([1, 2])
        #expect(t.windowAt(x: 100, y: 100, excluding: 1) == nil)
    }

    @Test func floatingWindowsBlockTiledOnesUnderThem() {
        let t = makeTree([1, 2])
        t.addWindow(3, floating: true, rect: Rect(0, 0, 300, 300))
        #expect(t.windowAt(x: 100, y: 100) == nil)
        #expect(t.windowAt(x: 400, y: 400)?.id == 1)
    }

    @Test func outsideEveryWindowIsNil() {
        let t = makeTree([1])
        #expect(t.windowAt(x: 5000, y: 5000) == nil)
        #expect(t.outputAt(x: 5000, y: 5000) == nil)
        #expect(t.outputAt(x: 10, y: 10)?.name == "main")
    }
}

@Suite struct DragResize {
    func laidOut(_ ids: [WindowID]) -> Tree { let t = makeTree(ids); _ = t.computeLayout(); return t }

    @Test func draggingRightEdgeMovesBoundary() {
        let t = laidOut([1, 2])
        t.resizeByEdges(1, right: 100)
        let f = frames(t)
        #expect(f[1]!.w == 600 && f[2]!.x == 600 && f[2]!.w == 400)
    }

    @Test func draggingTheNeighboursLeftEdgeMovesTheSameBoundary() {
        let t = laidOut([1, 2])
        t.resizeByEdges(2, left: 100)
        let f = frames(t)
        #expect(f[1]!.w == 400 && f[2]!.w == 600)
    }

    @Test func draggingInwardShrinks() {
        let t = laidOut([1, 2])
        t.resizeByEdges(1, right: -100)
        #expect(frames(t)[1]!.w == 400)
    }

    @Test func screenBorderEdgesAreIgnored() {
        let t = laidOut([1, 2])
        t.resizeByEdges(1, left: 100)
        t.resizeByEdges(2, right: 100)
        #expect(frames(t)[1]!.w == 500)
    }

    @Test func tinyMovementsAreJitter() {
        let t = laidOut([1, 2])
        t.resizeByEdges(1, right: 3)
        #expect(frames(t)[1]!.w == 500)
    }

    @Test func neighbourKeepsAMinimumShare() {
        let t = laidOut([1, 2])
        t.resizeByEdges(1, right: 10_000)
        let f = frames(t)
        #expect(f[2]!.w >= 49 && f[1]!.w <= 951)
        t.resizeByEdges(1, right: -10_000)
        #expect(frames(t)[1]!.w >= 49)
    }

    @Test func nestedVerticalBoundary() {
        let t = laidOut([1, 2])
        t.run("split v"); t.addWindow(3)                 // H[1 V[2 3]]
        _ = t.computeLayout()
        t.resizeByEdges(3, top: 100)
        let f = frames(t)
        #expect(f[2]!.h == 300 && f[3]!.h == 500 && f[3]!.y == 300)
        #expect(f[1]!.w == 500)
    }

    @Test func nestedWindowsSideEdgeMovesTheOuterBoundary() {
        let t = laidOut([1, 2])
        t.run("split v"); t.addWindow(3)                 // H[1 V[2 3]]
        _ = t.computeLayout()
        t.resizeByEdges(3, left: 100)                    // no horizontal neighbour inside the V column
        let f = frames(t)
        #expect(f[1]!.w == 400 && f[2]!.w == 600 && f[3]!.w == 600)
    }

    @Test func cornerDragMovesBothAxes() {
        let t = laidOut([1, 2])
        t.run("split v"); t.addWindow(3)
        _ = t.computeLayout()
        t.resizeByEdges(2, left: 100, bottom: 100)
        let f = frames(t)
        #expect(f[1]!.w == 400 && f[2]!.h == 500 && f[3]!.h == 300)
    }

    @Test func tabbedContainersAreNotResizable() {
        let t = laidOut([1, 2, 3])
        t.run("layout tabbed")
        _ = t.computeLayout()
        t.resizeByEdges(3, left: 100)
        #expect(t.activeShape == "T[1 2 3*]")
        #expect(frames(t)[3]!.w == 1000)
    }

    @Test func floatingWindowsAreIgnored() {
        let t = laidOut([1, 2])
        t.run("floating toggle")
        t.resizeByEdges(2, left: 100)
        #expect(frames(t)[1]!.w == 1000)
    }
}

@Suite struct DragMove {
    @Test func dropOnRightEdgeOfSameOrientationInserts() {
        let t = makeTree([1, 2, 3])
        t.dropWindow(1, onto: 3, zone: .right)
        #expect(t.activeShape == "H[2 3 1*]")
    }

    @Test func dropOnLeftEdge() {
        let t = makeTree([1, 2, 3])
        t.dropWindow(3, onto: 1, zone: .left)
        #expect(t.activeShape == "H[3* 1 2]")
    }

    @Test func dropInTheMiddleSwaps() {
        let t = makeTree([1, 2, 3])
        t.dropWindow(1, onto: 3, zone: .center)
        #expect(t.activeShape == "H[3 2 1*]")
    }

    @Test func swapKeepsEachSlotsSize() {
        let t = makeTree([1, 2])
        _ = t.computeLayout()
        t.resizeByEdges(1, right: 100)                    // 600 | 400
        t.dropWindow(1, onto: 2, zone: .center)
        let f = frames(t)
        #expect(f[2]!.w == 600 && f[1]!.w == 400)
    }

    @Test func dropOnTopSplitsTheTargetsSlot() {
        let t = makeTree([1, 2])
        t.dropWindow(1, onto: 2, zone: .top)
        #expect(t.activeShape == "H[V[1* 2]]")
        let f = frames(t)
        #expect(f[1] == Rect(0, 0, 1000, 400) && f[2] == Rect(0, 400, 1000, 400))
    }

    @Test func dropOnBottomOfFirstOfThree() {
        let t = makeTree([1, 2, 3])
        t.dropWindow(3, onto: 1, zone: .bottom)
        #expect(t.activeShape == "H[V[1 3*] 2]")
    }

    @Test func dropBesideAWindowInsideAPerpendicularContainer() {
        let t = makeTree([1, 2])
        t.run("split v"); t.addWindow(3)                  // H[1 V[2 3*]]
        t.dropWindow(1, onto: 3, zone: .right)
        #expect(t.activeShape == "H[V[2 H[3 1*]]]")
    }

    @Test func dropIntoTabbedContainerAddsATab() {
        let t = makeTree([1, 2, 3])
        t.run("layout tabbed")                            // T[1 2 3]
        t.run("focus left")
        t.dropWindow(3, onto: 1, zone: .right)
        #expect(t.activeShape == "T[1 3* 2]")
    }

    @Test func dropOntoSelfOrFloatingOrUnknownDoesNothing() {
        let t = makeTree([1, 2])
        t.addWindow(3, floating: true)
        t.dropWindow(1, onto: 1, zone: .right)
        t.dropWindow(1, onto: 3, zone: .right)
        t.dropWindow(1, onto: 99, zone: .right)
        t.dropWindow(3, onto: 1, zone: .right)
        #expect(t.activeShape == "H[1 2 ~3*]")
    }

    @Test func draggedWindowGetsFocus() {
        let t = makeTree([1, 2, 3])
        t.dropWindow(1, onto: 3, zone: .right)
        #expect(t.focusedWindowID == 1)
    }

    @Test func dropBetweenOutputsMovesTheWindow() {
        let t = Tree(outputs: [("left", Rect(0, 0, 1000, 800)), ("right", Rect(1000, 0, 1000, 800))])
        t.addWindow(1); t.run("focus right"); t.addWindow(2)
        t.dropWindow(1, onto: 2, zone: .right)
        #expect(t.shape(workspace: "2") == "H[2 1*]")
        #expect(t.activeOutput.name == "right")
        #expect(t.computeLayout().frames[1]!.x >= 1000)
    }

    @Test func swapAcrossOutputs() {
        let t = Tree(outputs: [("left", Rect(0, 0, 1000, 800)), ("right", Rect(1000, 0, 1000, 800))])
        t.addWindow(1); t.run("focus right"); t.addWindow(2)
        t.dropWindow(1, onto: 2, zone: .center)
        #expect(t.shape(workspace: "1") == "H[2]")
        #expect(t.shape(workspace: "2") == "H[1*]")
    }

    @Test func dropOnEmptyOutputMovesWindowThere() {
        let t = Tree(outputs: [("left", Rect(0, 0, 1000, 800)), ("right", Rect(1000, 0, 1000, 800))])
        t.addWindow(1); t.addWindow(2)
        t.dropWindow(2, onOutput: "right")
        #expect(t.shape(workspace: "1") == "H[1]")
        #expect(t.shape(workspace: "2") == "H[2*]")
        #expect(t.activeOutput.name == "right")
    }

    @Test func dropOnOwnOutputDoesNothing() {
        let t = makeTree([1, 2])
        t.dropWindow(2, onOutput: "main")
        #expect(t.activeShape == "H[1 2*]")
    }
}

@Suite struct GrabAndEdges {
    let f = Rect(100, 100, 400, 300)

    @Test func titleBarAndContentAreInterior() {
        #expect(Grab.at(x: 300, y: 112, in: f) == .interior)
        #expect(Grab.at(x: 300, y: 250, in: f) == .interior)
    }

    @Test func edgesAndJustOutsideAreBorder() {
        #expect(Grab.at(x: 499, y: 250, in: f) == .border)     // 1px inside the right edge
        #expect(Grab.at(x: 503, y: 250, in: f) == .border)     // 3px outside it
        #expect(Grab.at(x: 300, y: 101, in: f) == .border)
        #expect(Grab.at(x: 96, y: 96, in: f) == .border)       // corner handle
    }

    @Test func farAwayIsOutside() {
        #expect(Grab.at(x: 600, y: 250, in: f) == .outside)
        #expect(Grab.at(x: 300, y: 50, in: f) == .outside)
    }

    @Test func oneEdgeDragged() {
        let d = EdgeDeltas(from: f, to: Rect(100, 100, 550, 300))
        #expect(d == EdgeDeltas(left: 0, right: 150, top: 0, bottom: 0))
    }

    @Test func leftEdgeDraggedLeftGrowsOutward() {
        let d = EdgeDeltas(from: f, to: Rect(40, 100, 460, 300))
        #expect(d == EdgeDeltas(left: 60, right: 0, top: 0, bottom: 0))
    }

    @Test func cornerDragMovesTwoEdges() {
        let d = EdgeDeltas(from: f, to: Rect(100, 100, 450, 380))
        #expect(d == EdgeDeltas(left: 0, right: 50, top: 0, bottom: 80))
    }

    /// A window dropped fully onto a smaller display is moved *and* shrunk by macOS. That must not be
    /// mistaken for a resize with a ~2000px edge delta.
    @Test func movedAndClampedWindowIsNotAResize() {
        let d = EdgeDeltas(from: Rect(900, 39, 900, 1130), to: Rect(2310, 0, 900, 1080))
        #expect(d.left == 0 && d.right == 0)                      // horizontal: a pure translation
        #expect(d.top == 0 && d.bottom == 0)                      // vertical: moved 39 up and shrunk 50: both edges moved
    }

    @Test func symmetricResizeKeepsBothEdges() {
        let d = EdgeDeltas(from: f, to: Rect(50, 100, 500, 300))    // both sides outward by 50
        #expect(d.left == 50 && d.right == 50)
    }
}
