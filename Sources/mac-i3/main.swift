import AppKit
import I3Config
import I3Mac

let usage = """
mac-i3 — i3 window management for macOS

USAGE
  mac-i3 [run] [--only APP]... [--exclude APP]... [--config FILE] [-v]
        Start the window manager (foreground). Listens for i3's key bindings.
        --only limits management to the named apps (name or bundle id); handy for testing.
  mac-i3 msg <i3 command>     Run an i3 command in the running daemon, e.g. `mac-i3 msg 'split v; layout tabbed'`
  mac-i3 tree                 JSON dump of the container tree
  mac-i3 state                JSON dump of workspaces, shapes and the OS-reported window frames
  mac-i3 shape                One-line tree shape per output
  mac-i3 modifiers            Show which modifier keys macOS thinks are held (should be none)
  mac-i3 release-modifiers    Clear stuck modifier keys
  mac-i3 inject <chord>       Post a synthetic key press, e.g. `mac-i3 inject Mod1+Shift+j`
  mac-i3 mouse <click|down|dragto|up> X Y | drag X1 Y1 X2 Y2
                              Post synthetic mouse events (screen coordinates, top-left origin)
  mac-i3 restore              Pull windows stranded off-screen back onto the display
  mac-i3 doctor               Check permissions and environment
  mac-i3 test-window <title>  Open a labelled test window (for trying it out)
  mac-i3 default-config       Print the built-in i3-style default config
"""

var args = Array(CommandLine.arguments.dropFirst())
let sub = args.first.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "run"
if args.first == sub { args.removeFirst() }

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

func client(_ req: String) -> Never {
    guard let resp = IPC.send(req) else { fail("mac-i3: daemon is not running (start it with `mac-i3`)") }
    print(resp)
    exit(resp.hasPrefix("error") ? 1 : 0)
}

switch sub {
case "run":
    var o = ManagerOptions()
    var it = args.makeIterator()
    while let a = it.next() {
        switch a {
        case "--only": if let v = it.next() { o.only.append(v) }
        case "--exclude": if let v = it.next() { o.exclude.append(v) }
        case "--config": o.configPath = it.next()
        case "-v", "--verbose": o.verbose = true
        default: fail("unknown option \(a)\n\n\(usage)")
        }
    }
    WindowManager(options: o).run()
case "msg":
    guard !args.isEmpty else { fail("usage: mac-i3 msg <command>") }
    client(args.joined(separator: " "))
case "tree", "state", "shape", "reconcile", "ping":
    client(sub)
case "modifiers":
    let held = KeyInjector.heldModifiers()
    print(held.isEmpty ? "none" : held.joined(separator: "+"))
case "release-modifiers":
    KeyInjector.releaseModifiers()
    let held = KeyInjector.heldModifiers()
    print(held.isEmpty ? "modifiers released" : "still held: " + held.joined(separator: "+"))
    exit(held.isEmpty ? 0 : 1)
case "inject":
    guard let chord = args.first else { fail("usage: mac-i3 inject <chord>") }
    exit(KeyInjector.press(chord) ? 0 : 1)
case "mouse":
    let n = args.dropFirst().compactMap { Double($0) }
    if ["click", "down", "drag"].contains(args.first ?? ""), n.count >= 2,
       let owner = MouseInjector.guardViolation(x: n[0], y: n[1]) {
        fail("mac-i3 mouse: refusing to press at \(Int(n[0])),\(Int(n[1])): the window there belongs to \(owner), not \(ProcessInfo.processInfo.environment["MAC_I3_MOUSE_GUARD"] ?? "")")
    }
    switch (args.first, n.count) {
    case ("click", 2): MouseInjector.click(n[0], n[1])
    case ("down", 2): MouseInjector.down(n[0], n[1])
    case ("dragto", 2): MouseInjector.dragTo(n[0], n[1])
    case ("up", 2): MouseInjector.up(n[0], n[1])
    case ("drag", 4): MouseInjector.drag(from: (n[0], n[1]), to: (n[2], n[3]))
    default: fail("usage: mac-i3 mouse click|down|dragto|up X Y  |  drag X1 Y1 X2 Y2")
    }
case "restore":
    let n = WindowManager.restoreOffscreen(quiet: false)
    print("restored \(n) window(s)")
case "doctor":
    runDoctor()
case "test-window":
    runTestWindow(title: args.first ?? "test")
case "default-config":
    print(DefaultConfig.text)
case "help", "-h", "--help":
    print(usage)
default:
    fail("unknown command '\(sub)'\n\n\(usage)")
}
