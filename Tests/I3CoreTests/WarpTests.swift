import Testing
@testable import I3Core

@Suite struct MouseWarping {
    let win = Rect(1000, 100, 800, 600)          // centre (1400, 400)

    func dest(_ mode: WarpMode, focus: Bool = true, frame: Bool = false, output: Bool = false,
              cursor: (Double, Double) = (50, 50)) -> (x: Double, y: Double)? {
        warpDestination(mode: mode, focusChanged: focus, frameChanged: frame, outputChanged: output,
                        cursor: (x: cursor.0, y: cursor.1), target: win)
    }

    @Test func noneNeverMoves() {
        #expect(dest(.none, output: true) == nil)
    }

    @Test func centreAlwaysGoesToTheMiddleWhenFocusMoved() {
        #expect(dest(.center)?.x == 1400 && dest(.center)?.y == 400)
        #expect(dest(.center, cursor: (1401, 401))?.x == 1400)          // even if already inside
    }

    @Test func windowModeLeavesACursorThatIsAlreadyOverTheWindow() {
        #expect(dest(.window, cursor: (1100, 150)) == nil)
        #expect(dest(.window)?.x == 1400)                                // cursor elsewhere: go to the centre
    }

    @Test func windowModeFollowsAMovedWindow() {
        // focus stayed, the window moved out from under the cursor
        #expect(dest(.window, focus: false, frame: true)?.y == 400)
    }

    @Test func commandsThatChangeNothingNeverMoveTheCursor() {
        #expect(dest(.window, focus: false) == nil)
        #expect(dest(.center, focus: false) == nil)
    }

    @Test func outputModeOnlyActsWhenTheDisplayChanges() {
        #expect(dest(.output) == nil)
        #expect(dest(.output, output: true)?.x == 1400)
    }

    @Test func emptyWorkspaceUsesTheOutputArea() {
        let out = Rect(1800, 0, 1920, 1080)
        let d = warpDestination(mode: .window, focusChanged: true, frameChanged: false, outputChanged: true,
                                cursor: (x: 100, y: 100), target: out)
        #expect(d?.x == 2760 && d?.y == 540)
    }
}
