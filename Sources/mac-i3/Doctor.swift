import AppKit
import ApplicationServices
import I3Config
import I3Mac

func runDoctor() -> Never {
    func mark(_ ok: Bool) -> String { ok ? "ok  " : "FAIL" }
    var bad = false
    func check(_ ok: Bool, _ msg: String, hint: String = "") {
        print("[\(mark(ok))] \(msg)")
        if !ok { bad = true; if !hint.isEmpty { print("       \(hint)") } }
    }
    let ax = AXIsProcessTrusted()
    check(ax, "Accessibility permission", hint: "System Settings > Privacy & Security > Accessibility: enable the app that runs mac-i3 (your terminal / VS Code).")
    let listen = CGPreflightListenEventAccess()
    check(listen, "Input Monitoring (needed for the key tap)", hint: "System Settings > Privacy & Security > Input Monitoring.")
    let aero = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "bobko.aerospace" || $0.localizedName == "AeroSpace" }
    check(!aero, "AeroSpace is not running", hint: "Quit AeroSpace; two window managers will fight over window positions.")
    let yabai = NSWorkspace.shared.runningApplications.contains { $0.localizedName == "yabai" }
    check(!yabai, "yabai is not running")
    let screens = NSScreen.screens
    print("[info] \(screens.count) display(s):")
    for o in Displays.publicOutputs() { print("       \(o)") }
    let spans = (CFPreferencesCopyAppValue("spans-displays" as CFString, "com.apple.spaces" as CFString) as? NSNumber)?.boolValue ?? false
    if spans {
        print("[warn] 'Displays have separate Spaces' is off (System Settings > Desktop & Dock > Mission Control).")
        print("       Multi-monitor workspaces work best with it on; takes effect after logout.")
    } else {
        print("[ok  ] Displays have separate Spaces")
    }
    let path = NSString(string: "~/.config/mac-i3/config").expandingTildeInPath
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? DefaultConfig.text
    let r = ConfigParser.parse(text)
    check(r.errors.isEmpty, "Config parses (\(FileManager.default.fileExists(atPath: path) ? path : "built-in default"))")
    for e in r.errors { print("       \(e)") }
    let running = IPC.send("ping", timeout: 1) == "pong"
    print("[info] daemon \(running ? "is running" : "is not running")")
    exit(bad ? 1 : 0)
}
