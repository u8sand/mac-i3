import Foundation
import Testing
@testable import I3Core

/// Small deterministic RNG so failures are reproducible from the seed.
struct LCG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
    mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
    mutating func chance(_ n: Int) -> Bool { next() % UInt64(n) == 0 }
}

/// Structural invariants that must hold after any sequence of operations.
func violations(_ t: Tree) -> [String] {
    var out: [String] = []
    var seen = Set<WindowID>()

    func walk(_ c: Con) {
        let kids = c.children + c.floating
        let kidIDs = Set(kids.map { ObjectIdentifier($0) })
        if !c.isWindow {
            if kidIDs.count != kids.count { out.append("duplicate child in \(c.kind)") }
            if Set(c.focusOrder.map { ObjectIdentifier($0) }) != kidIDs || c.focusOrder.count != kids.count {
                out.append("focusOrder != children in \(c.kind) \(c.name) \(t.shape(c))")
            }
            if c.kind == .split && kids.isEmpty { out.append("empty split container") }
            if c.kind == .split && c.children.isEmpty && !c.floating.isEmpty { out.append("split with only floating") }
            if !c.children.isEmpty && (c.kind == .split || c.kind == .workspace) {
                let sum = c.children.reduce(0) { $0 + $1.percent }
                if abs(sum - 1) > 1e-6 { out.append("percents sum to \(sum) in \(t.shape(c))") }
                if c.children.contains(where: { $0.percent <= 0 }) { out.append("non-positive percent in \(t.shape(c))") }
            }
        } else {
            if let id = c.windowID { if !seen.insert(id).inserted { out.append("window \(id) appears twice") } }
        }
        for k in kids where k.parent !== c { out.append("bad parent pointer under \(c.kind)") }
        for k in kids { walk(k) }
    }
    walk(t.root)

    for o in t.outputs where o.focusOrder.isEmpty { out.append("output \(o.name) has no workspace") }
    if !t.focused.isDescendant(of: t.root) { out.append("focus is detached from the tree") }
    if t.focused.kind == .output || t.focused.kind == .root { out.append("focus on \(t.focused.kind)") }
    return out
}

@Suite struct Fuzz {
    /// `FUZZ_SEEDS=5000 scripts/test.sh` for a longer soak run.
    static let seedCount = UInt64(ProcessInfo.processInfo.environment["FUZZ_SEEDS"] ?? "") ?? 400

    static let commands = [
        "focus left", "focus right", "focus up", "focus down", "focus parent", "focus child", "focus mode_toggle",
        "move left", "move right", "move up", "move down",
        "split h", "split v", "layout tabbed", "layout stacking", "layout splith", "layout splitv", "layout toggle split",
        "fullscreen toggle", "floating toggle", "kill",
        "workspace 1", "workspace 2", "workspace 3", "workspace next", "workspace back_and_forth",
        "move container to workspace 1", "move container to workspace 2", "move container to workspace 4",
        "resize grow width 10 px or 10 ppt", "resize shrink height 10 px or 10 ppt",
        "move container to output left", "move container to output right", "focus output left", "focus output right",
        "move workspace to output right", "move workspace to output left",
    ]

    func run(seed: UInt64, outputs: Int) {
        var rng = LCG(state: seed)
        let specs = (0..<outputs).map { (name: "o\($0)", rect: Rect(Double($0) * 1000, 0, 1000, 800)) }
        let t = Tree(outputs: specs)
        var nextID: WindowID = 1
        var log: [String] = []
        for step in 0..<80 {
            let op: String
            let r = Int(rng.next() % 100)
            if r < 18 || t.allWindowIDs.isEmpty {
                op = "add \(nextID)"
                t.addWindow(nextID, title: "w\(nextID)", floating: rng.chance(8))
                nextID += 1
            } else if r < 28 {
                let id = rng.pick(t.allWindowIDs)
                op = "remove \(id)"
                t.removeWindow(id)
            } else if r < 31 {
                let id = rng.pick(t.allWindowIDs)
                op = "os-focus \(id)"
                t.focusWindow(id)
            } else if r < 38 {
                let a = rng.pick(t.allWindowIDs), b = rng.pick(t.allWindowIDs)
                let zone = rng.pick([DropZone.left, .right, .top, .bottom, .center])
                op = "drop \(a) onto \(b) \(zone)"
                t.dropWindow(a, onto: b, zone: zone)
            } else if r < 42 {
                let id = rng.pick(t.allWindowIDs)
                let d = { Double(Int(rng.next() % 400)) - 200 }
                let (l, rr, tp, bt) = (d(), d(), d(), d())
                op = "resize \(id) l\(l) r\(rr) t\(tp) b\(bt)"
                t.resizeByEdges(id, left: l, right: rr, top: tp, bottom: bt)
            } else if r < 44 && outputs > 1 {
                let id = rng.pick(t.allWindowIDs)
                let name = rng.pick(specs).name
                op = "drop \(id) on output \(name)"
                t.dropWindow(id, onOutput: name)
            } else {
                op = rng.pick(Fuzz.commands)
                var errs: [String] = []
                t.run(op, errors: &errs)
                if !errs.isEmpty { Issue.record("seed \(seed): command rejected: \(op)") }
            }
            log.append(op)
            let v = violations(t)
            if !v.isEmpty {
                Issue.record("seed \(seed) outputs \(outputs) step \(step) after '\(op)': \(v)\nlast ops: \(log.suffix(8))\ntree: \(t.outputs.map { t.shape($0) })")
                return
            }
            let res = t.computeLayout()
            for (id, f) in res.frames where f.w <= 0 || f.h <= 0 || f.x.isNaN || f.y.isNaN {
                Issue.record("seed \(seed) step \(step): degenerate frame for \(id): \(f)")
                return
            }
            // every window is either shown or hidden, never both, never neither (floating rect aside)
            let all = Set(t.allWindowIDs)
            let shown = Set(res.frames.keys), hidden = res.hidden
            if !shown.isDisjoint(with: hidden) || shown.union(hidden) != all {
                Issue.record("seed \(seed) step \(step) after '\(op)': shown/hidden mismatch shown=\(shown) hidden=\(hidden) all=\(all)")
                return
            }
        }
    }

    @Test func randomOperationsKeepTreeConsistentOneOutput() {
        for seed in UInt64(1)...Fuzz.seedCount { run(seed: seed, outputs: 1) }
    }

    @Test func randomOperationsKeepTreeConsistentTwoOutputs() {
        for seed in UInt64(1000)...(1000 + Fuzz.seedCount) { run(seed: seed, outputs: 2) }
    }
}
